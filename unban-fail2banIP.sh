
#!/bin/bash

# Unban IP from all Fail2ban jails

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

IP="${1:-}"

if [[ -z "$IP" ]]; then
    read -rp "IP address: " IP
fi

if ! python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$IP" 2>/dev/null; then
    echo "Invalid IP: $IP"
    exit 1
fi

JAILS=$(fail2ban-client status |
    sed -n 's/.*Jail list:[[:space:]]*//p' |
    tr ',' ' ')

[[ -n "$JAILS" ]] || { echo "No jails found."; exit 1; }

echo
echo "Unbanning: $IP"
echo

REMOVED=0
NOT_BANNED=0

for jail in $JAILS; do
    BANNED=$(fail2ban-client get "$jail" banip 2>/dev/null)

    if echo "$BANNED" | grep -Fwq -- "$IP"; then
        fail2ban-client set "$jail" unbanip "$IP" >/dev/null 2>&1
        echo "[UNBANNED] $jail"
        ((REMOVED+=1))
    else
        echo "[NOT BANNED] $jail"
        ((NOT_BANNED+=1))
    fi
done

echo
echo "Finished: $IP"
echo "Removed: $REMOVED | Not banned: $NOT_BANNED"
