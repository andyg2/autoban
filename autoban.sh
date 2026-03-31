#!/bin/bash
# autoban.sh - Block vulnerability scanners hitting banned URL patterns
# Scans nginx + apache access logs, bans IPs with 3+ hits on banned URLs
# Uses ipset for efficient O(1) firewall blocking
#
# Usage: Run via cron every minute as root
#   * * * * * /etc/autoban/autoban.sh >> /var/log/autoban.log 2>&1

set -euo pipefail

# --- Full paths (cron doesn't have /usr/sbin in PATH) ---
IPSET=$(command -v ipset || echo /sbin/ipset)
IPTABLES=$(command -v iptables || echo /sbin/iptables)

# --- Configuration ---
CONF_DIR="/etc/autoban"
BANNED_FILE="$CONF_DIR/banned.txt"
WHITELIST_FILE="$CONF_DIR/whitelist.txt"
STATE_DIR="$CONF_DIR/state"
BAN_LOG="/var/log/autoban.log"
IPSET_NAME="autoban"
THRESHOLD=3           # Number of banned URL hits before banning
BAN_DURATION=86400    # Ban duration in seconds (24 hours)
LOCKFILE="/tmp/autoban.lock"
LOG_DIRS="/var/log/nginx/domains /var/log/apache2/domains"

# --- Prevent concurrent runs ---
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    exit 0
fi

# --- Ensure ipset exists ---
if ! $IPSET list "$IPSET_NAME" &>/dev/null; then
    $IPSET create "$IPSET_NAME" hash:ip timeout "$BAN_DURATION" maxelem 65536
fi

# --- Ensure iptables DROP rule exists (insert before other INPUT rules) ---
if ! $IPTABLES -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP 2>/dev/null; then
    $IPTABLES -I INPUT 1 -m set --match-set "$IPSET_NAME" src -j DROP
fi

# --- Ensure state directory exists ---
mkdir -p "$STATE_DIR"

# --- Temp file for collecting flagged IPs ---
TMPFILE=$(mktemp /tmp/autoban.XXXXXX)
trap "rm -f '$TMPFILE'" EXIT

# --- Scan each access log for banned URL hits ---
for dir in $LOG_DIRS; do
    [[ -d "$dir" ]] || continue

    for logfile in "$dir"/*.log; do
        # Skip error logs, .bytes files, rotated logs, empty/missing files
        [[ "$logfile" == *.error.log ]] && continue
        [[ "$logfile" == *.bytes ]]     && continue
        [[ "$logfile" == *.log.[0-9]* ]] && continue
        [[ ! -f "$logfile" ]]           && continue

        current_size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
        [[ "$current_size" -eq 0 ]] && continue

        # Position tracking (only read new lines since last scan)
        state_key=$(echo "$logfile" | md5sum | cut -d' ' -f1)
        state_file="$STATE_DIR/$state_key"

        saved_size=0
        [[ -f "$state_file" ]] && saved_size=$(cat "$state_file" 2>/dev/null || echo 0)

        # If file was rotated (smaller than saved), reset to read entire file
        if (( current_size < saved_size )); then
            saved_size=0
        fi

        # Skip if no new data
        if (( current_size <= saved_size )); then
            echo "$current_size" > "$state_file"
            continue
        fi

        # Process only new bytes with awk:
        #   - Load banned patterns into hash table
        #   - For each log line, extract URL path ($7), strip query string
        #   - If path matches a banned pattern, output the IP ($1)
        tail -c +"$((saved_size + 1))" "$logfile" | awk -v banned_file="$BANNED_FILE" '
        BEGIN {
            while ((getline line < banned_file) > 0) {
                # Trim trailing whitespace/CR
                gsub(/[[:space:]]+$/, "", line)
                if (line != "") banned[line] = 1
            }
            close(banned_file)
        }
        {
            # $7 = request path in combined log format
            path = $7
            if (path == "" || path == "-") next

            # Strip query string for exact match
            sub(/\?.*/, "", path)

            # Check against banned patterns
            if (path in banned) {
                # $1 = client IP, output IP<tab>path
                print $1 "\t" path
            }
        }' >> "$TMPFILE"

        # Update saved position
        echo "$current_size" > "$state_file"
    done
done

# --- If no hits found, exit early ---
[[ ! -s "$TMPFILE" ]] && exit 0

# --- Count hits per IP, ban those meeting threshold ---
cut -f1 "$TMPFILE" | sort | uniq -c | sort -rn | while IFS= read -r line; do
    count=$(echo "$line" | awk '{print $1}')
    ip=$(echo "$line" | awk '{print $2}')

    # Skip if below threshold
    (( count < THRESHOLD )) && continue

    # Basic IP validation
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        continue
    fi

    # Skip whitelisted IPs
    if [[ -f "$WHITELIST_FILE" ]] && grep -qxF "$ip" "$WHITELIST_FILE" 2>/dev/null; then
        continue
    fi

    # Skip if already in ipset
    if $IPSET test "$IPSET_NAME" "$ip" 2>/dev/null; then
        continue
    fi

    # Collect matched URLs for this IP
    urls=$(grep -P "^${ip}\t" "$TMPFILE" | cut -f2 | sort | uniq -c | sort -rn | awk '{print $2 "(" $1 ")"}' | paste -sd, -)

    # Ban the IP
    if $IPSET add "$IPSET_NAME" "$ip" timeout "$BAN_DURATION" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') BANNED $ip (hits=$count, duration=${BAN_DURATION}s) urls=$urls"
    fi
done
