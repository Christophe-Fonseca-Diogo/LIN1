#!/usr/bin/env bash
#===============================================================================
# SRV-LIN1-02 - Debian 13 - Nextcloud 
# Pré-requis : SRV-LIN1-01 (DNS/DHCP/LDAP) et NAS-LIN1-01 (OMV) sont installés.
#
# Fonseca Diogo Christophe
# 14.10.2026
#
# Usage (en root) :
#   SSH_PUBKEY='ssh-rsa AAAA...' NXTCLOUD_LDAP_PASS='xxx' ./setup-srv-lin1-02.sh
#===============================================================================
set -eE
export PATH="$PATH:/sbin:/usr/sbin:/bin:/usr/bin"
export DEBIAN_FRONTEND=noninteractive

# Couleurs
BLEU=$'\e[1;34m'; CYAN=$'\e[36m'; VERT=$'\e[1;32m'; ROUGE=$'\e[1;31m'; JAUNE=$'\e[1;33m'; RESET=$'\e[0m'
trap 'echo "${ROUGE}Échec ligne $LINENO : $BASH_COMMAND${RESET}" >&2' ERR
die() { echo "${ROUGE}[ERREUR] $*${RESET}" >&2; exit 1; }

# Variables
#-------------------------------------------------------------------------------
NC_URL="${NC_URL:-https://download.nextcloud.com/server/releases/nextcloud-34.0.3.zip}"
NC_DIR="/var/www/html/nextcloud"
NC_ADMIN="nxtadmin"
DB_NAME="nextcloud"
DB_USER="nextclouduser"

IP_SRV="10.10.10.22"
IP_DNS_GW="10.10.10.11"          # SRV-LIN1-01 : DNS, passerelle, LDAP
IP_NAS="10.10.10.33"
FQDN="srv-lin1-02.LIN1-Christophe.local"

LDAP_BASE="dc=LIN1-Christophe,dc=local"
LDAP_BIND_DN="uid=nxtcloud,ou=services,${LDAP_BASE}"
CERT_SUBJ="${CERT_SUBJ:-/C=CH/ST=Vaud/L=Lausanne/O=LIN1-Christophe/CN=${FQDN}}"

PASS_FILE="/root/mdp-nextcloud.txt"

# Outils 
#-------------------------------------------------------------------------------
gen_pass() {  
    local p
    p="$(openssl rand -base64 64 | tr -d '/+=
')"
    printf '%s' "${p:0:$1}"
}

occ() { 
    (cd "$NC_DIR" && runuser -u www-data -- php occ "$@")
}

nc_mount() {  
    local out id
    out="$(occ files_external:create "$1" local null::null -c "datadir=$2")"
    id="$(echo "$out" | grep -oE '[0-9]+' | tail -1)"
    [ -n "$id" ] || die "ID du stockage '$1' introuvable (sortie : $out)"
    echo "$id"
}

nc_groups() {  
    local id="$1"; shift
    for g in "$@"; do occ files_external:applicable --add-group="$g" "$id"; done
}

[ "$(id -u)" -eq 0 ] || die "Lance ce script en root."
[ -t 0 ] || die "Ce script a besoin d'un terminal."

if [ -z "$NXTCLOUD_LDAP_PASS" ] ; then
    read -rsp "Mot de passe du compte LDAP 'nxtcloud' (affiché sur SRV-LIN1-01) : " NXTCLOUD_LDAP_PASS; echo
fi
[ -n "$NXTCLOUD_LDAP_PASS" ] || die "Mot de passe LDAP vide."

DB_PASS="$(gen_pass 20)"
ADMIN_PASS="$(gen_pass 20)"
{
    echo "Base de données ($DB_USER)  : $DB_PASS"
    echo "Nextcloud ($NC_ADMIN)  : $ADMIN_PASS"
} > "$PASS_FILE"
chmod 600 "$PASS_FILE"

# Update de la machine
#-------------------------------------------------------------------------------
echo "${BLEU}=== Mise à jour du système ===${RESET}"
if [ -f /etc/apt/sources.list ]; then
    # Mise en commentaire de la première ligne de sources.list (si pas déjà fait)
    sed -i '1{/^#/!s/^/# /}' /etc/apt/sources.list
fi
apt update && apt upgrade -y -o Dpkg::Options::="--force-confold"

# Configuration réseau
#-------------------------------------------------------------------------------
echo "${BLEU}=== Configuration de l'adresse IP en statique===${RESET}"
[ -f /etc/network/interfaces.org ] || cp /etc/network/interfaces /etc/network/interfaces.org
cat > /etc/network/interfaces <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto ens33
iface ens33 inet static 
	address ${IP_SRV}
	netmask 255.255.255.0
	gateway ${IP_DNS_GW}
	dns-nameservers ${IP_DNS_GW}
EOF

echo "${CYAN}=== Blocage du protocole DHCP ===${RESET}"

# 1. Pare-feu de sécurité : On bloque les paquets DHCP (ports 67 et 68) au niveau du noyau Linux
if command -v nft >/dev/null 2>&1; then
    nft add table inet filter 2>/dev/null || true
    nft add chain inet filter input { type filter hook input priority 0 \; } 2>/dev/null || true
    nft add rule inet filter input iifname "ens33" udp sport 67-68 counter drop 2>/dev/null || true
    nft add rule inet filter input iifname "ens33" udp dport 67-68 counter drop 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -A INPUT -i ens33 -p udp --sport 67:68 -j DROP 2>/dev/null || true
    iptables -A INPUT -i ens33 -p udp --dport 67:68 -j DROP 2>/dev/null || true
fi

# Bloquer tous les services de gestion réseau automatique qui peuvent relancer un DHCP
systemctl stop NetworkManager systemd-networkd systemd-networkd.socket dhcpcd 2>/dev/null || true
systemctl disable NetworkManager systemd-networkd systemd-networkd.socket dhcpcd 2>/dev/null || true
systemctl mask NetworkManager systemd-networkd dhcpcd 2>/dev/null || true
killall dhclient dhcpcd 2>/dev/null || pkill -f "dhclient|dhcpcd" 2>/dev/null || true

# On cherche toutes les IP de la carte ens33 et on exclut dynamiquement notre IP cible (.22)
IP_A_NETTOYER=$(ip -4 addr show dev ens33 | awk '/inet / {print $2}' | grep -v "${IP_SRV}" || true)

if [ -n "$IP_A_NETTOYER" ]; then
    for ip_obsolete in $IP_A_NETTOYER; do
        echo "${CYAN}[RÉSEAU] Suppression dynamique de l'IP : $ip_obsolete${RESET}"
        ip addr del "$ip_obsolete" dev ens33 2>/dev/null || true
    done
fi

ip addr flush dev ens33 || true
ip addr add "${IP_SRV}/24" dev ens33 2>/dev/null || true
ip link set ens33 up || true

systemctl restart networking 2>/dev/null || true
sleep 2

# Vérification Finale 
IP_PARASITE_REBOND=$(ip -4 addr show dev ens33 | awk '/inet / {print $2}' | grep -v "${IP_SRV}" || true)
if [ -n "$IP_PARASITE_REBOND" ]; then
    for ip_obsolete in $IP_PARASITE_REBOND; do
        ip addr del "$ip_obsolete" dev ens33 2>/dev/null || true
    done
fi

if ! ip addr show ens33 | grep -q "${IP_SRV}"; then
    die "Le script n'a pas pu basculer l'interface ens33 sur l'IP statique ${IP_SRV}."
fi
echo "${VERT}[OK] IP active unique : ${IP_SRV}${RESET}"

# Authentification par clé
#-------------------------------------------------------------------------------
echo "${BLEU}=== Authentification par clé ===${RESET}"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [ -n "$SSH_PUBKEY" ]; then
    echo "$SSH_PUBKEY" >> ~/.ssh/authorized_keys
fi
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo "${VERT}[OK] Authentification OK"

# Liaison Nextcloud et OMV
#-------------------------------------------------------------------------------
echo "${BLEU}=== Liaison Nextcloud et OMV (NFS) ===${RESET}"
apt install -y nfs-common
/usr/sbin/showmount -e "$IP_NAS" || die "Le NAS ($IP_NAS) ne répond pas : installe d'abord NAS-LIN1-01."

DOSSIERS_NFS=(Clients Commun Logiciels Perso)

for d in "${DOSSIERS_NFS[@]}"; do
    echo "${CYAN}=== Montage automatique du dossier : $d ===${RESET}"
    mkdir -p "/mnt/nextcloud/$d"
    mountpoint -q "/mnt/nextcloud/$d" || mount -t nfs "$IP_NAS:/$d" "/mnt/nextcloud/$d"
done
findmnt -t nfs,nfs4

echo "${CYAN}=== Persistance des montages NFS (fstab) ===${RESET}"
for d in "${DOSSIERS_NFS[@]}"; do
    grep -q "/mnt/nextcloud/$d " /etc/fstab ||         echo "$IP_NAS:/$d   /mnt/nextcloud/$d   nfs   defaults,_netdev   0  0" >> /etc/fstab
done
systemctl daemon-reload

# Installation de Nextcloud
#-------------------------------------------------------------------------------
echo "${BLEU}=== Installation de Nextcloud ===${RESET}"
apt install -y apache2
apt install -y php libapache2-mod-php php-mysql php-common php-gd php-xml php-mbstring php-zip php-curl
apt install -y mariadb-server mariadb-client

echo "${CYAN}=== Configuration de la base de données ===${RESET}"
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
EOF

echo "${VERT}[OK] Base de donnée OK"

echo "${CYAN}=== Téléchargement et installation des fichiers ===${RESET}"
cd /root
wget -nc "$NC_URL"
apt install -y unzip
if [ ! -d "$NC_DIR" ]; then
    unzip -q "$(basename "$NC_URL")" -d /var/www/html/
fi
chown -R www-data:www-data "$NC_DIR/"
systemctl restart apache2

echo "${CYAN}=== Installation de Nextcloud ===${RESET}"
if occ status 2>/dev/null | grep -q 'installed: true'; then
    echo "Nextcloud est déjà installé."
else
    occ maintenance:install         --database=mysql --database-name="$DB_NAME"         --database-user="$DB_USER" --database-pass="$DB_PASS"         --admin-user="$NC_ADMIN" --admin-pass="$ADMIN_PASS"
fi
occ config:system:set trusted_domains 1 --value="$IP_SRV"
occ config:system:set trusted_domains 2 --value="$FQDN"

# Configuration du SSL
#-------------------------------------------------------------------------------
echo "${BLEU}=== Configuration de SSL ===${RESET}"
a2enmod ssl rewrite
systemctl restart apache2

mkdir -p /etc/apache2/ssl
if [ ! -f /etc/apache2/ssl/nextcloud.crt ]; then
    openssl req -x509 -nodes -days 365 \
      -newkey rsa:4096 \
      -keyout /etc/apache2/ssl/nextcloud.key \
      -out /etc/apache2/ssl/nextcloud.crt \
      -subj "$CERT_SUBJ"
fi

cat > /etc/apache2/sites-available/default-ssl.conf <<EOF
<IfModule mod_ssl.c>
        <VirtualHost _default_:443>
                ServerAdmin webmaster@localhost
                DocumentRoot /var/www/html/nextcloud
                ServerName ${FQDN}

                SSLEngine on
                SSLCertificateFile /etc/apache2/ssl/nextcloud.crt
                SSLCertificateKeyFile /etc/apache2/ssl/nextcloud.key

                <Directory /var/www/html/nextcloud/>
                        Options +FollowSymlinks
                        AllowOverride All
                        Require all granted
                        <IfModule mod_dav.c>
                                Dav off
                        </IfModule>
                        SetEnv HOME /var/www/html/nextcloud
                        SetEnv HTTP_HOME /var/www/html/nextcloud
                </Directory>
        </VirtualHost>
</IfModule>
EOF

a2ensite default-ssl
systemctl restart apache2

echo "${VERT}[OK] SSL OK"

# Liaison OpenLDAP et Nextcloud
#-------------------------------------------------------------------------------
echo "${BLEU}=== Configuration de la liaison OpenLDAP ===${RESET}"
apt install -y php-ldap
systemctl restart apache2
occ app:enable user_ldap

echo "${CYAN}=== Configuration LDAP s01 ===${RESET}"
occ ldap:show-config s01 >/dev/null 2>&1 || occ ldap:create-empty-config
occ ldap:set-config s01 ldapHost "$IP_DNS_GW"
occ ldap:set-config s01 ldapPort 389
occ ldap:set-config s01 ldapAgentName "$LDAP_BIND_DN"
occ ldap:set-config s01 ldapAgentPassword "$NXTCLOUD_LDAP_PASS"
occ ldap:set-config s01 ldapBase "$LDAP_BASE"
occ ldap:set-config s01 ldapBaseUsers "ou=users,${LDAP_BASE}"
occ ldap:set-config s01 ldapUserFilterObjectclass posixAccount
occ ldap:set-config s01 ldapUserFilter "(|(objectclass=posixAccount))"
occ ldap:set-config s01 ldapLoginFilter "(&(|(objectclass=posixAccount))(uid=%uid))"
occ ldap:set-config s01 ldapLoginFilterUsername 1
occ ldap:set-config s01 ldapBaseGroups "ou=groups,${LDAP_BASE}"
occ ldap:set-config s01 ldapGroupFilterObjectclass posixGroup
occ ldap:set-config s01 ldapGroupFilter "(|(objectclass=posixGroup))"
occ ldap:set-config s01 ldapGroupMemberAssocAttr memberUid
occ ldap:set-config s01 ldapExpertUsernameAttr uid
occ ldap:set-config s01 ldapConfigurationActive 1
occ ldap:set-config s01 ldapUserDisplayName cn
occ ldap:set-config s01 ldapGroupDisplayName cn

echo "${CYAN}=== Test de la configuration LDAP ===${RESET}"
occ ldap:test-config s01 || echo "${JAUNE}[WARN] Test LDAP en échec : vérifie le mot de passe de nxtcloud et SRV-LIN1-01.${RESET}"

echo "${VERT}[OK] Connexion Nextcloud et OpenLDAP OK"

# Installation du module de calendrier
#-------------------------------------------------------------------------------
echo "${BLEU}=== Installation du calendrier ===${RESET}"
occ app:enable calendar || echo "${JAUNE}[WARN] Calendrier non installé (accès Internet / app store ?).${RESET}"

# Configuration des partages dans Nextcloud
#-------------------------------------------------------------------------------
echo "${BLEU}=== Configuration des partages dans Nextcloud ===${RESET}"
occ app:enable files_external
systemctl restart apache2

echo "${CYAN}=== Configuration des permissions locales sur les points NFS ===${RESET}"
chmod -R 770 /mnt/nextcloud/Clients /mnt/nextcloud/Logiciels /mnt/nextcloud/Commun /mnt/nextcloud/Perso
chown -R www-data:www-data /mnt/nextcloud

echo "${CYAN}=== Synchronisation et importation des groupes LDAP ===${RESET}"
for g in managers ingenieurs developpeurs; do
    echo "Importation du groupe LDAP : $g"
    occ ldap:check-group "$g" || true
done
sleep 2


echo "${CYAN}=== Dossiers perso (variable \$user) ===${RESET}"
ID_PERSO="$(nc_mount 'Perso' '/mnt/nextcloud/Perso/$user')"
echo "Perso -> stockage $ID_PERSO"

echo "${CYAN}=== Dossier Clients (managers, ingenieurs) ===${RESET}"
ID_CLIENTS="$(nc_mount 'Clients' /mnt/nextcloud/Clients)"
nc_groups "$ID_CLIENTS" managers ingenieurs
echo "Clients -> stockage $ID_CLIENTS"

echo "${CYAN}=== Dossier Logiciels (ingenieurs, developpeurs) ===${RESET}"
ID_LOGICIELS="$(nc_mount 'Logiciels' /mnt/nextcloud/Logiciels)"
nc_groups "$ID_LOGICIELS" ingenieurs developpeurs
echo "Logiciels -> stockage $ID_LOGICIELS"

echo "${CYAN}=== Dossier Commun (ingenieurs, developpeurs) ===${RESET}"
ID_COMMUN="$(nc_mount 'Commun' /mnt/nextcloud/Commun)"
nc_groups "$ID_COMMUN" ingenieurs developpeurs
echo "Commun -> stockage $ID_COMMUN"

echo "${CYAN}=== Accès restreint au Commun (managers, lecture seule) ===${RESET}"
ID_COMMUN_RO="$(nc_mount 'Commun' /mnt/nextcloud/Commun)"
nc_groups "$ID_COMMUN_RO" managers
occ files_external:option "$ID_COMMUN_RO" readonly true
echo "Commun (lecture seule) -> stockage $ID_COMMUN_RO"

systemctl restart apache2

echo "${CYAN}=== Vérifications ===${RESET}"
occ files:scan --all
occ files_external:list

# Vérification de fin
#-------------------------------------------------------------------------------
echo
echo "${BLEU}=== Sommaire des services ===${RESET}"
ERREURS=0

verif() {   
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "  %-34s ${VERT}[ OK ]${RESET}
" "$desc"
    else
        printf "  %-34s ${ROUGE}[ ERREUR ]${RESET}
" "$desc"
        ERREURS=$((ERREURS + 1))
    fi
}

nc_installed() { occ status | grep -q 'installed: true'; }
nc_https()     { wget -qO- --no-check-certificate "https://localhost/status.php" | grep -q '"installed":true'; }
ldap_ok()      { occ ldap:test-config s01 | grep -q 'configuration is valid'; }
storages_ok()  { occ files_external:list | grep -q Clients; }
nfs_ok()       { for d in Clients Commun Logiciels Perso; do mountpoint -q "/mnt/nextcloud/$d" || return 1; done; }

verif "SSH"                          systemctl is-active --quiet ssh
verif "Apache2"                      systemctl is-active --quiet apache2
verif "MariaDB"                      systemctl is-active --quiet mariadb
verif "Nextcloud installé"           nc_installed
verif "Nextcloud en HTTPS (SSL)"     nc_https
verif "Liaison OpenLDAP (s01)"       ldap_ok
verif "Montages NFS (4 dossiers)"    nfs_ok
verif "Partages Nextcloud"           storages_ok

echo
if [ "$ERREURS" -eq 0 ]; then
    echo "${VERT}  >>> Tous les services sont actifs : tout est OK <<<${RESET}"
else
    echo "${ROUGE}  >>> $ERREURS vérification(s) en erreur <<<${RESET}"
fi

echo
echo "${VERT}================================================================${RESET}"
echo "${VERT} SRV-LIN1-02 installé avec succès.${RESET}"
echo " Nextcloud : https://${IP_SRV}/nextcloud   (compte : ${NC_ADMIN})"
echo " Mots de passe (base de données + ${NC_ADMIN}) : ${PASS_FILE}"
echo "${VERT}================================================================${RESET}"
cat "$PASS_FILE"
