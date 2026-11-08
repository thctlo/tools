#!/usr/bin/env bash
#
# backup-testvps.sh
#
# Nightly backup of everything on this server that is not reproducible by
# just reinstalling packages + rerunning server-setup.sh: the three live
# MariaDB databases (dumped properly, see below), and whole directories
# rather than a curated list of paths within them - a curated list keeps
# missing things (round 1 missed /etc/nginx and /etc/postfix entirely;
# round 2 would have missed /var/lib/fail2ban, /var/lib/redis, the
# grommunio-files/-admin-api/-web state under /var/lib, and the postfix
# mail queue in /var/spool). So: all of /etc, all of /var/lib, all of
# /var/spool, minus a short explicit exclude list for the handful of
# large directories that are either redundant with the mysqldumps below
# or pure disposable cache (see EXCLUDES).
#
# Not run by server-setup.sh - this is an ongoing operational script, not a
# one-time provisioning step. Install it on its own (see "One-time setup"
# below), run manually once to check it, then put it on a systemd timer.
#
# Pushes to a BorgBackup repo on a *different* VPS over SSH - deduplicated,
# compressed, encrypted. Nothing is kept unencrypted once it leaves this
# server; the local staging copy (plain SQL dumps) is deleted again after
# each successful run, so an attacker who only has this server never has
# the dumps sitting around either.
#
# ============================================================
# One-time setup (do this by hand before the first run; this script does
# not do it for you, since it is destructive/initialising state):
#
#   1. On the REMOTE VPS, pick a dedicated path for the repo, e.g.
#      /srv/borg-backups/testvps. The remote side just needs `borg`
#      installed (or even just SSH + `borg serve` via
#      authorized_keys command="borg serve --restrict-to-path
#      /srv/borg-backups/testvps --append-only", which also stops this
#      server from ever being able to delete/tamper with old backups even
#      if it is compromised - recommended).
#   2. On THIS server: generate a passphrase and save it where only root
#      can read it:
#        umask 077; openssl rand -base64 48 > /root/cfg-server/borg-passphrase.txt
#   3. Set BORG_REPO below to ssh://<user>@<remote-host>/srv/borg-backups/testvps
#   4. Make sure root on this server can SSH to that user@host without a
#      password prompt (a dedicated ed25519 key, added to that user's
#      authorized_keys on the remote VPS - ideally restricted to just the
#      borg serve command above).
#   5. Initialise the repo (ONCE):
#        BORG_PASSCOMMAND="cat /root/cfg-server/borg-passphrase.txt" \
#          borg init --encryption=repokey-blake2 "$BORG_REPO"
#      (repokey: the encryption key lives inside the repo, protected by the
#      passphrase above - back up "borg key export" output somewhere too,
#      e.g. printed and kept offline, so a lost passphrase file plus a lost
#      repo copy does not mean a permanently unreadable backup.)
#   6. Run this script once by hand, check it ends with "Backup OK", then
#      enable the systemd timer (see the .service/.timer files alongside
#      this script, or add them yourself).
# ============================================================

set -euo pipefail

# --- Configuration -------------------------------------------------------
BORG_REPO="ssh://CHANGE_ME@CHANGE_ME:22/srv/borg-backups/testvps"
BORG_PASSCOMMAND="cat /root/cfg-server/borg-passphrase.txt"
export BORG_REPO BORG_PASSCOMMAND
export BORG_RSH="ssh -i /root/.ssh/id_ed25519_borg"

STAGING="/root/backup-staging"
LOCKFILE="/run/backup-testvps.lock"
LOGFILE="/var/log/backup-testvps.log"

MYSQL_DBS=(grommunio grofiles grommunio_keycloak)

# Whole directories, relative to /. See the comment at the top for why
# this is "everything except an exclude list", not a curated include list.
PATHS=(
    etc
    var/lib
    var/spool
    root/cfg-server
)

# Excluded because mysqldump above already covers this properly (a live
# copy of /var/lib/mysql is not a safe way to back up a running database),
# or because it is pure cache that is cheaply rebuilt/redownloaded and not
# worth the space (sizes checked live on testvps 2026-10-17):
#   var/lib/mysql        193M  - covered by mysqldump above
#   var/lib/postgresql     55M  - empty default DBs only (chat removed); nothing real here
#   var/lib/clamav        168M  - virus signatures, freshclam redownloads them daily
#   var/lib/apt           160M  - package manager cache, reproducible from the repo
#   var/lib/dpkg           31M  - package manager metadata, reproducible by reinstalling
#   var/lib/plocate       3.8M  - locate(1) index, rebuilt by updatedb
EXCLUDES=(
    var/lib/mysql
    var/lib/postgresql
    var/lib/clamav
    var/lib/apt
    var/lib/dpkg
    var/lib/plocate
)

# --- Helpers ---------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }
die()  { log "ERROR: $*"; exit 1; }

cleanup() {
    rm -rf "$STAGING"
    rm -f "$LOCKFILE"
}
trap cleanup EXIT

# --- Guard against overlapping runs ---------------------------------------
if [[ -e "$LOCKFILE" ]]; then
    die "Lock file $LOCKFILE already exists - another run in progress, or a previous run crashed without cleaning up. Check and remove it by hand if the latter."
fi
touch "$LOCKFILE"

[[ "$(id -u)" -eq 0 ]] || die "Must run as root (reads /etc/letsencrypt, /var/lib/rspamd/dkim, mysqldump via debian.cnf)."
command -v borg >/dev/null || die "borg is not installed (apt install borgbackup)."

log "=== Starting backup ==="

# --- Stage the database dumps ----------------------------------------------
# Dumped to plain files first (not piped directly into borg create) so one
# failed dump does not leave a half-written archive - the archive is only
# created once every dump below has already succeeded.
rm -rf "$STAGING"
mkdir -p "$STAGING/mysql"
chmod 700 "$STAGING"

for db in "${MYSQL_DBS[@]}"; do
    log "Dumping MariaDB database: $db"
    # --databases (not just the bare db name) makes the dump self-contained:
    # it includes CREATE DATABASE IF NOT EXISTS + USE, so restoring is just
    # "zcat file.sql.gz | mariadb" with no separate create-database step.
    mysqldump --defaults-file=/etc/mysql/debian.cnf \
        --single-transaction --quick --routines --triggers \
        --databases "$db" | gzip -9 > "$STAGING/mysql/${db}.sql.gz" \
        || die "mysqldump failed for database $db"
done

# The app databases above do NOT include the MySQL user accounts
# themselves (grommunio/grofiles/grommunio_keycloak as MySQL *connection*
# credentials) - those live in the mysql system database, which we
# deliberately do not back up as a raw datadir (var/lib/mysql is excluded
# above - a live copy of it is not a safe way to back it up). Without
# this, a restore onto a freshly provisioned server - which generates its
# own new random MySQL passwords - would restore /etc/dbconfig-common's
# OLD passwords while MySQL itself has NEW ones: the exact
# password-mismatch class of bug from the grommunio-files incident
# (2026-10-12), this time for every app at once. --system=users dumps
# CREATE USER + GRANT as portable, replayable SQL (confirmed on this
# server's MariaDB 11.8.6; verified it includes the password hash and the
# per-database GRANT, not just the bare account).
log "Dumping MariaDB user accounts/grants (--system=users)"
mariadb-dump --defaults-file=/etc/mysql/debian.cnf --system=users \
    | gzip -9 > "$STAGING/mysql/_users-and-grants.sql.gz" \
    || die "mariadb-dump --system=users failed"

# --- Create the archive -----------------------------------------------------
ARCHIVE_NAME="testvps-$(date '+%Y-%m-%d_%H%M%S')"
log "Creating Borg archive: $ARCHIVE_NAME"

BORG_EXCLUDE_ARGS=()
for ex in "${EXCLUDES[@]}"; do
    BORG_EXCLUDE_ARGS+=(--exclude "$ex")
done

borg create \
    --stats --compression zstd,6 \
    -C / \
    "${BORG_REPO}::${ARCHIVE_NAME}" \
    "${STAGING#/}" \
    "${PATHS[@]}" \
    "${BORG_EXCLUDE_ARGS[@]}" \
    --exclude 're:\.sock$' \
    --one-file-system \
    --exclude-caches \
    --warning \
    2>&1 | tee -a "$LOGFILE" \
    || die "borg create failed"

# --- Prune old archives ------------------------------------------------------
log "Pruning old archives (keep 14 daily / 8 weekly / 6 monthly)"
borg prune --stats \
    --keep-daily 14 --keep-weekly 8 --keep-monthly 6 \
    "$BORG_REPO" \
    2>&1 | tee -a "$LOGFILE" \
    || die "borg prune failed"

log "Compacting repo (reclaim space from pruned archives)"
borg compact "$BORG_REPO" 2>&1 | tee -a "$LOGFILE" || log "WARNING: borg compact failed (non-fatal, retried next run)"

log "=== Backup OK: $ARCHIVE_NAME ==="
