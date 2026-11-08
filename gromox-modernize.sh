
#!/usr/bin/env bash
#
# Gromox 3.13.x configuration modernization
# Debian / grommunio
#
# Usage:
#   ./gromox-modernize.sh apply
#   ./gromox-modernize.sh status
#   ./gromox-modernize.sh revert
#   ./gromox-modernize.sh revert /var/backups/gromox-modernize.DATE

set -Eeuo pipefail

DIR="/etc/gromox"
BACKUP_ROOT="/var/backups"
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

backup_config() {
    local backup="$1"
    mkdir -m 700 -p "$backup"

    for file in "${FILES[@]}"; do
        if [[ -f "$DIR/$file" ]]; then
            cp -a "$DIR/$file" "$backup/$file"
        fi
    done

    printf '%s\n' "${FILES[@]}" > "$backup/files.list"
    chmod 600 "$backup/files.list"

    log "Backup created: $backup"
}

restore_config() {
    local backup="$1"
    local file

    [[ -f "$backup/files.list" ]] ||
        die "Invalid backup: $backup"

    while IFS= read -r file; do
        if [[ -f "$backup/$file" ]]; then
            cp -a "$backup/$file" "$DIR/$file"
        else
            rm -f "$DIR/$file"
        fi
    done < "$backup/files.list"

    log "Original configuration restored."
}

apply_config() {
    local backup
    local changed

    backup="$BACKUP_ROOT/gromox-modernize.$(date +%Y%m%d-%H%M%S)"

    backup_config "$backup"

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
        "http_support_ssl": "http_support_tls",
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
        restore_config "$backup"
        die "No migration applied."
    fi

    echo "$changed"

    if [[ "$changed" == *"No deprecated listener directives found."* ]]; then
        log "Nothing to migrate."
        return
    fi

    if ! restart_services; then
        warn "A service failed. Rolling back all configuration."
        restore_config "$backup"
        restart_services || true
        die "Migration rolled back."
    fi

    log "Migration completed successfully."
    log "Backup: $backup"
}

revert_config() {
    local backup="${2:-}"

    if [[ -z "$backup" ]]; then
        backup=$(find "$BACKUP_ROOT" -maxdepth 1 \
            -type d -name 'gromox-modernize.*' \
            -printf '%T@ %p\n' |
            sort -nr | head -n1 | cut -d' ' -f2-)
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
