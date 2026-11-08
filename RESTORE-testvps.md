# Restore procedure for testvps (from a backup-testvps.sh/Borg backup)

This is deliberately **not** an automated script — a restore is a decision
point (which server, which archive, what gets overwritten), not something to
run blind. Follow these steps in this order.

**Prerequisite:** the new server has already had a complete, successful
`server-setup.sh` run (all packages, system users, systemd units already
exist). This restore **overlays** state on top of that — it does not replace
the provisioning.

**Rule 0, always: use exactly ONE Borg archive for the entire restore.**
Never combine one night's database dump with another night's files — the
users/domains in the `grommunio` database and the exmdb files in
`/var/lib/gromox` must match up by ID.

```
borg list "$BORG_REPO"                      # pick the archive
mkdir /root/restore-scratch && cd /root/restore-scratch
borg extract "$BORG_REPO::<archive-name>"   # extracts into the current directory
```

## Step 1 — stop services

Stop everything that touches the state being restored. Keep MariaDB running
(needed to load the dumps):

```
systemctl stop nginx postfix \
    grommunio-admin-api grommunio-keycloak \
    gromox-http gromox-zcore gromox-delivery gromox-delivery-queue \
    gromox-midb gromox-timer gromox-imap gromox-pop3 \
    php8.4-fpm saslauthd rspamd
```

## Step 2 — MySQL users/grants FIRST, then the 3 databases

This must happen in this order: accounts first (with the old passwords), then
the data — otherwise the application user can't even log in to see the data
(which doesn't matter for the restore itself, since you restore as root via
`debian.cnf`, but the ACCOUNTS still need to be correct for the applications
that connect again afterward).

```
zcat mysql/_users-and-grants.sql.gz | mariadb --defaults-file=/etc/mysql/debian.cnf
zcat mysql/grommunio.sql.gz          | mariadb --defaults-file=/etc/mysql/debian.cnf
zcat mysql/grofiles.sql.gz           | mariadb --defaults-file=/etc/mysql/debian.cnf
zcat mysql/grommunio_keycloak.sql.gz | mariadb --defaults-file=/etc/mysql/debian.cnf
```

(Each dump contains its own `CREATE DATABASE IF NOT EXISTS` + `USE`, so no
separate creation step is needed.)

**Immediately afterward, verify** that the passwords in
`/etc/dbconfig-common/*.conf` and `/etc/grommunio-keycloak/keycloak.conf`
(restored in step 4) match what's now in MySQL — this should already be
correct, since both come from the same archive, but check it anyway
(`mariadb -u grofiles -p<password-from-conf> grofiles -e "SELECT 1;"` etc.)
before continuing.

## Step 3 — files: gromox, rspamd/DKIM, postfix queue, cfg-server

```
cp -a var/lib/gromox/.       /var/lib/gromox/
cp -a var/lib/rspamd/.       /var/lib/rspamd/
cp -a var/spool/postfix/.    /var/spool/postfix/
cp -a root/cfg-server/.      /root/cfg-server/
chown -R postfix:postdrop /var/spool/postfix   # cp -a usually preserves ownership correctly, but verify
```

## Step 4 — `/etc`: do NOT blindly overwrite everything

The backup contains the **entire** `/etc` of the old server — including
things that are machine-specific and should (correctly!) be different on a
new server. Skip these unless you deliberately want to take over the old
server's identity (e.g. to avoid SSH "host key changed" warnings if the same
DNS name points at this new server):

- `etc/fstab` — the old server's disk UUIDs; restoring this can break
  mounting on the new server.
- `etc/hostname`, `etc/machine-id`
- `etc/netplan/`, `etc/network/`, `etc/systemd/network/` — network config
  tied to the old MAC addresses/interface names.
- `etc/ssh/ssh_host_*` — SSH host keys (deliberately taking these over is a
  choice, not something to do automatically).

Then restore the rest of `/etc`, e.g.:

```
rsync -a --exclude='fstab' --exclude='hostname' --exclude='machine-id' \
    --exclude='netplan/' --exclude='network/' --exclude='systemd/network/' \
    --exclude='ssh/ssh_host_*' \
    etc/ /etc/
```

## Step 5 — restart services

```
systemctl daemon-reload
systemctl start saslauthd rspamd php8.4-fpm \
    gromox-event.service gromox-zcore gromox-midb gromox-http \
    gromox-imap gromox-pop3 gromox-delivery gromox-delivery-queue gromox-timer \
    grommunio-admin-api grommunio-keycloak postfix nginx
```

(Or simply `reboot` — `60-boot-order.sh` already handles the correct order.)

## Step 6 — verify

- `grommunio-admin-api`: `curl -sk https://localhost:8443/api/v1/status` → database:true
- Keycloak: log in with the password from `/root/cfg-server/keycloak-admin-password.txt`
- Send/receive a test email, open webmail, check an existing message/contact is visible
- `fail2ban-client status` — should start up normally again (state comes
  from `/var/lib/fail2ban`, already restored in step 3 via the full
  `var/lib` restore)

**Not done yet: this runbook has not actually been tested on a disposable
VM yet.** Do that before relying on it — this procedure is as complete as I
can currently make it on paper, but "correct on paper" is not the same as
"it works".
