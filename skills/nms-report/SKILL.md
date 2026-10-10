---
name: nms-report
description: "Query LibreNMS for down devices, active alerts and port errors; produce the daily network health report for JM's PH business + homelab."
version: 0.1.0
author: hermes-jm
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [LibreNMS, Network, Monitoring, SNMP, Report]
    related_skills: [proxmox-manage, site-monitor]
required_environment_variables:
  - name: LIBRENMS_URL
    prompt: LibreNMS base URL on the tailnet (e.g. http://librenms.tailnet)
    required_for: all commands
  - name: LIBRENMS_TOKEN
    prompt: LibreNMS API token
    required_for: all commands
---

# NMS Report

LibreNMS runs in the Philippines (an LXC/VM on Proxmox, reached over the tailnet).
This skill reads it through the REST API (`X-Auth-Token`, `${LIBRENMS_URL}/api/v0`)
using `nms.sh` in this skill's directory. It is **read-only**: never acknowledge,
mute or change anything in LibreNMS unless JM explicitly asks.

## When to Use

- Daily 07:00 Asia/Manila network report (cron, delivered to `#ops-alerts`).
- "Is anything down?", "Any alerts on the network?", "Which ports have errors?"
- Before/after a Proxmox or network change to compare state.

## Commands

```bash
N=~/.hermes/skills/nms-report/nms.sh
$N summary   # one JSON doc: counts, down devices, active alerts, top error ports
$N down      # devices down
$N alerts    # active alerts (state=1) with device/rule names
$N ports     # ports whose in+out error delta >= NMS_ERR_THRESHOLD (default 1)
$N devices
```

Env: `LIBRENMS_URL`, `LIBRENMS_TOKEN`; optional `LIBRENMS_CA_FILE` or
`LIBRENMS_INSECURE=1`, `NMS_ERR_THRESHOLD`.

## Procedure (daily report)

1. Run `$N summary`. If it fails (HTTP/timeout), report that LibreNMS is unreachable,
   include the error line, and suggest `tailscale status` / checking the LibreNMS CT —
   do not invent numbers.
2. Build the report in the format below. Keep it under ~25 lines; link nothing external.
3. Severity cues: any `critical` alert or a down device tagged as core (router, firewall,
   core switch, Proxmox node) → put a line starting with `ACTION:` at the top.
4. If everything is green, still send the short report (one line per section), unless the
   cron prompt says to stay silent when healthy — then reply only `[SILENT]`.
5. Do not take remedial action. Suggest next steps only.

## Daily report format

```text
NMS daily - Fri 10 Oct 2026 07:00 PHT
Devices: 42 total | 40 up | 1 down | 1 disabled
Alerts: 3 active (critical 1, warning 2)
Ports with errors: 2

DOWN
- ap-warehouse-02 (10.10.20.32) - down since 03:14, reason: icmp

ALERTS
- [critical] fw-office-01 - "WAN packet loss > 10%" since 05:40
- [warning] sw-core-01 - "Port utilisation > 80%" since 06:12

PORT ERRORS (last poll)
- sw-core-01 Gi1/0/24 "uplink-isp2" in 1,204 / out 0

Suggested next steps
- Check ISP2 uplink cabling/SFP on sw-core-01 Gi1/0/24 (CRC errors align with WAN loss).
```

## Notes

- The API's `ifInErrors_delta` is per poll interval (5 min by default), so a one-off
  small count is noise; mention ports only when the delta is meaningful or recurring.
- Device names come from `display`/`sysName`/`hostname` in that order.
- If LibreNMS is behind a self-signed cert, prefer `LIBRENMS_CA_FILE` over `LIBRENMS_INSECURE=1`.
