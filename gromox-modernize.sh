
#!/usr/bin/env bash
#
# Gromox 3.13.x configuration modernization
# Debian / grommunio
#
# Usage:
#   ./gromox-modernize.sh apply
#   ./gromox-modernize.sh status
#   ./gromox-modernize.sh revert
#   ./gromox-modernize.sh revert /root/backups/<run-timestamp>

set -Eeuo pipefail

DIR="/etc/gromox"

# Same convention as the server-setup.sh framework's own backup_file()
# (functions/00-common.sh there): one timestamped run directory under
# /root/backups/, each backed-up file keeping its full original path
# underneath it, a manifest listing what was touched. Reimplemented
# here rather than sourced from that repo on purpose - this tool is
# meant to stand on its own (a separate repo from the provisioning
# framework), not depend on it being checked out at some known path.
RUN_TIMESTAMP="${RUN_TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/backups/${RUN_TIMESTAMP}}"
MANIFEST_FILE="${BACKUP_ROOT}/modified-files.txt"

SERVICES=(
    gromox-http
    gromox-imap
    gromox-pop3
    gromox-delivery-queue
)

FILES=(
    gromox.cfg
    http.cfg
    imap.cfg
    pop3.cfg
    smtp.cfg
)

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
command -v python3 >/dev/null || die "Python3 required."
command -v systemctl >/dev/null || die "systemctl required."
[[ -f "$DIR/gromox.cfg" ]] || die "Missing gromox.cfg"

restart_services() {
    local service
    local failed=0

    for service in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log "Restarting $service"

            if ! systemctl restart "$service"; then
                warn "Failed to restart $service"
                failed=1
            fi

            if ! systemctl is-active --quiet "$service"; then
                warn "$service is not active"
                failed=1
            fi
        fi
    done

    return "$failed"
}

# backup_file <absolute path> / finalize_backup <same path> - ported
# verbatim from functions/00-common.sh in the server-setup.sh repo (see
# note above RUN_TIMESTAMP). Not idempotent across repeated touches of
# the same file WITHIN one run on purpose: the first backup is the true
# pre-run original; a later touch in the same run appends .1, .2, .3...
# instead of overwriting it.
#
# This tool backs up ALL managed files up front (backup_all_files, before
# even knowing which ones the migration will actually touch - the Python
# step below only knows that after inspecting them). finalize_backup
# (called via finalize_all_files, after the migration has run) removes
# the backup+manifest line again for any file that turned out byte-
# identical, so a no-op run (the common case - most config files already
# have nothing deprecated left to migrate) doesn't leave 5 pointless
# fresh backups behind every single time this is run.
# Tracked per-target-path (not a single last-call slot): backup_all_files
# below backs up several files in a batch before any of them are
# written, so a single-slot "last backup" variable would only ever let
# finalize_all_files correctly finalize the LAST file in that batch -
# found and fixed while testing this against the real batch call
# pattern here, not a hypothetical.
declare -A _BACKUP_DEST_FOR

backup_file()
{
    local target="$1"
    unset '_BACKUP_DEST_FOR[$target]' 2>/dev/null
    [[ -e "$target" ]] || return 0
    local dest="${BACKUP_ROOT}${target}"
    mkdir -p "$(dirname "$dest")"
    if [[ -e "$dest" ]]; then
        local n=1
        while [[ -e "${dest}.${n}" ]]; do
            n=$((n + 1))
        done
        dest="${dest}.${n}"
    fi
    cp -a "$target" "$dest"
    mkdir -p "$(dirname "$MANIFEST_FILE")"
    printf '%-40s %-50s %s\n' "$(basename "$0")" "$target" "$dest" >> "$MANIFEST_FILE"
    _BACKUP_DEST_FOR["$target"]="$dest"
}

finalize_backup()
{
    local target="$1"
    local dest="${_BACKUP_DEST_FOR[$target]:-}"
    [[ -n "$dest" ]] || return 0
    [[ -e "$target" && -e "$dest" ]] || return 0
    if cmp -s "$target" "$dest"; then
        rm -f "$dest"
        if [[ -f "$MANIFEST_FILE" ]]; then
            # grep -v exits 1 (not an error here) when the filtered
            # result is empty - the "|| true" matters even without an
            # explicit "&&" after it: under set -e (this whole script
            # has it), a bare command returning non-zero still aborts
            # the whole script, found live when this was the only
            # remaining manifest line.
            grep -vF "$dest" "$MANIFEST_FILE" > "${MANIFEST_FILE}.tmp" 2>/dev/null || true
            mv "${MANIFEST_FILE}.tmp" "$MANIFEST_FILE"
        fi
    fi
    unset '_BACKUP_DEST_FOR[$target]'
}

print_backup_manifest()
{
    echo
    echo "------------------------------------------------------------"
    echo "Files modified this run"
    echo "------------------------------------------------------------"
    if [[ -s "$MANIFEST_FILE" ]]; then
        column -t "$MANIFEST_FILE" 2>/dev/null || cat "$MANIFEST_FILE"
        echo
        echo "Originals backed up under: $BACKUP_ROOT"
        echo "This list: $MANIFEST_FILE"
    else
        echo "(none yet)"
    fi
    echo
}

backup_all_files() {
    for file in "${FILES[@]}"; do
        if [[ -f "$DIR/$file" ]]; then
            backup_file "$DIR/$file"
        fi
    done
    log "Backups (if any files existed) written under: $BACKUP_ROOT"
}

# finalize_all_files: call once after the migration step has finished
# writing (or not writing) each managed file - see backup_file's comment
# above for why this exists. Must be called with the SAME $DIR/$file
# pairing backup_all_files just used, in the same run.
finalize_all_files() {
    local file
    for file in "${FILES[@]}"; do
        if [[ -f "$DIR/$file" ]]; then
            finalize_backup "$DIR/$file"
        fi
    done
}

# restore_config <backup-run-directory>
#
# Restores every tracked file found under <backup-run-directory>'s own
# mirrored path (<backup>/etc/gromox/<file>) back to $DIR. Unlike
# backup_file's own numbered-suffix files (.1, .2, ...), which only
# matter if the SAME run touched a file more than once (this tool
# never does), the plain (no-suffix) copy is always the correct one to
# restore - the true state from before that run started.
restore_config() {
    local backup="$1"
    local file

    [[ -d "$backup$DIR" ]] ||
        die "Invalid backup: $backup$DIR not found."

    for file in "${FILES[@]}"; do
        if [[ -f "$backup$DIR/$file" ]]; then
            cp -a "$backup$DIR/$file" "$DIR/$file"
        else
            rm -f "$DIR/$file"
        fi
    done

    log "Original configuration restored from $backup."
}

apply_config() {
    local changed

    backup_all_files

    log "Inspecting and migrating legacy directives..."

    if ! changed=$(python3 - "$DIR" <<'PY'
import os
import re
import sys
import tempfile

directory = sys.argv[1]

# old directive -> new directive
# Port values are converted to bind-address:port notation.

rules = {
    "http.cfg": {
        "listen_port": "http_listen",
        "listen_ssl_port": "http_listen_tls",
        "http_listen_port": "http_listen",
        "http_listen_tls_port": "http_listen_tls",
    },
    "imap.cfg": {
        "imap_listen_port": "imap_listen",
        "imap_listen_tls_port": "imap_listen_tls",
    },
    "pop3.cfg": {
        "pop3_listen_port": "pop3_listen",
        "pop3_listen_tls_port": "pop3_listen_tls",
    },
    "smtp.cfg": {
        "lda_listen_port": "lda_listen",
        "lda_listen_tls_port": "lda_listen_tls",
    },
}

# Directives that rename IN PLACE within the same file - NOT moved to
# gromox.cfg like the listen_* keys above. Confirmed via http.8gx's own
# man page section headers: "Configuration directives (gromox.cfg)" vs
# "Configuration directives (http.cfg)" are two distinct, separately
# documented lists, and http_support_tls is only ever documented under
# the http.cfg one. An earlier version of this script wrongly moved it
# to gromox.cfg, same as the listen_* keys - gromox-http's own code
# only ever reads http_support_tls from http.cfg, so it then found
# nothing there (NULL), which parse_bool() treats as false, silently
# deactivating TLS ("TLS support deactivated via config") regardless
# of the stray "http_support_tls=true" left behind in gromox.cfg.
rename_in_place = {
    "http.cfg": {
        "http_support_ssl": "http_support_tls",
    },
}

def read_file(path):
    with open(path, encoding="utf-8") as f:
        return f.readlines()

def find_keys(lines, key):
    result = []
    pattern = re.compile(
        r"^\s*" + re.escape(key) + r"\s*=\s*(.*?)\s*$"
    )

    for index, line in enumerate(lines):
        match = pattern.match(line)
        if match:
            result.append((index, match.group(1)))

    return result

def bind_value(value):
    value = value.strip()

    # Numeric port: bind on all interfaces.
    if value.isdigit():
        return f"[::]:{value}"

    # Already an address/port specification.
    return value

paths = {
    name: os.path.join(directory, name)
    for name in ["gromox.cfg", *rules.keys()]
    if os.path.isfile(os.path.join(directory, name))
}

contents = {name: read_file(path) for name, path in paths.items()}

if "gromox.cfg" not in contents:
    raise SystemExit("Missing gromox.cfg")

target = contents["gromox.cfg"][:]
remove_indices = {}
appended_lines = {}
migrations = []

# Check all source directives and conflicts before writing anything.

for filename, mapping in rules.items():
    if filename not in contents:
        continue

    source = contents[filename]
    remove_indices[filename] = set()

    for old, new in mapping.items():
        matches = find_keys(source, old)

        if len(matches) > 1:
            raise SystemExit(
                f"Duplicate directive {old} in {filename}"
            )

        if not matches:
            continue

        index, value = matches[0]

        if old.endswith("_port") and old != "http_support_ssl":
            value = bind_value(value)

        existing = find_keys(target, new)

        if len(existing) > 1:
            raise SystemExit(
                f"Duplicate target directive {new} in gromox.cfg"
            )

        if existing and existing[0][1] != value:
            raise SystemExit(
                f"Conflict: {new} already exists with value "
                f"{existing[0][1]}, migration requires {value}"
            )

        if not existing:
            if target and not target[-1].endswith("\n"):
                target[-1] += "\n"

            target.append(f"{new}={value}\n")

        remove_indices[filename].add(index)
        migrations.append(f"{filename}: {old} -> {new}={value}")

# Same-file renames (see rename_in_place above) - the old key's line is
# removed and the new key is appended to the SAME file, never moved to
# gromox.cfg (mirrors the move-based loop above, just targeting the
# original file as its own "target" instead of gromox.cfg - this is
# deliberately not a direct in-place line rewrite: that would mutate
# contents[filename] as a side effect before the final "did this file
# actually change" comparison runs, silently defeating it).
#
# Also self-heals a server that already ran an earlier, buggy version
# of this script that WRONGLY moved one of these keys into gromox.cfg
# (exactly what happened to http_support_tls before this fix): if the
# new key is found there instead of in its proper file, it is pulled
# back out of gromox.cfg's target and placed into the proper file
# where gromox's own code actually reads it from.

for filename, mapping in rename_in_place.items():
    if filename not in contents:
        continue

    source = contents[filename]
    remove_indices.setdefault(filename, set())
    appended_lines.setdefault(filename, [])

    for old, new in mapping.items():
        matches = find_keys(source, old)

        if len(matches) > 1:
            raise SystemExit(f"Duplicate directive {old} in {filename}")

        existing_new = find_keys(source, new)
        if len(existing_new) > 1:
            raise SystemExit(f"Duplicate directive {new} in {filename}")

        stray_in_gromox = find_keys(target, new)
        if len(stray_in_gromox) > 1:
            raise SystemExit(f"Duplicate directive {new} in gromox.cfg")

        if existing_new:
            # Already correct in this file. A stray leftover copy in
            # gromox.cfg (from the old buggy migration) is cleaned up
            # regardless of whether the old key is still present here.
            if stray_in_gromox:
                if stray_in_gromox[0][1] != existing_new[0][1]:
                    raise SystemExit(
                        f"Conflict: {new} in gromox.cfg "
                        f"({stray_in_gromox[0][1]}) does not match the "
                        f"one already in {filename} ({existing_new[0][1]})"
                    )
                del target[stray_in_gromox[0][0]]
                migrations.append(
                    f"gromox.cfg: removed stray {new} (belongs in {filename})"
                )
            if matches:
                remove_indices[filename].add(matches[0][0])
                migrations.append(f"{filename}: removed stray duplicate {old}")
            continue

        if matches:
            # Fresh system: old key still present in its original file.
            index, value = matches[0]
        elif stray_in_gromox:
            # Already (wrongly) migrated to gromox.cfg by an earlier
            # buggy run - recover the value from there instead.
            index, value = None, stray_in_gromox[0][1]
            del target[stray_in_gromox[0][0]]
            migrations.append(
                f"gromox.cfg: removed stray {new} (belongs in {filename})"
            )
        else:
            continue

        if index is not None:
            remove_indices[filename].add(index)

        appended_lines[filename].append(f"{new}={value}\n")
        migrations.append(f"{filename}: {old} -> {new}={value}")

# Check for deprecated address directives that need manual handling.

address_keys = {
    "http.cfg": ["http_listen_addr"],
    "imap.cfg": ["imap_listen_addr"],
    "pop3.cfg": ["pop3_listen_addr"],
    "smtp.cfg": ["lda_listen_addr"],
}

for filename, keys in address_keys.items():
    if filename not in contents:
        continue

    for key in keys:
        if find_keys(contents[filename], key):
            print(
                f"WARNING: {filename} contains {key}; "
                "review its bind address manually.",
                file=sys.stderr
            )

if not migrations:
    print("No deprecated listener directives found.")
    sys.exit(0)

new_contents = {"gromox.cfg": target}

for filename, indices in remove_indices.items():
    new_contents[filename] = [
        line for index, line in enumerate(contents[filename])
        if index not in indices
    ]

for filename, lines_to_add in appended_lines.items():
    if not lines_to_add:
        continue
    existing = new_contents.setdefault(filename, contents[filename][:])
    if existing and not existing[-1].endswith("\n"):
        existing[-1] += "\n"
    new_contents[filename] = existing + lines_to_add

# Write files atomically, preserving ownership and permissions.

written = []

try:
    for filename, lines in new_contents.items():
        if lines == contents[filename]:
            continue

        path = paths[filename]
        st = os.stat(path)

        fd, tmp = tempfile.mkstemp(dir=directory)

        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(lines)
            f.flush()
            os.fsync(f.fileno())

        os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, path)
        written.append(filename)

except Exception:
    print("ERROR: write failed; restoring backup is required.",
          file=sys.stderr)
    raise

for item in migrations:
    print("MIGRATED:", item)

print("CHANGED:", ",".join(written))

PY
    ); then
        warn "Migration failed. Restoring backup."
        restore_config "$BACKUP_ROOT"
        die "No migration applied."
    fi

    echo "$changed"

    if [[ "$changed" == *"No deprecated listener directives found."* ]]; then
        log "Nothing to migrate."
        finalize_all_files
        return
    fi

    if ! restart_services; then
        warn "A service failed. Rolling back all configuration."
        restore_config "$BACKUP_ROOT"
        restart_services || true
        die "Migration rolled back."
    fi

    finalize_all_files
    log "Migration completed successfully."
    print_backup_manifest
}

revert_config() {
    local backup="${2:-}"

    if [[ -z "$backup" ]]; then
        # /root/backups/<timestamp>/ is a shared namespace (the same
        # one server-setup.sh's own backup_file() writes to) - look
        # specifically for a run that actually backed up gromox.cfg,
        # not just any timestamped directory.
        backup=$(find /root/backups -maxdepth 1 -type d -name '[0-9]*' \
            -printf '%T@ %p\n' 2>/dev/null |
            sort -nr |
            while read -r _ dir; do
                [[ -f "${dir}${DIR}/gromox.cfg" ]] && { echo "$dir"; break; }
            done)
    fi

    [[ -n "$backup" && -d "$backup" ]] ||
        die "No backup found."

    echo "Restore configuration from:"
    echo "$backup"
    read -r -p "Type YES to continue: " answer

    [[ "$answer" == "YES" ]] || die "Cancelled."

    restore_config "$backup"

    restart_services ||
        die "Configuration restored, but one or more services failed."
    
    log "Revert completed."
}

show_status() {
    echo "Gromox configuration"
    echo "====================="

    for file in "${FILES[@]}"; do
        [[ -f "$DIR/$file" ]] || continue

        echo
        echo "--- $file ---"

        grep -nE \
          '(^|[[:space:]])(listen_port|listen_ssl_port|http_listen_port|http_listen_tls_port|imap_listen_port|imap_listen_tls_port|pop3_listen_port|pop3_listen_tls_port|lda_listen_port|lda_listen_tls_port|http_support_ssl|http_support_tls|http_listen|imap_listen|pop3_listen|lda_listen)[[:space:]]*=' \
          "$DIR/$file" || true
    done

    echo
    echo "--- Active Gromox services ---"

    for service in "${SERVICES[@]}"; do
        systemctl is-active "$service" 2>/dev/null || true
    done

    echo
    echo "--- Listening ports ---"
    ss -lntp | grep -E 'gromox|:10080|:10443|:993|:995|:25|:24' || true
}

case "${1:-}" in
    apply)
        apply_config
        ;;
    revert)
        revert_config "$@"
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage:"
        echo "$0 apply"
        echo "$0 status"
        echo "$0 revert [backup-directory]"
        exit 1
        ;;
esac
