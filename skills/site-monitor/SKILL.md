---
name: site-monitor
description: "Check JM's websites and tailnet services: HTTP status, response time, TLS certificate expiry and DNS. Alerts only on state change or certificate < 14 days."
version: 0.1.0
author: hermes-jm
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Monitoring, Uptime, SSL, DNS, Websites]
    related_skills: [nms-report, proxmox-manage]
---

# Site Monitor

`check_sites.sh` (this directory) checks every URL in the sites list and prints one
JSON object per site:

```json
{"ts":"2026-10-10T03:10:00Z","url":"https://www.example-business.ph","status":"up",
 "http_code":200,"time_s":0.412,"ssl_days":61,"dns":"203.0.113.10",
 "consecutive_failures":0,"error":null,"alert":false,"alert_reason":null}
```

- Sites list: `~/.hermes/sites.txt` (copy `sites.example.txt`); `<url> [expected_status_regex]`.
- State: `~/.hermes/state/sites.json` (per-URL status, failure count, last result).
- A site becomes `down` after `FAIL_THRESHOLD` (default 2) consecutive failures, to avoid
  alerting on a single blip; `alert_reason` is `down`, `recovered` or `ssl_expiring`.
- `ssl_expiring` fires when the certificate has < `SSL_WARN_DAYS` (default 14) days left,
  at most once per day per site.
- Flags: `--alerts-only` prints only sites with an alert (empty output = all quiet);
  `--text` prints one human line per site instead of JSON.
- Needs `curl`, `jq`, `openssl`, and `getent` or `dig`.

## When to Use

- Scheduled every 10 minutes (script-only cron job, no LLM tokens) delivering to `#ops-alerts`.
- "Is the website up?", "When does the shop certificate expire?", "Status of all sites".
- After DNS/hosting changes, run it with no flags and summarise.

## How to run

```bash
S=~/.hermes/skills/site-monitor/check_sites.sh
$S --text                     # full status, human readable
$S                            # full status, JSON lines
$S --alerts-only --text       # what the cron job runs
```

For the 10-minute cron job the script must live in `~/.hermes/scripts/` (Hermes only
runs cron scripts from there), so the install step symlinks or copies it:
`ln -sf ~/.hermes/skills/site-monitor/check_sites.sh ~/.hermes/scripts/check_sites.sh`.

## Interpreting results (when asked in chat)

- `dns_resolution_failed` - DNS problem (registrar/zone/MagicDNS); check before blaming the server.
- `curl_exit_28` - timeout; `curl_exit_35`/`60` - TLS handshake or certificate problem;
  `curl_exit_7` - connection refused.
- `unexpected_status` - server answered but with a code not matching the expected regex.
- Slow (`time_s` > 3) but up - mention it, do not alert.
- For tailnet URLs that are down, check `tailscale status` and the subnet router first,
  then `nms-report` for the underlying host.

Never "fix" anything automatically from this skill; report and suggest.
