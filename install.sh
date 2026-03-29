#!/bin/bash
# install.sh - Install autoban on the server
# Run as root: bash /tmp/autoban/install.sh
#
# Prerequisites: This script expects the autoban files to be in the same
# directory as this install script (e.g., /tmp/autoban/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/etc/autoban"
IPSET=$(command -v ipset || echo /sbin/ipset)
IPTABLES=$(command -v iptables || echo /sbin/iptables)

echo "=== Installing Autoban ==="

# 1. Create install directory
echo "[1/8] Creating $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR/state"

# 2. Copy files
echo "[2/8] Copying files ..."
cp "$SCRIPT_DIR/autoban.sh"         "$INSTALL_DIR/autoban.sh"
cp "$SCRIPT_DIR/autoban-persist.sh" "$INSTALL_DIR/autoban-persist.sh"
cp "$SCRIPT_DIR/autoban-status.sh"  "$INSTALL_DIR/autoban-status.sh"
cp "$SCRIPT_DIR/banned.txt"         "$INSTALL_DIR/banned.txt"

# Only copy whitelist if it doesn't already exist (preserve user edits)
if [[ ! -f "$INSTALL_DIR/whitelist.txt" ]]; then
    cp "$SCRIPT_DIR/whitelist.txt" "$INSTALL_DIR/whitelist.txt"
fi

chmod +x "$INSTALL_DIR/autoban.sh"
chmod +x "$INSTALL_DIR/autoban-persist.sh"
chmod +x "$INSTALL_DIR/autoban-status.sh"

# 3. Create symlink for easy CLI access
echo "[3/8] Creating CLI shortcut ..."
ln -sf "$INSTALL_DIR/autoban-status.sh" /usr/local/bin/autoban

# 4. Seed position state so first run only scans NEW log entries
#    (prevents OOM from processing entire historical logs at once)
echo "[4/8] Seeding log positions (skip historical data) ..."
for dir in /var/log/nginx/domains /var/log/apache2/domains; do
    [[ -d "$dir" ]] || continue
    for logfile in "$dir"/*.log; do
        [[ "$logfile" == *.error.log ]] && continue
        [[ "$logfile" == *.log.[0-9]* ]] && continue
        [[ ! -f "$logfile" ]] && continue
        current_size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
        state_key=$(echo "$logfile" | md5sum | cut -d' ' -f1)
        echo "$current_size" > "$INSTALL_DIR/state/$state_key"
    done
done

# 5. Set up cron job (every minute)
echo "[5/8] Setting up cron ..."
CRON_LINE="* * * * * /etc/autoban/autoban.sh >> /var/log/autoban.log 2>&1"
PERSIST_LINE="0 */6 * * * /etc/autoban/autoban-persist.sh save >> /var/log/autoban.log 2>&1"
REBOOT_LINE="@reboot /etc/autoban/autoban-persist.sh restore >> /var/log/autoban.log 2>&1"

# Remove old autoban cron entries and add fresh ones
(crontab -l 2>/dev/null | grep -v '/etc/autoban/'; echo "$CRON_LINE"; echo "$PERSIST_LINE"; echo "$REBOOT_LINE") | crontab -

# 6. Create ipset and iptables rule now
echo "[6/8] Creating ipset and iptables rule ..."
if ! $IPSET list autoban &>/dev/null; then
    $IPSET create autoban hash:ip timeout 86400 maxelem 65536
    echo "  Created ipset 'autoban'"
else
    echo "  ipset 'autoban' already exists"
fi

if ! $IPTABLES -C INPUT -m set --match-set autoban src -j DROP 2>/dev/null; then
    $IPTABLES -I INPUT 1 -m set --match-set autoban src -j DROP
    echo "  Added iptables DROP rule"
else
    echo "  iptables DROP rule already exists"
fi

# 7. Set up logrotate for autoban log
echo "[7/8] Setting up log rotation ..."
cat > /etc/logrotate.d/autoban << 'LOGROTATE'
/var/log/autoban.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}
LOGROTATE

# 8. Verify setup
echo "[8/8] Verifying ..."
/etc/autoban/autoban.sh >> /var/log/autoban.log 2>&1 || true

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Autoban is now active and scanning logs every minute."
echo "Log positions have been seeded -- only NEW requests will be scanned."
echo ""
echo "IMPORTANT: Edit the whitelist to add your own IP(s):"
echo "  nano $INSTALL_DIR/whitelist.txt"
echo ""
echo "Commands:"
echo "  autoban                    - Show status summary + usage"
echo "  autoban list               - List all banned IPs"
echo "  autoban ban 1.2.3.4        - Manually ban an IP"
echo "  autoban unban 1.2.3.4      - Unban a specific IP"
echo "  autoban test 1.2.3.4       - Check if an IP is banned"
echo "  autoban top                - Show top repeat offenders"
echo "  autoban flush              - Remove all bans"
echo "  autoban reinstall /path    - Reinstall from source (preserves bans)"
echo ""
echo "Logs:  tail -f /var/log/autoban.log"
echo "Config: $INSTALL_DIR/"
echo ""

# Show initial results
echo "--- Current status ---"
/etc/autoban/autoban-status.sh summary
