# Restore-procedure voor testvps (vanuit een backup-testvps.sh/Borg-backup)

Dit is géén geautomatiseerd script — bewust, want een restore is een
beslismoment (welke server, welk archief, wat overschrijf je), niet iets
om blind te laten draaien. Volg deze stappen in deze volgorde.

**Voorwaarde:** de nieuwe server heeft al een volledige, succesvolle
`server-setup.sh`-run gehad (alle pakketten, systeemgebruikers, systemd-units
bestaan al). Deze restore **overlegt** state daarop, hij vervangt de
provisioning niet.

**Regel 0, altijd: gebruik precies ÉÉN Borg-archief voor de hele restore.**
Nooit een databasedump van de ene nacht combineren met bestanden van een
andere — de gebruikers/domeinen in de `grommunio`-database en de
exmdb-bestanden in `/var/lib/gromox` moeten qua ID's bij elkaar passen.

```
borg list "$BORG_REPO"                      # kies het archief
mkdir /root/restore-scratch && cd /root/restore-scratch
borg extract "$BORG_REPO::<archief-naam>"   # pakt uit in de huidige map
```

## Stap 1 — diensten stoppen

Stop alles dat de te herstellen state aanraakt. MariaDB blijft draaien
(nodig om de dumps in te laden):

```
systemctl stop nginx postfix \
    grommunio-admin-api grommunio-keycloak \
    gromox-http gromox-zcore gromox-delivery gromox-delivery-queue \
    gromox-midb gromox-timer gromox-imap gromox-pop3 \
    php8.4-fpm saslauthd rspamd
```

## Stap 2 — MySQL-gebruikers/rechten EERST, dan de 3 databases

Dit moet in deze volgorde: eerst de accounts (met de oude wachtwoorden),
dan de data — anders kun je als de app-gebruiker niet eens inloggen om de
data te zien (en dat is precies niet het punt, je herstelt als root via
`debian.cnf`, maar de ACCOUNTS moeten alsnog kloppen voor de apps die er
straks weer mee verbinden).

```
zcat mysql/_users-and-grants.sql.gz | mariadb --defaults-file=/etc/mysql/debian.cnf
zcat mysql/grommunio.sql.gz          | mariadb --defaults-file=/etc/mysql/debian.cnf
zcat mysql/grofiles.sql.gz           | mariadb --defaults-file=/etc/mysql/debian.cnf
zcat mysql/grommunio_keycloak.sql.gz | mariadb --defaults-file=/etc/mysql/debian.cnf
```

(Elke dump bevat zijn eigen `CREATE DATABASE IF NOT EXISTS` + `USE`, dus
geen losse aanmaak-stap nodig.)

**Controleer daarna meteen** dat de wachtwoorden in `/etc/dbconfig-common/*.conf`
en `/etc/grommunio-keycloak/keycloak.conf` (die je in stap 4 terugzet)
overeenkomen met wat er nu in MySQL staat — dat zou moeten kloppen, want
beide komen uit hetzelfde archief, maar controleer het (`mariadb -u grofiles
-p<wachtwoord-uit-conf> grofiles -e "SELECT 1;"` enz.) voor je verder gaat.

## Stap 3 — bestanden: gromox, rspamd/DKIM, postfix-queue, cfg-server

```
cp -a var/lib/gromox/.       /var/lib/gromox/
cp -a var/lib/rspamd/.       /var/lib/rspamd/
cp -a var/spool/postfix/.    /var/spool/postfix/
cp -a root/cfg-server/.      /root/cfg-server/
chown -R postfix:postdrop /var/spool/postfix   # cp -a bewaart eigenaar meestal goed, controleer het wel
```

## Stap 4 — `/etc`: NIET blind alles overschrijven

De backup bevat de **hele** `/etc` van de oude server — inclusief dingen
die machine-specifiek zijn en op een nieuwe server anders (en correct!)
horen te zijn. Sla deze over, tenzij je bewust de identiteit van de oude
server wilt overnemen (bijv. om SSH "host key changed"-waarschuwingen te
voorkomen als dezelfde DNS-naam naar deze nieuwe server wijst):

- `etc/fstab` — schijf-UUID's van de oude server; dit teruggooien kan het
  mounten op de nieuwe server breken.
- `etc/hostname`, `etc/machine-id`
- `etc/netplan/`, `etc/network/`, `etc/systemd/network/` — netwerkconfig
  gebonden aan de oude MAC-adressen/interfacenamen.
- `etc/ssh/ssh_host_*` — SSH-hostkeys (bewust overnemen is een keuze, geen
  automatisme).

Zet daarna de rest van `/etc` terug, bijv.:

```
rsync -a --exclude='fstab' --exclude='hostname' --exclude='machine-id' \
    --exclude='netplan/' --exclude='network/' --exclude='systemd/network/' \
    --exclude='ssh/ssh_host_*' \
    etc/ /etc/
```

## Stap 5 — diensten herstarten

```
systemctl daemon-reload
systemctl start saslauthd rspamd php8.4-fpm \
    gromox-event.service gromox-zcore gromox-midb gromox-http \
    gromox-imap gromox-pop3 gromox-delivery gromox-delivery-queue gromox-timer \
    grommunio-admin-api grommunio-keycloak postfix nginx
```

(Of simpelweg `reboot` — `60-boot-order.sh` regelt de juiste volgorde al.)

## Stap 6 — controleren

- `grommunio-admin-api`: `curl -sk https://localhost:8443/api/v1/status` → database:true
- Keycloak: inloggen met het wachtwoord uit `/root/cfg-server/keycloak-admin-password.txt`
- Een testmail versturen/ontvangen, webmail openen, een bestaand bericht/contact zien
- `fail2ban-client status` — moet weer normaal opstarten (state komt uit `/var/lib/fail2ban`, al herstelt in stap 3 via de volledige `var/lib`-restore)

**Nog niet gedaan: dit draaiboek is nog niet echt getest op een wegwerp-VM.**
Doe dat voor je hierop vertrouwt — deze procedure is zo compleet als ik 'm nu
kan bedenken, maar "op papier klopt het" is niet hetzelfde als "het werkt".
