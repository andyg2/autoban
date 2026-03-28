# Autoban

A lightweight bash toolkit that automatically firewall-blocks vulnerability scanners on Linux servers. It monitors nginx and Apache access logs for known malicious URL patterns and bans offending IPs using ipset + iptables.

Built for [HestiaCP](https://hestiacp.com/) multi-domain hosting environments but works on any server running nginx and/or Apache with combined log format.

## How it works

1. A cron job runs `autoban.sh` every minute
2. It reads only **new** log lines since the last scan (byte-offset tracking per log file)
3. Each request URL is checked against ~960 known scanner patterns (`banned.txt`) using awk's O(1) hash table lookup
4. Any IP that hits **3 or more** banned URLs gets added to an [ipset](https://ipset.netfilter.org/) hash table
5. A single iptables rule drops all traffic from IPs in the ipset
6. Bans auto-expire after 24 hours (configurable)

### Why ipset?

A single iptables rule + ipset handles up to 65,536 banned IPs with O(1) lookup per packet. This is far more efficient than individual iptables/UFW rules per IP.

## Requirements

- Linux (tested on Ubuntu 20.04)
- `ipset` (`apt install ipset`)
- `iptables`
- `awk`, `tail`, `flock`, `md5sum` (standard on most distros)
- nginx and/or Apache with combined log format
- Root access

## Installation

```bash
git clone https://github.com/andyg2/autoban.git /tmp/autoban
sudo bash /tmp/autoban/install.sh
```

The installer will:

- Copy scripts to `/etc/autoban/`
- Seed log positions (only new requests are scanned, not historical logs)
- Create the ipset and iptables DROP rule
- Set up cron jobs (scan every minute, persist ipset every 6 hours, restore on reboot)
- Set up log rotation
- Create the `autoban` CLI shortcut

**After install, add your own IP to the whitelist:**

```bash
echo "YOUR.IP.HERE" >> /etc/autoban/whitelist.txt
```

## Usage

```bash
autoban                  # Show status summary
autoban list             # List all currently banned IPs with timeout remaining
autoban test 1.2.3.4     # Check if a specific IP is banned
autoban unban 1.2.3.4    # Manually unban an IP
autoban top              # Show top repeat offenders from the ban log
autoban flush            # Remove ALL bans
```

### Monitoring

```bash
tail -f /var/log/autoban.log
```

Output looks like:

```log
2026-03-28 04:55:01 BANNED 91.92.243.236 (hits=12, duration=86400s)
2026-03-28 04:56:01 BANNED 141.98.11.239 (hits=5, duration=86400s)
```

## Configuration

Edit the variables at the top of `/etc/autoban/autoban.sh`:

| Variable       | Default                | Description                                          |
| -------------- | ---------------------- | ---------------------------------------------------- |
| `THRESHOLD`    | `3`                    | Banned URL hits before an IP is blocked              |
| `BAN_DURATION` | `86400`                | Ban duration in seconds (24h). Use `0` for permanent |
| `LOG_DIRS`     | nginx + apache domains | Space-separated log directories to scan              |

### Files

```txt
/etc/autoban/
  autoban.sh             # Main scanner (runs via cron)
  autoban-persist.sh     # Save/restore ipset across reboots
  autoban-status.sh      # CLI management tool
  banned.txt             # Banned URL patterns (one per line)
  whitelist.txt          # IPs that should never be banned
  state/                 # Log position tracking (managed automatically)
```

## Customizing the ban list

`banned.txt` contains one URL path per line. Matching is **exact** (after stripping query strings) -- `/wp-admin/css/` only matches requests for that exact directory, not `/wp-admin/css/login.min.css`.

**Add a pattern:**

```bash
echo "/evil-scanner-path.php" >> /etc/autoban/banned.txt
```

**The included list** covers ~960 common scanner probes: WordPress exploit paths, shell uploaders, config file probes, debug endpoints, and directory enumeration attempts.

## Log format

Autoban expects **combined log format** (the default for nginx and Apache):

```log
IP - - [date] "METHOD /path HTTP/x.x" status size "referer" "user-agent"
```

It extracts `$1` (IP) and `$7` (URL path) using awk field splitting.

## How it handles log rotation

- Each log file's byte offset is tracked in `/etc/autoban/state/`
- When a file shrinks (rotation), the offset resets and the new file is scanned from the beginning
- Rotated files (`.log.1`, `.log.2.gz`, etc.) are automatically skipped

## Uninstalling

```bash
# Remove cron jobs
crontab -l | grep -v '/etc/autoban/' | crontab -

# Remove iptables rule and ipset
iptables -D INPUT -m set --match-set autoban src -j DROP
ipset destroy autoban

# Remove files
rm -rf /etc/autoban
rm -f /usr/local/bin/autoban
rm -f /etc/logrotate.d/autoban
rm -f /var/log/autoban.log
```

## License

MIT
