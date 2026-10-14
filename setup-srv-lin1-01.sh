#!/usr/bin/env bash
#===============================================================================
# SRV-LIN1-01 - Debian 13
#
# Fonseca Diogo Christophe
# 12.10.2026
#
# Usage (en root) :
#   SSH_PUBKEY='ssh-rsa AAAA... user@pc' LDAP_ADMIN_PASS='xxx' ./setup-srv-lin1-01.sh
#===============================================================================
set -e
export PATH="$PATH:/sbin:/usr/sbin:/bin:/usr/bin"
export DEBIAN_FRONTEND=noninteractive

# Couleurs
BLEU=$'\e[1;34m'; CYAN=$'\e[36m'; VERT=$'\e[1;32m'; ROUGE=$'\e[1;31m'; RESET=$'\e[0m'

[ "$(id -u)" -eq 0 ] || { echo "${ROUGE}Lance ce script en root.${RESET}"; exit 1; }

if [ -z "$LDAP_ADMIN_PASS" ]; then
    read -rsp "Mot de passe administrateur LDAP : " LDAP_ADMIN_PASS; echo
fi
[ -n "$LDAP_ADMIN_PASS" ] || { echo "${ROUGE}Mot de passe LDAP vide.${RESET}"; exit 1; }

# Update et upgrade de la machine
#-------------------------------------------------------------------------------
echo "${BLEU}=== Mise à jour du système ===${RESET}"
# Met en commentaire la première ligne du cd dans sources-list 
sed -i '1{/^#/!s/^/# /}' /etc/apt/sources.list
apt update && apt upgrade -y
apt install -y nftables

# Configuration réseau de base
#-------------------------------------------------------------------------------
echo "${BLEU}=== Configuration de la deuxième carte réseau (ens34) ===${RESET}"
# Active l’interface LAN ens34, utilisée par les clients internes.
ip link set ens34 up

cat > /etc/network/interfaces.d/ens34 <<'EOF'
auto ens34
iface ens34 inet static 
	address 10.10.10.11
	netmask 255.255.255.0
	dns-nameservers 127.0.0.1
EOF

systemctl restart networking

#Configuration Key SSH
#-------------------------------------------------------------------------------
echo "${BLEU}=== Authentification par clé ===${RESET}"
# Prépare le répertoire SSH de root avec des permissions restrictives.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [ -n "$SSH_PUBKEY" ]; then
    echo "$SSH_PUBKEY" >> ~/.ssh/authorized_keys
fi
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Configuration Routage
#-------------------------------------------------------------------------------
echo "${BLEU}=== Activation du routage ===${RESET}"
# Active le transfert IPv4 pour faire de ce serveur la passerelle du réseau interne.
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-router.conf
sysctl --system

# Construit une règle NAT masquerade pour permettre au LAN de sortir via ens33.
/usr/sbin/nft flush ruleset
/usr/sbin/nft add table ip nat
/usr/sbin/nft add chain ip nat postrouting '{ type nat hook postrouting priority 100; }'
/usr/sbin/nft add rule ip nat postrouting oif "ens33" masquerade

echo "flush ruleset" > /etc/nftables.conf
/usr/sbin/nft list ruleset >> /etc/nftables.conf

systemctl enable --now nftables
/usr/sbin/nft list ruleset

# Configuration DNS
#-------------------------------------------------------------------------------
echo "${BLEU}=== Installation DNS (BIND9) ===${RESET}"
apt install bind9 bind9-utils dnsutils -y
systemctl status bind9 --no-pager

# Ajout de la configuration DNS 
cat > /etc/bind/named.conf.options <<'EOF'
acl "Intern-Network" {
    127.0.0.1;
    10.10.10.0/24;
};

options {
    directory "/var/cache/bind";

    // Permet à BIND d'utiliser l'interface LAN (ens34) et WAN (ens33)
    listen-on port 53 { any; };
    listen-on-v6 { none; };

    // Sécurité : Seuls les clients du LAN ont le droit de faire des query
    allow-query {
        Intern-Network;
    };

    // Résolution récursive vers Internet
    recursion yes; 
    allow-recursion { Intern-Network; };

    // Redirection pour accélérer les requêtes Internet (Passe par ens33)
    forwarders {
        1.1.1.1;
        8.8.8.8;
    };

    allow-transfer {
        none;
    };
};
EOF

# Les forwarders ne sont pas les mêmes si vous lancez le script au CPNV. Le CPNV va les bloquer à cause des FW.

named-checkconf /etc/bind/named.conf
systemctl restart bind9

# Configuration Zones DNS
#-------------------------------------------------------------------------------
echo "${CYAN}--- Configuration des zones ---${RESET}"
cat > /etc/bind/named.conf.local <<'EOF'
zone "LIN1-Christophe.local" {
    type master;
    file "/etc/bind/db.LIN1-Christophe.local";
    allow-query { Intern-Network; };
    allow-transfer { none; };
};

zone "10.10.10.in-addr.arpa" {
    type master;
    file "/etc/bind/db.10.10.10";
    allow-query { Intern-Network; };
    allow-transfer { none; };
};
EOF

# Zone directe
cat > /etc/bind/db.LIN1-Christophe.local <<'EOF'
$TTL 86400

@   IN  SOA srv-lin1-01.LIN1-Christophe.local. admin.LIN1-Christophe.local. (
        2026082301 ; Serial
        3600       ; Refresh
        1800       ; Retry
        604800     ; Expire
        86400      ; Minimum TTL
)

; Serveur DNS
@           IN  NS      srv-lin1-01.LIN1-Christophe.local.

; Serveurs
srv-lin1-01 IN  A       10.10.10.11
srv-lin1-02 IN  A       10.10.10.22

; NAS
nas-lin1-01 IN  A       10.10.10.33
EOF

# Zone inverse
cat > /etc/bind/db.10.10.10 <<'EOF'
$TTL 86400

@   IN  SOA srv-lin1-01.LIN1-Christophe.local. admin.LIN1-Christophe.local. (
        2026082301 ; Serial
        3600       ; Refresh
        1800       ; Retry
        604800     ; Expire
        86400      ; Minimum TTL
)

; Serveur DNS
@       IN  NS      srv-lin1-01.LIN1-Christophe.local.

; Enregistrements PTR
11      IN  PTR     srv-lin1-01.LIN1-Christophe.local.
22      IN  PTR     srv-lin1-02.LIN1-Christophe.local.
33      IN  PTR     nas-lin1-01.LIN1-Christophe.local.
EOF

# Vérifie les zones DNS directe et inverse avant de recharger BIND.
named-checkzone LIN1-Christophe.local /etc/bind/db.LIN1-Christophe.local
named-checkzone 10.10.10.in-addr.arpa /etc/bind/db.10.10.10
systemctl reload bind9

# Check DNS
#-------------------------------------------------------------------------------
echo "${CYAN}--- Tests DNS (zone directe) ---${RESET}"
dig @10.10.10.11 srv-lin1-01.LIN1-Christophe.local +short
dig @10.10.10.11 srv-lin1-02.LIN1-Christophe.local +short
dig @10.10.10.11 nas-lin1-01.LIN1-Christophe.local +short
echo "${CYAN}--- Tests DNS (zone inverse) ---${RESET}"
dig @10.10.10.11 -x 10.10.10.11 +short
dig @10.10.10.11 -x 10.10.10.22 +short
dig @10.10.10.11 -x 10.10.10.33 +short

# Configuration DHCP
#-------------------------------------------------------------------------------
echo "${BLEU}=== Installation DHCP (Kea) ===${RESET}"
# Installe Kea DHCPv4, qui distribuera les adresses du pool configuré aux clients du LAN.
apt -y install kea-dhcp4-server
[ -f /etc/kea/kea-dhcp4.conf.org ] || cp /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.org

cat > /etc/kea/kea-dhcp4.conf <<'EOF'
{
  "Dhcp4": {

    // Interface réseau utilisée par Kea
    "interfaces-config": {
      "interfaces": [ "ens34" ]
    },
    
    // Gestion automatique des baux DHCP expirés
    "expired-leases-processing": {
      "reclaim-timer-wait-time": 10,
      "flush-reclaimed-timer-wait-time": 25,
      "hold-reclaimed-time": 3600,
      "max-reclaim-leases": 100,
      "max-reclaim-time": 250,
      "unwarned-reclaim-cycles": 5
    },

    // Gestion du renouvellement des baux DHCP
    "renew-timer": 900,
    "rebind-timer": 1800,
    "valid-lifetime": 3600,

    // Paramètres transmis aux clients DHCP
    "option-data": [
      {
        "name": "domain-name-servers",
        "data": "10.10.10.11"
      },
      {
        "name": "domain-name",
        "data": "LIN1-Christophe.local"
      },
      {
        "name": "domain-search",
        "data": "LIN1-Christophe.local"
      }
    ],

    // Configuration du réseau et de la plage DHCP
    "subnet4": [
      {
        "id": 1,
        "subnet": "10.10.10.0/24",

        "pools": [
          {
            "pool": "10.10.10.110 - 10.10.10.130"
          }
        ],

        "option-data": [
          {
            "name": "routers",
            "data": "10.10.10.11"
          }
        ]
      }
    ],

    // Journalisation des événements DHCP
    "loggers": [
      {
        "name": "kea-dhcp4",
        "output_options": [
          {
            "output": "/var/log/kea/kea-dhcp4.log"
          }
        ],
        "severity": "INFO",
        "debuglevel": 0
      }
    ]
  }
}
EOF

systemctl restart kea-dhcp4-server
systemctl status kea-dhcp4-server --no-pager

# Configuration OpenLDAP
#-------------------------------------------------------------------------------
echo "${BLEU}=== Installation OpenLDAP ===${RESET}"
# Réponses aux écrans de slapd 
debconf-set-selections <<EOF
slapd slapd/internal/generated_adminpw password $LDAP_ADMIN_PASS
slapd slapd/internal/adminpw password $LDAP_ADMIN_PASS
slapd slapd/password1 password $LDAP_ADMIN_PASS
slapd slapd/password2 password $LDAP_ADMIN_PASS
slapd slapd/domain string LIN1-Christophe.local
slapd shared/organization string LIN1-Christophe
slapd slapd/backend select MDB
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
slapd slapd/no_configuration boolean false
EOF
apt install -y slapd ldap-utils

dpkg-reconfigure -f noninteractive slapd

# Vérifie que la base LDAP est accessible après l’installation.
ldapsearch -x -b "dc=LIN1-Christophe,dc=local" -s base

# Injection des datas dans l'OpenLDAP
echo "${CYAN}--- Injection des données ---${RESET}"
# Prépare le LDIF contenant les unités organisationnelles, groupes et comptes LDAP à créer.
cat > /tmp/Arborescence.ldif <<'EOF'
# OU user
dn: ou=users,dc=LIN1-Christophe,dc=local
objectClass: organizationalUnit
ou: users

# OU groups
dn: ou=groups,dc=LIN1-Christophe,dc=local
objectClass: organizationalUnit
ou: groups

# OU services
dn: ou=services,dc=LIN1-Christophe,dc=local
objectClass: organizationalUnit
ou: services

# Groupe managers
dn: cn=managers,ou=groups,dc=LIN1-Christophe,dc=local
objectClass: posixGroup
cn: managers
gidNumber: 5001
memberUid: man01
memberUid: man02

# Groupe ingenieurs
dn: cn=ingenieurs,ou=groups,dc=LIN1-Christophe,dc=local
objectClass: posixGroup
cn: ingenieurs
gidNumber: 5002
memberUid: ing01
memberUid: ing02

# Groupe dev
dn: cn=developpeurs,ou=groups,dc=LIN1-Christophe,dc=local
objectClass: posixGroup
cn: developpeurs
gidNumber: 5003
memberUid: dev01

# Groupe services
dn: cn=services,ou=services,dc=LIN1-Christophe,dc=local
objectClass: posixGroup
cn: services
gidNumber: 5004
memberUid: nxtcloud
memberUid: truenas

# User man01
dn: uid=man01,ou=users,dc=LIN1-Christophe,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: man01
sn: Manager
givenName: Un
cn: Manager Un
uidNumber: 10001
gidNumber: 5001
shadowLastChange: 20690
loginShell: /bin/bash
homeDirectory: /home/man01

# User man02
dn: uid=man02,ou=users,dc=LIN1-Christophe,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: man02
sn: Manager
givenName: Deux
cn: Manager Deux
uidNumber: 10002
gidNumber: 5001
shadowLastChange: 20690
loginShell: /bin/bash
homeDirectory: /home/man02

# User ing01
dn: uid=ing01,ou=users,dc=LIN1-Christophe,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ing01
sn: Ingenieur
givenName: Un
cn: Ingenieur Un
uidNumber: 10003
gidNumber: 5002
shadowLastChange: 20690
loginShell: /bin/bash
homeDirectory: /home/ing01

# User ing02
dn: uid=ing02,ou=users,dc=LIN1-Christophe,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ing02
sn: Ingenieur
givenName: Deux
cn: Ingenieur Deux
uidNumber: 10004
gidNumber: 5002
shadowLastChange: 20690
loginShell: /bin/bash
homeDirectory: /home/ing02

# User Dev01
dn: uid=dev01,ou=users,dc=LIN1-Christophe,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: dev01
sn: Developpeur
givenName: Un
cn: Developpeur Un
uidNumber: 10005
gidNumber: 5003
shadowLastChange: 20690
loginShell: /bin/bash
homeDirectory: /home/dev01

# User Nxtcloud
dn: uid=nxtcloud,ou=services,dc=LIN1-Christophe,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: nxtcloud
sn: Next
givenName: Cloud
cn: Next Cloud
uidNumber: 10006
gidNumber: 5004
shadowLastChange: 20690
loginShell: /bin/bash
homeDirectory: /home/nxtcloud

# User Truenas
dn: uid=truenas,ou=services,dc=LIN1-Christophe,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: truenas
sn: True
givenName: Nas
cn: True Nas
uidNumber: 10007
gidNumber: 5004
shadowLastChange: 20690
loginShell: /bin/bash
homeDirectory: /home/truenas

#Userlam
dn: uid=adminlam,ou=services,dc=LIN1-Christophe,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: adminlam
sn: Lam
givenName: Admin
cn: Admin Lam
uidNumber: 10008
gidNumber: 5004
shadowLastChange: 20690
loginShell: /bin/bash
homeDirectory: /home/adminlam
EOF

# Ajuste les ACL LDAP pour autoriser l’administration locale et l’accès en lecture aux autres clients autorisés.
cat <<'EOF' | ldapmodify -Y EXTERNAL -H ldapi:///
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.exact="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" write by dn.exact="cn=admin,dc=LIN1-Christophe,dc=local" write by * read
EOF

ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/Arborescence.ldif

# Fichier qui regroupe tous les mots de passe générés, attention au reboot de la machine le fichier disparait.
MDP_FILE=/tmp/mdp-ldap.txt
: > "$MDP_FILE"
chmod 600 "$MDP_FILE"

# Génération des mots de passe pour les users
for user in man01 man02 ing01 ing02 dev01; do
  PASS=$(openssl rand -base64 12)
  ldappasswd -Y EXTERNAL -H ldapi:/// -s "$PASS" "uid=$user,ou=users,dc=LIN1-Christophe,dc=local" > /dev/null
  echo "Utilisateur $user -> Mot de passe : $PASS" | tee -a "$MDP_FILE"
done

# Génération des mots de passe pour les comptes de service.
for service in nxtcloud truenas adminlam; do
  PASS=$(openssl rand -base64 16)
  ldappasswd -Y EXTERNAL -H ldapi:/// -s "$PASS" "uid=$service,ou=services,dc=LIN1-Christophe,dc=local" > /dev/null
  echo "Service $service     -> Mot de passe : $PASS" | tee -a "$MDP_FILE"
done

ldapsearch -Y EXTERNAL -H ldapi:/// -b "dc=LIN1-Christophe,dc=local" "(objectClass=posixAccount)" uid

rm -f /tmp/grant_root.ldif /tmp/Arborescence.ldif

# Configuration de LAM
#-------------------------------------------------------------------------------
echo "${BLEU}=== Installation LAM ===${RESET}"
# Installe Apache et l’interface Web LDAP Account Manager (LAM).
apt install -y apache2 ldap-account-manager
systemctl enable --now apache2
systemctl status apache2 --no-pager

echo "${CYAN}--- Configuration de LAM (profil par défaut) ---${RESET}"
# Configure le profil LAM pour utiliser la base LDAP de ce domaine.
LAM_CONF=/var/lib/ldap-account-manager/config/lam.conf
BASE="dc=LIN1-Christophe,dc=local"

# lam.conf est un fichier JSON, on remplace uniquement des valeurs
cp -n "$LAM_CONF" "$LAM_CONF.org"
lam_json() {   # lam_json <clé> <valeur>
    if grep -q "\"$1\": \"" "$LAM_CONF"; then
        sed -i "s|\"$1\": \"[^\"]*\"|\"$1\": \"$2\"|" "$LAM_CONF"
        echo "  $1 -> $2"
    else
        echo "${ROUGE}  [!] clé \"$1\" introuvable dans lam.conf : à régler dans l'interface web${RESET}"
    fi
}

# Tool settings : Tree suffix dans LAM
lam_json "treeViewSuffix"      "$BASE"
# Active account types : LDAP suffix des Users et des Groups
lam_json "suffix_user"         "ou=users,$BASE"
lam_json "suffix_group"        "ou=groups,$BASE"
# Connexion avec les comptes LDAP (adminlam) : recherche par uid
lam_json "loginMethod"         "search"
lam_json "loginSearchSuffix"   "$BASE"
lam_json "loginSearchFilter"   "uid=%USER%"

# Mot de passe du profil LAM (remplace le mot de passe par défaut "lam")
cp "$LAM_CONF" "$LAM_CONF.avant-mdp"
LAM_PASS=$(openssl rand -base64 12 | tr -d '/+=\n')
LAM_HASH="{CRYPT-SHA512}$(openssl passwd -6 "$LAM_PASS")"
sed -i "s|\"Passwd\": \"[^\"]*\"|\"Passwd\": \"$LAM_HASH\"|" "$LAM_CONF"

# Vérification : on relit le hash écrit dans le fichier et on le recalcule
LAM_STORED=$(grep -o '"Passwd": "[^"]*"' "$LAM_CONF" | sed 's/^"Passwd": "{CRYPT-SHA512}//; s/"$//')
LAM_SALT=$(echo "$LAM_STORED" | cut -d'$' -f3)
if [ -n "$LAM_SALT" ] && [ "$(openssl passwd -6 -salt "$LAM_SALT" "$LAM_PASS")" = "$LAM_STORED" ]; then
    echo "  Passwd -> nouveau mot de passe de profil enregistré"
    echo "Mot de passe du profil LAM : $LAM_PASS" | tee -a "$MDP_FILE"
else
    cat "$LAM_CONF.avant-mdp" > "$LAM_CONF"
    echo "${ROUGE}  [!] mot de passe du profil non modifié (reste : lam) : à changer dans l'interface web${RESET}"
fi

#-------------------------------------------------------------------------------
echo
echo "${BLEU}=== Sommaire des services ===${RESET}"
ERREURS=0

verif() {   # verif "Description" commande...
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "  %-32s ${VERT}[ OK ]${RESET}\n" "$desc"
    else
        printf "  %-32s ${ROUGE}[ ERREUR ]${RESET}\n" "$desc"
        ERREURS=$((ERREURS + 1))
    fi
}

# Vérification de fin pour savoir si tous les services sont UP.
verif "SSH"                         systemctl is-active --quiet ssh
verif "Pare-feu / NAT (nftables)"   systemctl is-active --quiet nftables
verif "DNS (BIND9)"                 systemctl is-active --quiet bind9
verif "DHCP (Kea)"                  systemctl is-active --quiet kea-dhcp4-server
verif "LDAP (OpenLDAP)"             systemctl is-active --quiet slapd
verif "Web (Apache2 / LAM)"         systemctl is-active --quiet apache2
verif "Réseau ens34 (10.10.10.11)"  bash -c 'ip -4 -br addr show ens34 | grep -q "10.10.10.11"'
verif "Routage IPv4 activé"         bash -c '[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]'

echo
if [ "$ERREURS" -eq 0 ]; then
    echo "${VERT}  >>> Tous les services sont actifs : tout est OK <<<${RESET}"
else
    echo "${ROUGE}  >>> $ERREURS vérification(s) en erreur <<<${RESET}"
fi

echo
echo "${VERT}================================================================${RESET}"
echo "${VERT} Serveur SRV-LIN1-01 installé.${RESET}"
echo " Mots de passe (LDAP + profil LAM) enregistrés dans : $MDP_FILE"
echo " LAM : http://10.10.10.11/lam  (connexion avec adminlam)"
echo "${VERT}================================================================${RESET}"
