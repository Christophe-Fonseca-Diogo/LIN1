#!/usr/bin/env bash
#===============================================================================
# SRV-NAS-LIN1-01 - OMV
#
# Fonseca Diogo Christophe
# 13.10.2026
#
# Usage (en root) :
#   SSH_PUBKEY='ssh-rsa AAAA... user@pc' LDAP_ADMIN_PASS='xxx' CONFIRM_RAID=oui REBOOT_AT_END=oui ./setup-nas-lin1-01.sh
#===============================================================================
set -Eeuo pipefail
umask 077

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

# Couleurs
RED=$'\e[1;31m'
GREEN=$'\e[1;32m'
BLUE=$'\e[1;34m'
YELLOW=$'\e[1;33m'
CYAN=$'\e[36m'
RESET=$'\e[0m'

LOG_FILE="/var/log/setup-nas-lin1-01.log"
mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'rc=$?; echo "${RED}[ERREUR] code=${rc} ligne=${LINENO}: ${BASH_COMMAND}${RESET}"; exit "$rc"' ERR

info() { echo "${CYAN}[INFO] $*${RESET}"; }
ok() { echo "${GREEN}[OK] $*${RESET}"; }
warn() { echo "${YELLOW}[ATTENTION] $*${RESET}"; }
die() { echo "${RED}[ERREUR] $*${RESET}" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Commande requise introuvable : $1"
}
# Permet de lire la conf omv
omv_read() {
    omv-confdbadm read "$1"
}

omv_create() {
    local model="$1"
    local json="$2"

    omv-confdbadm update "$model" "$json"
}

# Permet de mettre à jour la configuration omv
omv_update() {
    local model="$1"
    local json="$2"

    omv-confdbadm update "$model" "$json"
}

[ "$(id -u)" -eq 0 ] || die "Exécute ce script en root."

# Paramètres
#-------------------------------------------------------------------------------

NAS_IFACE="${NAS_IFACE:-ens33}"
NAS_IP="${NAS_IP:-10.10.10.33}"
NAS_PREFIX="${NAS_PREFIX:-24}"
NAS_NETMASK="${NAS_NETMASK:-255.255.255.0}"
NAS_GATEWAY="${NAS_GATEWAY:-10.10.10.11}"
NAS_DNS="${NAS_DNS:-10.10.10.11}"

DISK1="${DISK1:-/dev/sdb}"
DISK2="${DISK2:-/dev/sdc}"
RAID="${RAID:-/dev/md0}"
FS_LABEL="${FS_LABEL:-raid1_data}"

NFS_NETWORK="${NFS_NETWORK:-10.10.10.0/24}"
NFS_OPTIONS="${NFS_OPTIONS:-rw,subtree_check,secure,root_squash}"

CONFIRM_RAID="${CONFIRM_RAID:-non}"
REBOOT_AT_END="${REBOOT_AT_END:-non}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-45}"

SERVICE_DIRS=(Clients Commun Logiciels)
SERVICE_PROJECT_IDS=(101 102 103)
SERVICE_HARD_LIMITS=(20480 30720 20480)

PERSO_USERS=(dev01 dev02 ing01 ing02 man01 man02)
PERSO_FIRST_PROJECT_ID=201
PERSO_HARD_LIMIT=10240

# Fonctions OMV
#-------------------------------------------------------------------------------
# Récupère les uuid des d'un point de montage OMV
get_mount_uuid() {
    omv_read conf.system.filesystem.mountpoint |
        jq -r --arg dir "$1" '
            if type == "array" then .[] else . end
            | select(.dir == $dir)
            | .uuid
        ' |
        head -n 1
}
# Récupère l'objet de configuration JSON brut d'un point de montage
get_mount_json() {
    omv_read conf.system.filesystem.mountpoint |
        jq -c --arg dir "$1" '
            if type == "array" then .[] else . end
            | select(.dir == $dir)
        ' |
        head -n 1
}
# Recherche l'UUID d'un dossier partagé OMV par son nom (ex: Clients)
get_shared_folder_uuid() {
    omv_read conf.system.sharedfolder |
        jq -r --arg name "$1" '
            if type == "array" then .[] else . end
            | select(.name == $name)
            | .uuid
        ' |
        head -n 1
}
# Recherche l'UUID d'un partage NFS existant lié à un dossier partagé spécifique
get_nfs_share_uuid() {
    omv_read conf.service.nfs.share |
        jq -r --arg sfref "$1" '
            if type == "array" then .[] else . end
            | select(.sharedfolderref == $sfref)
            | .uuid
        ' |
        head -n 1
}
# Déclare et provisionne un dossier partagé en contournant l'API RPC (injection XML brute)
create_shared_folder() {
    local name="$1"
    local existing=""
    local folder_uuid=""
    local config_file="/etc/openmediavault/config.xml"

    existing="$(get_shared_folder_uuid "$name" || true)"

    # Vérifie si le dossier existe déjà pour éviter les doublons
    if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        SF_UUID["$name"]="$existing"
        info "Dossier partagé déjà enregistré : $name"
        return 0
    fi

    folder_uuid="$(uuidgen)"
    info "Injection directe du dossier partagé dans config.xml : $name (UUID: $folder_uuid)..."

    # Installation à la volée de xmlstarlet si manquant
    if ! command -v xmlstarlet >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq xmlstarlet >/dev/null
    fi

    # Injection de la structure XML nécessaire pour OMV dans /system/shares
    xmlstarlet ed -L -s "//system/shares" -t elem -n "sharedfolder" \
        -v "" \
        -s "//system/shares/sharedfolder[last()]" -t elem -n "uuid" -v "$folder_uuid" \
        -s "//system/shares/sharedfolder[last()]" -t elem -n "name" -v "$name" \
        -s "//system/shares/sharedfolder[last()]" -t elem -n "comment" -v "" \
        -s "//system/shares/sharedfolder[last()]" -t elem -n "mntentref" -v "$MNTENT_UUID" \
        -s "//system/shares/sharedfolder[last()]" -t elem -n "reldirpath" -v "$name" \
        "$config_file"

    # Création physique du répertoire sur le disque RAID
    local raid_uuid
    raid_uuid="$(blkid -s UUID -o value "$RAID")"
    mkdir -p "/srv/dev-disk-by-uuid-${raid_uuid}/$name"
    chmod 775 "/srv/dev-disk-by-uuid-${raid_uuid}/$name"

    systemctl restart openmediavault-engined
    sleep 2
    # Stocke l'UUID généré dans le tableau associatif global
    SF_UUID["$name"]="$folder_uuid"
    ok "Dossier partagé injecté et validé avec succès : $name"
}

# Associe et configure un export NFS sur un dossier partagé existant via injection XML
create_nfs_share() {
    local folder_name="$1"
    local sf_uuid="${SF_UUID[$folder_name]}"
    local existing=""
    local nfs_uuid=""
    local config_file="/etc/openmediavault/config.xml"

    [ -n "$sf_uuid" ] ||
        die "UUID manquant pour le dossier partagé : $folder_name"

    existing="$(get_nfs_share_uuid "$sf_uuid" || true)"
    # Évite d'injecter deux fois le même export NFS
    if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        info "Export NFS déjà enregistré : $folder_name"
        return 0
    fi

    nfs_uuid="$(uuidgen)"
    info "Injection directe de l'export NFS dans config.xml pour : $folder_name (UUID: $nfs_uuid)..."

    if ! command -v xmlstarlet >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq xmlstarlet >/dev/null
    fi
    # Injection XML dans la section des services NFS d'OMV
    xmlstarlet ed -L -s "//services/nfs/shares" -t elem -n "share" \
        -v "" \
        -s "//services/nfs/shares/share[last()]" -t elem -n "uuid" -v "$nfs_uuid" \
        -s "//services/nfs/shares/share[last()]" -t elem -n "sharedfolderref" -v "$sf_uuid" \
        -s "//services/nfs/shares/share[last()]" -t elem -n "mntentref" -v "$MNTENT_UUID" \
        -s "//services/nfs/shares/share[last()]" -t elem -n "client" -v "$NFS_NETWORK" \
        -s "//services/nfs/shares/share[last()]" -t elem -n "options" -v "$NFS_OPTIONS" \
        -s "//services/nfs/shares/share[last()]" -t elem -n "extraoptions" -v "async" \
        -s "//services/nfs/shares/share[last()]" -t elem -n "comment" -v "" \
        "$config_file"

    systemctl restart openmediavault-engined
    sleep 2

    ok "Export NFS injecté avec succès : $folder_name"
}

# Modifie le JSON réseau d'OMV en Python pour appliquer les paramètres IP statiques
configure_network_omv() {
    local before_json="$1"
    local after_json="$2"

    python3 - \
        "$before_json" \
        "$NAS_IFACE" \
        "$NAS_IP" \
        "$NAS_NETMASK" \
        "$NAS_GATEWAY" \
        "$NAS_DNS" \
        > "$after_json" <<'PY'
import json
import sys

src, iface, address, netmask, gateway, dns = sys.argv[1:]

with open(src, encoding="utf-8") as handle:
    data = json.load(handle)

items = data if isinstance(data, list) else [data]
matches = [item for item in items if item.get("devicename") == iface]

if len(matches) != 1:
    raise SystemExit(
        f"Interface OMV '{iface}' : {len(matches)} occurrence(s), une attendue."
    )

entry = matches[0]
entry.update({
    "method": "static",
    "address": address,
    "netmask": netmask,
    "gateway": gateway,
    "dnsnameservers": dns,
    "method6": "manual",
    "address6": "",
    "gateway6": "",
    "wol": False,
})

print(json.dumps(entry, separators=(",", ":")))
PY
}

# Vérification de base
#-------------------------------------------------------------------------------

echo "${BLUE}=== 1. Vérifications initiales ===${RESET}"

require_command apt-get
require_command ip
require_command awk
require_command grep
require_command sed
require_command date
require_command blkid
require_command mountpoint
require_command python3
require_command systemctl
require_command dpkg-query
require_command omv-confdbadm
require_command omv-salt

[ -f /etc/openmediavault/config.xml ] ||
    die "Le fichier /etc/openmediavault/config.xml est absent."

ip link show "$NAS_IFACE" >/dev/null 2>&1 ||
    die "Interface réseau absente : $NAS_IFACE"
# Vérifie que les disques ne sont pas montés avant d’envisager leur intégration au RAID.
for disk in "$DISK1" "$DISK2"; do
    [ -b "$disk" ] || die "Disque introuvable : $disk"
done

OMV_VERSION="$(dpkg-query -W -f='${Version}' openmediavault 2>/dev/null || true)"
[ -n "$OMV_VERSION" ] || die "OpenMediaVault n'est pas installé."

info "OMV : $OMV_VERSION"
info "Réseau : $NAS_IFACE -> $NAS_IP/$NAS_PREFIX"
info "Journal : $LOG_FILE"

exec 9>/run/lock/setup-nas-lin1-01.lock
flock -n 9 || die "Une instance du script est déjà en cours."

# Update des paquets
#-------------------------------------------------------------------------------

echo "${BLUE}=== 2. Mise à jour et paquets ===${RESET}"

echo "postfix postfix/main_mailer_type select No configuration" |
    debconf-set-selections

APT_OPTS=(
    -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}"
    -o "APT::Get::Assume-Yes=true"
)

# Actualise les index APT puis installe les mises à jour et outils nécessaires au RAID, aux quotas et aux ACL.
apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" upgrade \
    -o Dpkg::Options::="--force-confold"

apt-get "${APT_OPTS[@]}" install \
    mdadm quota acl nfs-kernel-server jq uuid-runtime e2fsprogs

for cmd in \
    jq uuidgen setquota repquota setfacl getfacl \
    mdadm tune2fs wipefs chattr lsattr \
    update-initramfs udevadm; do
    require_command "$cmd"
done

ok "Paquets installés."

# Configuration du réseau OMV
#-------------------------------------------------------------------------------

echo "${BLUE}=== 3. Sauvegarde et configuration réseau OMV ===${RESET}"

# Sauvegarde la configuration OMV et l’état réseau avant de modifier les paramètres.
BACKUP_DIR="/root/backup-nas-lin1-01-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

cp -a /etc/openmediavault/config.xml "$BACKUP_DIR/config.xml.before"

omv_read conf.system.network.interface \
    > "$BACKUP_DIR/network-before.json"

if [ -f /etc/systemd/network/10-nas-lin1-01.network ]; then
    mv /etc/systemd/network/10-nas-lin1-01.network \
        "$BACKUP_DIR/10-nas-lin1-01.network.disabled"

    warn "Ancien fichier réseau indépendant désactivé."
fi

NETWORK_JSON="$BACKUP_DIR/network-after.json"

configure_network_omv \
    "$BACKUP_DIR/network-before.json" \
    "$NETWORK_JSON"

omv_update conf.system.network.interface \
    "$(cat "$NETWORK_JSON")"

ok "IP enregistrée dans la configuration OMV."
info "Elle sera appliquée au redémarrage final."

# Configuration key SSH
#-------------------------------------------------------------------------------

echo "${BLUE}=== 4. SSH ===${RESET}"

# Prépare le fichier des clés SSH de root avec des permissions privées.
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

if [ -n "$SSH_PUBKEY" ]; then
    [[ "$SSH_PUBKEY" == ssh-* ]] ||
        die "SSH_PUBKEY ne commence pas par ssh-."

    grep -qxF "$SSH_PUBKEY" /root/.ssh/authorized_keys ||
        printf '%s\n' "$SSH_PUBKEY" >> /root/.ssh/authorized_keys

    ok "Clé SSH enregistrée."
else
    warn "Aucune clé SSH fournie."
fi

systemctl enable --now ssh

# Configuration RAID1
#-------------------------------------------------------------------------------

echo "${BLUE}=== 5. RAID 1 ===${RESET}"

for disk in "$DISK1" "$DISK2"; do
    if lsblk -nr -o MOUNTPOINT "$disk" |
        grep -qv '^$'; then
        die "$disk, ou une de ses partitions, est monté."
    fi
done

if [ -b "$RAID" ] &&
    grep -qE "^md0 : active raid1" /proc/mdstat; then
    info "RAID existant détecté : aucune opération destructive."
else
    [ "$CONFIRM_RAID" = "oui" ] ||
        die "CONFIRM_RAID=oui est obligatoire avant la création du RAID."

    for disk in "$DISK1" "$DISK2"; do
        if wipefs -n "$disk" | grep -q .; then
            warn "Signatures présentes sur $disk : elles vont être effacées."
        fi
    done

    wipefs -a "$DISK1"
    wipefs -a "$DISK2"

    mdadm --create "$RAID" \
        --level=1 \
        --raid-devices=2 \
        --metadata=1.2 \
        --run \
        "$DISK1" "$DISK2"

    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    update-initramfs -u

    ok "RAID 1 créé."
fi

udevadm settle || true
sleep 3

grep -qE "^md0 : active raid1" /proc/mdstat ||
    die "Le RAID md0 n'est pas actif."

cat /proc/mdstat

# Configuration du montage et du quotas 
#-------------------------------------------------------------------------------

echo "${BLUE}=== 6. ext4, project quotas et montage OMV ===${RESET}"

# Prépare le volume RAID en ext4 avec la fonctionnalité project, requise pour les quotas par projet.
if ! blkid "$RAID" | grep -q 'TYPE="ext4"'; then
    [ "$CONFIRM_RAID" = "oui" ] ||
        die "Formatage refusé : CONFIRM_RAID=oui requis."

    if blkid "$RAID" >/dev/null 2>&1; then
        die "$RAID contient déjà un système de fichiers non-ext4."
    fi

    mkfs.ext4 -F -O project -L "$FS_LABEL" "$RAID"
    ok "ext4 créé avec la fonctionnalité project."
else
    info "ext4 déjà présent sur le RAID."
fi

UUID="$(blkid -s UUID -o value "$RAID")"
[ -n "$UUID" ] || die "UUID du RAID introuvable."

MNT="/srv/dev-disk-by-uuid-${UUID}"
DEVICE="/dev/disk/by-uuid/${UUID}"


MNTENT_UUID="$(get_mount_uuid "$MNT" || true)"

if [ -z "$MNTENT_UUID" ] || [ "$MNTENT_UUID" = "null" ]; then
    info "Enregistrement du point de montage via l'API RPC d'OMV..."
    
    # Appel de l'API officielle pour créer proprement le point de montage dans OMV
    omv-rpc -u admin 'filesystemmgmt' 'setMountPoint' \
        "{\"id\":\"${DEVICE}\",\"usagewarnthreshold\":85,\"comment\":\"\"}"

    omv-salt deploy run fstab
    
    MNTENT_UUID="$(get_mount_uuid "$MNT" || true)"
    ok "Point de montage enregistré de manière officielle. UUID : $MNTENT_UUID"
else
    info "Point de montage OMV déjà présent : $MNTENT_UUID"
fi

[ -n "$MNTENT_UUID" ] && [ "$MNTENT_UUID" != "null" ] || \
    die "Erreur fatale : Impossible de récupérer l'UUID de montage créé par OMV."

mkdir -p "$MNT"

if ! mountpoint -q "$MNT"; then
    mount "$MNT"
fi

mountpoint -q "$MNT" || die "Impossible de monter le RAID sur $MNT."

# IMPORTANT : Démonte avant d'activer les project quotas ext4
umount "$MNT"
tune2fs -O project -Q prjquota "$RAID"
mount "$MNT"

mountpoint -q "$MNT" || die "Impossible de remonter le RAID après activation prjquota."

omv-salt deploy run fstab

MNTENT_UUID="$(get_mount_uuid "$MNT" || true)"
ok "Section 6 finalisée. ext4 prêt avec project quotas. MNTENT_UUID=$MNTENT_UUID"


# Création des dossiers partagés OMV
#-------------------------------------------------------------------------------

echo "${BLUE}=== 7. Dossiers partagés OMV ===${RESET}"

# Mémorise les UUID des dossiers partagés pour pouvoir les associer aux exports NFS.
declare -A SF_UUID=()

for folder in "${SERVICE_DIRS[@]}" Perso; do
    create_shared_folder "$folder"
done

for folder in "${SERVICE_DIRS[@]}" Perso; do
    [ -d "$MNT/$folder" ] ||
        die "Dossier partagé absent : $MNT/$folder"
done

ok "Dossiers partagés présents."

# Ajout du quota pour les dossiers de service
#-------------------------------------------------------------------------------

echo "${BLUE}=== 8. Quotas des dossiers de services ===${RESET}"

for index in "${!SERVICE_DIRS[@]}"; do
    folder="${SERVICE_DIRS[$index]}"
    project_id="${SERVICE_PROJECT_IDS[$index]}"
    hard_limit="${SERVICE_HARD_LIMITS[$index]}"

    chattr +P -p "$project_id" "$MNT/$folder"
    setquota -P "$project_id" 0 "$hard_limit" 0 0 "$MNT"

    info "$folder : project ID=$project_id ; hard limit=${hard_limit} Ko"
done

# Création des dossiers perso et des ACL
#-------------------------------------------------------------------------------

echo "${BLUE}=== 9. Dossiers perso, quotas et ACL ===${RESET}"

mkdir -p "$MNT/Perso"

project_id="$PERSO_FIRST_PROJECT_ID"

for username in "${PERSO_USERS[@]}"; do
    userdir="$MNT/Perso/$username"

    mkdir -p "$userdir"

    chattr +P -p "$project_id" "$userdir"
    setquota -P "$project_id" 0 "$PERSO_HARD_LIMIT" 0 0 "$MNT"

    chown -R www-data:www-data "$userdir"

    setfacl -b "$userdir"
    setfacl -m u:www-data:rwx,g::---,o::--- "$userdir"
    setfacl -d -m u::rwx,g::---,o::--- "$userdir"
    setfacl -d -m u:www-data:rwx "$userdir"

    info "Perso/$username : project ID=$project_id ; hard limit=${PERSO_HARD_LIMIT} Ko"

    project_id=$((project_id + 1))
done

chown root:www-data "$MNT/Perso"
chmod 0710 "$MNT/Perso"
setfacl -m u:www-data:--x "$MNT/Perso"

ok "ACL Nextcloud/www-data appliquées."

# Activation du service NFS et des exports
#-------------------------------------------------------------------------------

echo "${BLUE}=== 10. Service NFS et exports ===${RESET}"

NFS_CURRENT="$(omv_read conf.service.nfs)"

NFS_UPDATED="$(
    printf '%s' "$NFS_CURRENT" |
        jq -c '
            if type == "array" then
                .[0] | .enable = true
            else
                .enable = true
            end
        '
)"

omv_update conf.service.nfs "$NFS_UPDATED"

for folder in "${SERVICE_DIRS[@]}" Perso; do
    create_nfs_share "$folder"
done

omv-salt deploy run nfs

systemctl enable --now nfs-server
systemctl restart nfs-server

ok "NFS configuré pour $NFS_NETWORK."

# Check final
#-------------------------------------------------------------------------------

echo "${BLUE}=== 11. Vérifications finales ===${RESET}"

ERRORS=0

verif() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        printf "  %-42s ${GREEN}[ OK ]${RESET}\n" "$description"
    else
        printf "  %-42s ${RED}[ ERREUR ]${RESET}\n" "$description"
        ERRORS=$((ERRORS + 1))
    fi
}

verif "OpenMediaVault installé" \
    dpkg-query -W openmediavault

verif "SSH actif" \
    systemctl is-active --quiet ssh

verif "Moteur OMV actif" \
    systemctl is-active --quiet openmediavault-engined

verif "Nginx actif" \
    systemctl is-active --quiet nginx

verif "RAID 1 md0 actif" \
    grep -qE "^md0 : active raid1" /proc/mdstat

verif "RAID 1 sain [UU]" \
    grep -q '\[UU\]' /proc/mdstat

verif "RAID monté" \
    mountpoint -q "$MNT"

for folder in Clients Commun Logiciels Perso; do
    verif "Dossier $folder présent" \
        test -d "$MNT/$folder"
done

verif "Quota Clients (ID 101)" \
    bash -c "repquota -P '$MNT' | grep -q '^#101'"

verif "Quota Perso (ID 206)" \
    bash -c "repquota -P '$MNT' | grep -q '^#206'"

verif "NFS actif" \
    systemctl is-active --quiet nfs-server

verif "Export NFS Perso" \
    bash -c "exportfs -s | grep -q '/export/Perso'"

verif "ACL www-data sur dev01" \
    bash -c "getfacl -p '$MNT/Perso/dev01' | grep -q '^user:www-data:rwx'"

echo
repquota -P "$MNT" || true

if [ "$ERRORS" -ne 0 ]; then
    die "$ERRORS vérification(s) en erreur. Consulte : $LOG_FILE"
fi

ok "NAS-LIN1-01 configuré avec succès."

# Permet de sauvegarder la configuration IP après un reboot
omv-salt deploy run systemd-networkd

# Redémarrage final pour appliquer la configuration réseau
#-------------------------------------------------------------------------------

echo
echo "${BLUE}=== Configuration réseau prévue au prochain démarrage ===${RESET}"
echo "Interface  : $NAS_IFACE"
echo "Adresse    : $NAS_IP/$NAS_PREFIX"
echo "Passerelle : $NAS_GATEWAY"
echo "DNS        : $NAS_DNS"
echo "OMV Web    : http://$NAS_IP"
echo "SSH        : ssh root@$NAS_IP"
echo "NFS        : showmount -e $NAS_IP"

if [ "$REBOOT_AT_END" = "oui" ]; then
    warn "Redémarrage dans 10 secondes."
    sleep 10
    systemctl reboot
else
    info "Pas de redémarrage automatique : REBOOT_AT_END=non."
fi
