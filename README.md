# Déploiement de l’infrastructure Linux

> **Attention — scripts d’administration système :** ces scripts modifient la configuration réseau et les services, installent des paquets et peuvent toucher au stockage. Le script NAS configure notamment un RAID 1 et un système de fichiers. Vérifiez les interfaces, adresses IP, disques et paramètres avant l’exécution. Faites une sauvegarde et assurez-vous de disposer d’un accès console en cas de perte de connectivité.

## 1. Prérequis

- Un poste Windows avec OpenSSH disponible (`scp` et `ssh` dans PowerShell ou Windows Terminal).
- Un accès SSH au serveur cible avec un compte.
- Les scripts `.sh` correspondants disponibles sur le poste Windows.
- Les mots de passe et la clé publique SSH nécessaires, prêts avant le lancement.

Vérifiez d’abord la connexion SSH :

```powershell
ssh user@IP
```

Remplacez l’adresse IP et le compte si nécessaire. Quittez ensuite la session avec `exit`.

## 2. Copier un script vers le serveur avec SCP

Depuis **PowerShell sur Windows**, la commande suivante copie le script dans `/tmp/` du serveur :

```powershell
scp "C:\Users\user\Downloads\script.sh" user@IP:/tmp/
```

À la fin du transfert, connectez-vous au serveur via VMware et rendez le fichier exécutable :

```bash  
chmod +x fichier.sh
```
Répétez le transfert pour chaque script et vers l’adresse IP du serveur auquel il est destiné.

## 3. Scripts et ordre de déploiement

| Script | Rôle principal | Prérequis / remarque |
|---|---|---|
| `setup-srv-lin1-01.sh` | Configure le serveur Debian : réseau, routage/NAT, DNS BIND9, DHCP Kea, OpenLDAP et interface LAM. | Préparer la clé SSH et le mot de passe administrateur LDAP. |
| `setup-nas-lin1-01.sh` | Configure le NAS sous OpenMediaVault : réseau, RAID 1, ext4 avec quotas, dossiers partagés, ACL et exports NFS. | Vérifier soigneusement les disques ciblés et confirmer l’opération RAID. |
| `setup-srv-lin1-02.sh` | Configure le serveur Nextcloud : IP statique, montages NFS, serveur web/base de données, HTTPS et liaison LDAP. | Le script indique que `SRV-LIN1-01` (DNS/DHCP/LDAP) et `NAS-LIN1-01` (OMV) doivent déjà être installés. |

**Ordre conseillé :**

1. Déployer et valider `SRV-LIN1-01`.
2. Déployer et valider `NAS-LIN1-01`.
3. Déployer `SRV-LIN1-02` lorsque le NAS, les exports NFS, le DNS et LDAP sont opérationnels.

Cet ordre est une recommandation pratique basée sur les dépendances déclarées par le script Nextcloud. Vérifiez l’adressage IP et les paramètres propres à votre environnement avant chaque étape.

## 4. Les paramètres

Les scripts acceptent certains paramètres via des variables d’environnement.

`setup-srv-lin1-01.sh`
```bash
SSH_PUBKEY='ssh-rsa AAAA... user@pc' LDAP_ADMIN_PASS='xxx' ./setup-srv-lin1-01.sh
```
`setup-nas-lin1-01.sh` 
```bash
SSH_PUBKEY='ssh-rsa AAAA... user@pc' CONFIRM_RAID=oui REBOOT_AT_END=oui ./setup-nas-lin1-01.sh
```
`setup-srv-lin1-02.sh`
```bash
SSH_PUBKEY='ssh-rsa AAAA...' NXTCLOUD_LDAP_PASS='xxx' ./setup-srv-lin1-02.sh
```

Les scripts doivent être lancés avec les privilèges root. Utilisez une clé publique complète et des mots de passe adaptés à votre environnement.

## 4. Conclusion

Les scripts permettent de tout automatiser. En exécutant les trois scripts l'environnement entier est mis en place. 
