#!/bin/bash
# autoban-status.sh - View autoban status, recent bans, and manage the blocklist
# Usage:
#   autoban-status.sh              - Show summary
#   autoban-status.sh list         - List all currently banned IPs
#   autoban-status.sh unban IP     - Remove an IP from the ban list
#   autoban-status.sh flush        - Remove ALL bans (use with caution)
#   autoban-status.sh test IP      - Check if an IP is currently banned
#   autoban-status.sh top          - Show top offenders from log

set -euo pipefail

IPSET=/usr/sbin/ipset
IPTABLES=/usr/sbin/iptables
IPSET_NAME="autoban"
BAN_LOG="/var/log/autoban.log"

case "${1:-summary}" in
    summary|status)
        echo "=== Autoban Status ==="
        if $IPSET list "$IPSET_NAME" &>/dev/null; then
            total=$($IPSET list "$IPSET_NAME" | grep -c '^[0-9]' 2>/dev/null || echo 0)
            echo "Currently banned IPs: $total"
            echo ""
            echo "--- iptables rule ---"
            $IPTABLES -L INPUT -n --line-numbers 2>/dev/null | grep "$IPSET_NAME" || echo "(no iptables rule found)"
            echo ""
            echo "--- Last 10 bans ---"
            tail -10 "$BAN_LOG" 2>/dev/null || echo "(no ban log yet)"
        else
            echo "ipset '$IPSET_NAME' does not exist. Run autoban.sh first."
        fi
        ;;
    list)
        if $IPSET list "$IPSET_NAME" &>/dev/null; then
            echo "Currently banned IPs (with remaining timeout):"
            $IPSET list "$IPSET_NAME" | grep '^[0-9]' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n
        else
            echo "ipset '$IPSET_NAME' does not exist."
        fi
        ;;
    unban)
        ip="${2:-}"
        if [[ -z "$ip" ]]; then
            echo "Usage: $0 unban <IP>"
            exit 1
        fi
        if $IPSET del "$IPSET_NAME" "$ip" 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') UNBANNED $ip (manual)" | tee -a "$BAN_LOG"
        else
            echo "IP $ip was not in the ban list."
        fi
        ;;
    flush)
        read -p "This will remove ALL banned IPs. Are you sure? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            $IPSET flush "$IPSET_NAME"
            echo "$(date '+%Y-%m-%d %H:%M:%S') FLUSHED all bans (manual)" | tee -a "$BAN_LOG"
        else
            echo "Cancelled."
        fi
        ;;
    test)
        ip="${2:-}"
        if [[ -z "$ip" ]]; then
            echo "Usage: $0 test <IP>"
            exit 1
        fi
        if $IPSET test "$IPSET_NAME" "$ip" 2>/dev/null; then
            echo "$ip is BANNED"
            $IPSET list "$IPSET_NAME" | grep "^$ip " || true
        else
            echo "$ip is NOT banned"
        fi
        ;;
    top)
        echo "=== Top 20 offenders (from ban log) ==="
        grep "BANNED" "$BAN_LOG" 2>/dev/null | awk '{print $3}' | sort | uniq -c | sort -rn | head -20
        ;;
    *)
        echo "Usage: $0 {summary|list|unban IP|flush|test IP|top}"
        exit 1
        ;;
esac
