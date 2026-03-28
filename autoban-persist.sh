#!/bin/bash
# autoban-persist.sh - Save/restore ipset across reboots
# Usage:
#   autoban-persist.sh save     - Save current ipset to disk
#   autoban-persist.sh restore  - Restore ipset from disk

set -euo pipefail

IPSET=$(command -v ipset || echo /sbin/ipset)
IPTABLES=$(command -v iptables || echo /sbin/iptables)
IPSET_NAME="autoban"
SAVE_FILE="/etc/autoban/ipset-autoban.save"
BAN_DURATION=86400

case "${1:-}" in
    save)
        if $IPSET list "$IPSET_NAME" &>/dev/null; then
            $IPSET save "$IPSET_NAME" > "$SAVE_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') Saved ipset $IPSET_NAME ($($IPSET list "$IPSET_NAME" | grep -c '^[0-9]' || echo 0) entries)"
        fi
        ;;
    restore)
        # Create ipset if it doesn't exist
        if ! $IPSET list "$IPSET_NAME" &>/dev/null; then
            $IPSET create "$IPSET_NAME" hash:ip timeout "$BAN_DURATION" maxelem 65536
        fi
        # Restore saved entries
        if [[ -f "$SAVE_FILE" ]]; then
            # Use -! to ignore errors for entries that already exist
            $IPSET restore -! < "$SAVE_FILE" 2>/dev/null || true
            echo "$(date '+%Y-%m-%d %H:%M:%S') Restored ipset $IPSET_NAME from $SAVE_FILE"
        fi
        # Ensure iptables rule exists
        if ! $IPTABLES -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP 2>/dev/null; then
            $IPTABLES -I INPUT 1 -m set --match-set "$IPSET_NAME" src -j DROP
        fi
        ;;
    *)
        echo "Usage: $0 {save|restore}"
        exit 1
        ;;
esac
