#!/bin/bash
# autoban-status.sh - View autoban status, recent bans, and manage the blocklist
# Usage:
#   autoban-status.sh              - Show summary + usage
#   autoban-status.sh list         - List all currently banned IPs
#   autoban-status.sh ban IP       - Manually ban an IP
#   autoban-status.sh unban IP     - Remove an IP from the ban list
#   autoban-status.sh flush        - Remove ALL bans (use with caution)
#   autoban-status.sh test IP      - Check if an IP is currently banned
#   autoban-status.sh why IP       - Show ban history and matched URLs for an IP
#   autoban-status.sh top          - Show top offenders from log
#   autoban-status.sh reinstall DIR- Reinstall from source dir (preserves bans)

set -euo pipefail

IPSET=$(command -v ipset || echo /sbin/ipset)
IPTABLES=$(command -v iptables || echo /sbin/iptables)
IPSET_NAME="autoban"
SAVE_FILE="/etc/autoban/ipset-autoban.save"
BAN_LOG="/var/log/autoban.log"
BAN_DURATION=86400

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
        echo ""
        echo "Usage:"
        echo "  autoban                    - Show this summary"
        echo "  autoban list               - List all banned IPs"
        echo "  autoban ban IP             - Manually ban an IP"
        echo "  autoban unban IP           - Unban a specific IP"
        echo "  autoban test IP            - Check if an IP is banned"
        echo "  autoban why IP             - Show ban history & matched URLs"
        echo "  autoban top                - Show top repeat offenders"
        echo "  autoban flush              - Remove all bans"
        echo "  autoban reinstall DIR      - Reinstall from source (preserves bans)"
        ;;
    ban)
        ip="${2:-}"
        if [[ -z "$ip" ]]; then
            echo "Usage: $0 ban <IP>"
            exit 1
        fi
        if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Invalid IP address: $ip"
            exit 1
        fi
        if $IPSET test "$IPSET_NAME" "$ip" 2>/dev/null; then
            echo "$ip is already banned."
        elif $IPSET add "$IPSET_NAME" "$ip" timeout "$BAN_DURATION" 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') BANNED $ip (manual, duration=${BAN_DURATION}s)" | tee -a "$BAN_LOG"
            $IPSET save "$IPSET_NAME" > "$SAVE_FILE" 2>/dev/null || true
        else
            echo "Failed to ban $ip. Is the ipset '$IPSET_NAME' created?"
            exit 1
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
            # Update persist file so the IP doesn't return on restore
            $IPSET save "$IPSET_NAME" > "$SAVE_FILE" 2>/dev/null || true
        else
            echo "IP $ip was not in the ban list."
        fi
        ;;
    flush)
        read -p "This will remove ALL banned IPs. Are you sure? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            $IPSET flush "$IPSET_NAME"
            echo "$(date '+%Y-%m-%d %H:%M:%S') FLUSHED all bans (manual)" | tee -a "$BAN_LOG"
            $IPSET save "$IPSET_NAME" > "$SAVE_FILE" 2>/dev/null || true
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
    why)
        ip="${2:-}"
        if [[ -z "$ip" ]]; then
            echo "Usage: $0 why <IP>"
            exit 1
        fi
        echo "=== Ban history for $ip ==="
        grep "BANNED $ip " "$BAN_LOG" 2>/dev/null || echo "No ban records found for $ip"
        ;;
    top)
        echo "=== Top 20 offenders (from ban log) ==="
        grep "BANNED" "$BAN_LOG" 2>/dev/null | awk '{print $3}' | sort | uniq -c | sort -rn | head -20
        ;;
    reinstall)
        src_dir="${2:-/tmp/autoban}"
        if [[ ! -d "$src_dir" ]]; then
            echo "Source directory not found: $src_dir"
            exit 1
        fi
        for f in autoban.sh autoban-status.sh autoban-persist.sh banned.txt; do
            if [[ ! -f "$src_dir/$f" ]]; then
                echo "Missing required file: $src_dir/$f"
                exit 1
            fi
        done

        INSTALL_DIR="/etc/autoban"

        echo "=== Reinstalling Autoban ==="
        echo "Source: $src_dir"
        echo "Target: $INSTALL_DIR"
        echo ""

        # Copy scripts and banned URL list
        echo "[1/4] Updating scripts ..."
        cp "$src_dir/autoban.sh"         "$INSTALL_DIR/autoban.sh"
        cp "$src_dir/autoban-persist.sh" "$INSTALL_DIR/autoban-persist.sh"
        cp "$src_dir/autoban-status.sh"  "$INSTALL_DIR/autoban-status.sh"
        cp "$src_dir/banned.txt"         "$INSTALL_DIR/banned.txt"
        chmod +x "$INSTALL_DIR/autoban.sh"
        chmod +x "$INSTALL_DIR/autoban-persist.sh"
        chmod +x "$INSTALL_DIR/autoban-status.sh"

        # Preserve whitelist - only copy if it doesn't exist
        if [[ ! -f "$INSTALL_DIR/whitelist.txt" ]] && [[ -f "$src_dir/whitelist.txt" ]]; then
            cp "$src_dir/whitelist.txt" "$INSTALL_DIR/whitelist.txt"
            echo "  Copied initial whitelist"
        else
            echo "  Whitelist preserved"
        fi

        # Ensure symlink is current
        echo "[2/4] Updating CLI shortcut ..."
        ln -sf "$INSTALL_DIR/autoban-status.sh" /usr/local/bin/autoban

        # Refresh cron entries
        echo "[3/4] Refreshing cron ..."
        CRON_LINE="* * * * * /etc/autoban/autoban.sh >> /var/log/autoban.log 2>&1"
        PERSIST_LINE="0 */6 * * * /etc/autoban/autoban-persist.sh save >> /var/log/autoban.log 2>&1"
        REBOOT_LINE="@reboot /etc/autoban/autoban-persist.sh restore >> /var/log/autoban.log 2>&1"
        (crontab -l 2>/dev/null | grep -v '/etc/autoban/'; echo "$CRON_LINE"; echo "$PERSIST_LINE"; echo "$REBOOT_LINE") | crontab -

        # Show what was preserved
        echo "[4/4] Verifying ..."
        if $IPSET list "$IPSET_NAME" &>/dev/null; then
            total=$($IPSET list "$IPSET_NAME" | grep -c '^[0-9]' 2>/dev/null || echo 0)
            echo "  ipset intact: $total IPs still banned"
        fi
        echo "  Log positions preserved"
        echo ""
        echo "=== Reinstall Complete ==="
        ;;
    *)
        echo "Usage: $0 {summary|list|ban IP|unban IP|flush|test IP|why IP|top|reinstall DIR}"
        exit 1
        ;;
esac
