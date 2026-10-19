# Dashboards - Homepage, Open WebUI, Hermes admin and Discord

> "These are all different dashboards and I can use them all at the same time? And customize
> them?" Yes to both. They are four different windows onto the **same** Hermes agent. This
> guide covers what each one is for, how to set them up, how to customize them, and how to
> keep them private.

Everything here is **tailnet-only**: no public URL, no inbound AWS ports, no Tailscale Funnel.
`<tailnet>` below is your tailnet's MagicDNS suffix (e.g. `tail1234ab`); `tailscale status`
shows it.

## Overview

| | Homepage NOC | Open WebUI | Hermes admin dashboard | Discord |
|---|---|---|---|---|
| **What it is for** | One-glance status page: Proxmox, LibreNMS, sites, Tailscale, Hermes up/down, bookmarks | Long chats with Hermes in a browser: history, search, file uploads, saved prompts | Run Hermes itself: config, API keys, cron jobs, skills, MCP, sessions, logs, token spend | Alerts and quick commands on your phone, approvals (`yes destroy <vmid>`, send email) |
| **Where it runs** | Its own Proxmox LXC in the homelab | EC2 `hermes-aws` (Docker) | EC2 `hermes-aws` (systemd) | Discord's cloud + the Hermes gateway on EC2 |
| **URL** | `https://homepage.<tailnet>.ts.net` | `https://hermes-aws.<tailnet>.ts.net` | `https://hermes-aws.<tailnet>.ts.net:8443` | Discord app, private "JM Ops" server |
| **Local port** | 3000 (on the CT) | 127.0.0.1:3000 | 127.0.0.1:9119 | - |
| **Login** | none (tailnet ACL is the gate) | Open WebUI account | Hermes dashboard username/password | Discord + `DISCORD_ALLOWED_USERS` |
| **Customizability** | High (YAML) | High (UI, presets, prompts, functions) | Medium (themes + plugins, no fork needed) | Medium (channels, threads, slash commands) |
| **Files** | [`dashboards/homepage/`](../dashboards/homepage/README.md) | [`dashboards/open-webui/`](../dashboards/open-webui/docker-compose.yml) | [`dashboards/hermes-dashboard/`](../dashboards/hermes-dashboard/hermes-dashboard.service) | [RUNBOOK 1.1](RUNBOOK.md#11-discord-server-and-bot) |

There is also a fifth, hidden URL: `https://hermes-aws.<tailnet>.ts.net:9443/health`, a
health-only endpoint that the Homepage "Hermes API" tile polls (see [Security](#security)).

## Yes, use them all at once

All four talk to the **same Hermes brain**: the same `~/.hermes` config, model, memory, skills,
cron jobs and API keys on `hermes-aws`. They do not conflict:

- **Discord** and **Open WebUI** are both front doors into the Hermes gateway. Discord comes in
  through the Discord adapter, Open WebUI through the API server (`127.0.0.1:8642`). Each chat
  is its own session, so a long Open WebUI conversation does not disturb a Discord thread.
  Shared memory and skills mean "remember X" in one is known in the other.
- **Tools always run on EC2.** Whether you type in Discord, Open WebUI or the dashboard's Chat
  tab, the agent runs on `hermes-aws`: `pve.sh`, email triage and terminal commands execute
  there, not on your laptop or phone. The same guardrails apply everywhere (agent-pool only,
  explicit destroy confirmation, no email sent without approval).
- **The Hermes admin dashboard** edits the config the gateway uses. Changes to `config.yaml`
  or `.env` need a gateway restart to apply (see [Troubleshooting](#troubleshooting)).
- **Homepage** only reads. It shows status and links; it never changes anything.

A typical day:

1. **Phone, morning:** Discord pings in `#ops-alerts` (site down, NMS daily report), `#email`
   (digest + drafts waiting for approval) and `#career` (job brief). Approve or reply right there.
2. **Desk:** open Homepage. Green across Proxmox, LibreNMS, sites and Hermes? Move on. Red tile?
   Click through to LibreNMS / Proxmox.
3. **Longer work:** Open WebUI for anything that needs back-and-forth, e.g. "plan a new CT for
   Uptime Kuma, create it in agent-pool, then show me the config", or rewriting an email
   draft. Use your saved presets and `/commands` (below).
4. **Housekeeping, weekly:** Hermes admin dashboard: check token spend (Analytics), pause or
   edit a cron job, rotate a key, enable a skill, read logs.

## Setup

Order: EC2 side first (API server, Open WebUI, admin dashboard, `tailscale serve`), then Homepage.
"On the box" = `tailscale ssh hermes@hermes-aws` (or SSM Session Manager), repo at
`/opt/hermes-jm` ([RUNBOOK 1.6](RUNBOOK.md#16-install-the-skills)). Run `git pull` there first.

### 0. Tailnet prerequisites

1. Admin console > **DNS**: MagicDNS on, **HTTPS Certificates** enabled (needed by
   `tailscale serve`).
2. Apply the updated [`tailscale/acl.hujson`](../tailscale/acl.hujson) (adds `tag:homepage`).

### 1. Enable the Hermes API server (for Open WebUI)

The API server is part of `hermes gateway`. It is off by default and binds `127.0.0.1:8642`.
From your workstation:

```bash
R=ap-southeast-1
put() { aws ssm put-parameter --region $R --type SecureString --overwrite --name "$1" --value "$2"; }
put /hermes/env/API_SERVER_ENABLED true
put /hermes/env/API_SERVER_KEY "$(openssl rand -hex 32)"
# Optional: name shown in Open WebUI's model picker (default: hermes-agent)
put /hermes/env/API_SERVER_MODEL_NAME Hermes
```

Do **not** set `API_SERVER_HOST`; the default loopback bind is what we want. On the box:

```bash
sudo systemctl restart hermes-gateway        # re-renders ~/.hermes/.env from SSM
sudo journalctl -u hermes-gateway -n 50 | grep -i 'api server'
#   [API Server] API server listening on http://127.0.0.1:8642
curl -s http://127.0.0.1:8642/health
key=$(sudo grep '^API_SERVER_KEY=' /home/hermes/.hermes/.env | cut -d= -f2-)
curl -s -H "Authorization: Bearer $key" http://127.0.0.1:8642/v1/models | jq '.data[].id'
```

The key is required even on loopback: the API gives full agent access, including terminal tools.

### 2. Open WebUI (Docker on EC2)

```bash
cd /opt/hermes-jm/dashboards/open-webui
cp .env.example .env && chmod 600 .env
key=$(sudo grep '^API_SERVER_KEY=' /home/hermes/.hermes/.env | cut -d= -f2-)
ts=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$key|; \
        s|^WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=$(openssl rand -hex 32)|; \
        s|hermes-aws\.TAILNET\.ts\.net|$ts|g" .env
unset key
docker compose up -d
docker compose logs -f        # first start downloads an embedding model (~150 MB), 30-60 s
curl -s http://127.0.0.1:3000/health
```

How it is wired (see the header of `docker-compose.yml`):

- `network_mode: host`, Open WebUI listening on `127.0.0.1:3000`, Hermes API at
  `http://127.0.0.1:8642/v1`. With the usual bridge network plus
  `extra_hosts: host.docker.internal:host-gateway`, the container reaches the host through
  `172.17.0.1`, where a loopback-only Hermes API is **not** listening. Host networking keeps
  both on loopback, so we never bind the agent API to a Docker bridge.
- Image pinned to `ghcr.io/open-webui/open-webui:v0.11.4`. To upgrade, read the release notes,
  bump the tag, then `docker compose pull && docker compose up -d`.
- `mem_limit: 1g`, Ollama off, login on, signup off, cookies `Secure`.

**First login:** after `tailscale serve` (step 4), open `https://hermes-aws.<tailnet>.ts.net`
and **create your account straight away**. The first account becomes admin. Signup is
already disabled for everyone after that. Add family or staff later in
Admin Panel > Users > **+** (role `user`).

Open WebUI stores its settings in its own database after the first start. Changing
`OPENAI_API_KEY` in `.env` later does nothing. Update it in Admin Panel > Settings >
Connections instead.

### 3. Hermes admin dashboard (systemd on EC2)

`hermes dashboard` has **no login when bound to 127.0.0.1**, and it reads and writes your
`.env` secrets. We bind it to loopback and publish it with `tailscale serve`. Setting
`HERMES_DASHBOARD_PUBLIC_URL` tells it a proxy is in front. That turns its auth gate on and
lets the `hermes-aws...:8443` Host header pass its DNS-rebinding guard. With the gate on, it
**refuses to start** without an auth provider, so give it a username and password:

```bash
# workstation
ts=hermes-aws.<tailnet>.ts.net
put /hermes/env/HERMES_DASHBOARD_PUBLIC_URL "https://$ts:8443"
put /hermes/env/HERMES_DASHBOARD_BASIC_AUTH_USERNAME jm
put /hermes/env/HERMES_DASHBOARD_BASIC_AUTH_PASSWORD '<long random password>'
put /hermes/env/HERMES_DASHBOARD_BASIC_AUTH_SECRET "$(openssl rand -base64 32)"   # keeps you logged in across restarts
```

The dashboard's HTTP stack (FastAPI/Uvicorn) is a core Hermes dependency. If it complains
about missing packages, run `sudo -iu hermes hermes pm repair`. On the box:

```bash
sudo -iu hermes which hermes      # unit assumes /home/hermes/.local/bin/hermes
sudo install -m 644 /opt/hermes-jm/dashboards/hermes-dashboard/hermes-dashboard.service \
     /etc/systemd/system/hermes-dashboard.service
sudo systemctl daemon-reload && sudo systemctl enable --now hermes-dashboard
sudo journalctl -u hermes-dashboard -n 50 --no-pager
curl -s http://127.0.0.1:9119/api/status | jq '.auth_required, .auth_providers'
#   true
#   ["basic"]
```

If you would rather use your Nous account (OAuth) than a password, see "Default provider: Nous
Research" in the Hermes web-dashboard docs (`hermes dashboard register`).

### 4. Publish on the tailnet

```bash
sudo /opt/hermes-jm/dashboards/tailscale-serve.sh
```

The script is idempotent. Re-run it any time. It configures:

| Tailnet URL | Goes to | Who (ACL) |
|---|---|---|
| `https://hermes-aws.<tailnet>.ts.net/` | Open WebUI `127.0.0.1:3000` | admins, `tag:homepage` (status check) |
| `https://hermes-aws.<tailnet>.ts.net:8443/` | Hermes dashboard `127.0.0.1:9119` | admins, `tag:homepage` (status check) |
| `https://hermes-aws.<tailnet>.ts.net:9443/health` | Hermes API `/health` only | admins, `tag:homepage` |

It never enables Funnel, and switches Funnel off on these ports if it finds it on.
`sudo .../tailscale-serve.sh status` shows the config. `... off` removes it.

### 5. Homepage NOC (Proxmox LXC)

Follow [`dashboards/homepage/README.md`](../dashboards/homepage/README.md): CT + Docker +
Tailscale, its own `tailscale serve`, and its `.env`. Points that tie in with this guide:

- Tag the CT `tag:homepage` in the Tailscale admin console. The ACL lets it reach
  `tag:hermes` on 443/8443/9443 only, Proxmox 8006 and LibreNMS. It cannot reach the raw
  Hermes API (8642) or SSH.
- In its `.env`: `HOMEPAGE_VAR_OPENWEBUI_URL=https://hermes-aws.<tailnet>.ts.net`,
  `HOMEPAGE_VAR_HERMES_DASHBOARD_URL=https://hermes-aws.<tailnet>.ts.net:8443`,
  `HOMEPAGE_VAR_HERMES_HEALTH_URL=https://hermes-aws.<tailnet>.ts.net:9443/health`.
- **Proxmox:** Homepage gets its **own read-only token** `hermes@pve!homepage` with
  `PVEAuditor`. Never reuse `hermes@pve!agent`, which can create and change guests.
- **LibreNMS:** Homepage has no native LibreNMS widget. The LibreNMS card uses three
  `customapi` widgets against the LibreNMS REST API (devices, devices down, active alerts),
  with a read-only API token.

## Customization

### Homepage (high, YAML)

Everything lives in `dashboards/homepage/config/*.yaml` and reloads on save (no restart needed
for most changes):

- **`services.yaml`**: groups and tiles. Each tile has `href`, `icon`, `description`, an
  optional `siteMonitor` (green/red dot), and a `widget` (Proxmox, Uptime Kuma, Tailscale, or
  `customapi` for anything with a JSON API, as used for LibreNMS).
- **`widgets.yaml`**: the top bar: resources, clock (set `Asia/Dubai`), search, weather.
- **`settings.yaml`**: `title`, `theme: dark|light`, `color` (slate, zinc, emerald, ...),
  `background` (image URL + `blur`, `opacity`), `layout` (per-group `style: row`,
  `columns: 4`, icons only, collapsed groups), `headerStyle`, `cardBlur`.
- **`bookmarks.yaml`**: link groups (GitHub, AWS console, ISP portals, ...).
- **`custom.css` / `custom.js`** (optional, add them next to the YAML files): for anything the YAML cannot do.

Secrets stay in `.env` as `HOMEPAGE_VAR_*` and are referenced as `{{HOMEPAGE_VAR_*}}`.

### Open WebUI (high, in the UI)

- **Look:** Settings > Interface: theme (dark, OLED, light), chat bubble layout, wide mode,
  default model. Admin Panel > Settings > Interface: banners, default prompt suggestions.
- **Model presets ("Workspace > Models")**: create named presets on top of the Hermes model,
  each with its own system prompt, avatar, default params and prompt suggestions. Ideas:
  - **Hermes-Ops**: "You are JM's infrastructure operator. Prefer read-only checks first,
    show the commands you will run, never destroy without `yes destroy <vmid>`."
  - **Hermes-Mail**: tone and signature rules for drafting replies (still drafts only).
  - **Hermes-Career**: GCC IT-leadership focus, CV-tailoring style.
  Hermes already has its own personality and skills. A preset adds instructions for that
  chat, and Hermes' guardrails still apply.
- **Prompt library ("Workspace > Prompts")**: saved prompts you trigger with `/` in the chat
  box, with `{{variables}}`:
  - `/pve-create`: "Create a Debian CT in agent-pool named {{name}}, {{cores}} cores,
    {{ram}} MB, {{disk}} GB, then report VMID and IP."
  - `/pve-inventory`: "List all Proxmox guests and flag stopped >7 days. Read-only."
  - `/email-digest`: "Summarise unread mail since {{since}} per the email-triage skill, list drafts awaiting approval."
  - `/nms-down`: "What is down in LibreNMS right now and since when?"
  - `/career-brief`: "Run the career-ops daily pipeline now. Drafts only."
- **Knowledge**: upload runbooks or network diagrams and attach them to a preset (`#` in
  chat). Uses the local embedding model (RAM; see [Resources](#resources)).
- **Functions / Pipelines** (Admin Panel > Functions): Python filters and actions that run
  inside Open WebUI, e.g. a filter that adds today's date and site name to every message, or
  a button that sends the answer to Discord. They run in the Open WebUI container, not in
  Hermes, so keep them simple and do not give them secrets they do not need.
- **Users and groups**: Admin Panel > Users. Add accounts, put them in groups, and limit which
  models or presets each group sees. To give someone their own isolated Hermes (own memory),
  run a separate Hermes profile with its own API server port and add it as a second
  connection (Hermes Open WebUI guide, "Multi-User Setup with Profiles").
- **Optional SSO**: `tailscale serve` adds `Tailscale-User-Login` headers. Open WebUI can trust
  them (`WEBUI_AUTH_TRUSTED_EMAIL_HEADER=Tailscale-User-Login`) for passwordless login. Only
  do this while nothing but `tailscale serve` can reach port 3000, which holds today because
  it is bound to loopback.

### Hermes admin dashboard (medium, no fork needed)

- **Themes:** the palette icon in the header switches between 8 built-in themes and changes
  the font. Your own theme is a YAML file in `~/.hermes/dashboard-themes/` (palette,
  typography, layout, background images, `customCSS`) and shows up in the switcher.
- **Plugins:** a folder in `~/.hermes/plugins/<name>/dashboard/` with `manifest.json` + a JS
  bundle adds a tab, replaces or augments a built-in page, or injects widgets into shell slots.
  An optional `plugin_api.py` adds backend routes under `/api/plugins/<name>/`. Example: a
  "Homelab" tab that shows `pve.sh list` output.
- **Forking the React frontend** is possible but rarely worth it. You would have to rebase on
  every Hermes update, and the dashboard changes often. Use themes and plugins first. See
  "Extending the Dashboard" in the Hermes docs.

### Discord (medium)

- **Channels:** one per topic (`#ops-alerts`, `#email`, `#career`, `#proxmox`). Cron jobs
  deliver with `--deliver "discord:#channel"`. Add channels freely (e.g. `#homelab-chat`).
- **Mentions and threads:** `DISCORD_FREE_RESPONSE_CHANNELS` (channel IDs where no
  @mention is needed), `DISCORD_AUTO_THREAD` (a thread per request, keeps sessions apart),
  `DISCORD_NO_THREAD_CHANNELS`. Put them in SSM `/hermes/env/` like the other keys.
- **Slash commands:** Hermes registers native slash commands (`/help`, `/model`, `/reset`,
  ...) in your server. Type `/` to see them.
- **Phone notifications:** per-channel notification settings in the Discord app, e.g.
  `#ops-alerts` = all messages, `#career` = mentions only.

## Security

- **Tailnet only.** Nothing is published to the internet. EC2 has no inbound security-group
  rules, all three EC2 services bind `127.0.0.1`, and `tailscale serve` (never `funnel`) is
  the only way in. `tailscale-serve.sh` checks for Funnel and refuses to leave it on.
- **Tailscale ACL** ([`tailscale/acl.hujson`](../tailscale/acl.hujson)): `autogroup:admin`
  (you) can reach everything, and `tag:homepage` can reach `tag:hermes` only on
  `tcp:443, tcp:8443, tcp:9443` (plus Proxmox 8006 and LibreNMS). Managed nodes (`tag:proxmox`, ...) are denied,
  and the `tests` block checks this. If you ever narrow the admin "everything" grant, or add a
  non-admin user (family, staff), grant them just the dashboard ports:

  ```hujson
  // Only these users/devices may open the Hermes chat and admin UIs.
  {
  	"src": ["jm@example.com"],           // or a tag on your own devices, e.g. "tag:jm-devices"
  	"dst": ["tag:hermes"],
  	"ip":  ["tcp:443", "tcp:8443"],
  },
  ```

  Leave 8443 (admin) out for anyone who should only chat.
- **Logins on top of the ACL.** Open WebUI: `WEBUI_AUTH=true`, signup disabled, new users
  `pending` until you approve. Hermes dashboard: auth gate on (basic auth or Nous OAuth),
  because it can read and write every secret in `.env`.
- **`API_SERVER_KEY`** protects the agent API (full tool access, including the terminal). It
  lives in SSM, is shared only with Open WebUI's `.env` (mode 600, git-ignored), and the API is
  never exposed on the tailnet. Only `/health` is, on 9443. Rotate it like the other keys:
  new SSM value, restart gateway, update Admin Panel > Settings > Connections in Open WebUI.
- **Homepage uses read-only credentials:** its own `hermes@pve!homepage` (PVEAuditor) token, a
  read-only LibreNMS token, and a Tailscale API key that expires. Homepage itself has no
  login, so treat its tailnet URL like anything else that sits behind the ACL.
- **Open WebUI chats and uploads** stay in the `open-webui-data` Docker volume on EC2. They
  are covered by the daily EBS snapshots.

## Resources

`hermes-aws` is a **t4g.medium (4 GB)** and stays that size for now. Rough steady-state use:

| Process | RAM |
|---|---|
| Hermes gateway (Discord + API server + cron) | 0.3-0.6 GB, more during runs |
| Open WebUI (incl. local embedding model) | 0.5-1 GB (capped at 1 GB) |
| Hermes dashboard (+ Chat tab sessions) | 0.15-0.5 GB (capped at 768 MB) |
| career-ops Playwright runs (daily) | up to ~1 GB for a few minutes |

That fits, but without much headroom. Watch it for the first week:

```bash
free -m                                  # "available" should stay > ~500 MB
docker stats --no-stream open-webui
systemctl status hermes-dashboard | grep Memory
journalctl -k | grep -i -E 'oom|killed process'
docker inspect -f '{{.State.OOMKilled}}' open-webui
```

If the box swaps or OOM kills appear, first stop the admin dashboard when you are not using it
(`sudo systemctl stop hermes-dashboard`). If that is not enough, resize to **t4g.large (8 GB,
about +US$25/mo)**: set `instance_type` in Terraform and `terraform apply`, which means a
stop/start of a few minutes.

## Troubleshooting

| Symptom | Check |
|---|---|
| `https://hermes-aws...` does not load | `tailscale status` on your device; `sudo dashboards/tailscale-serve.sh status`; HTTPS certificates enabled in the tailnet; ACL applied; first request after enabling can take ~1 min while the cert is issued |
| Open WebUI: no models in the picker | `curl -s http://127.0.0.1:8642/health` on the box (API server enabled? gateway restarted?); Admin Panel > Settings > Connections: URL `http://127.0.0.1:8642/v1` (with `/v1`), key = `API_SERVER_KEY` |
| Open WebUI: "Invalid API key" / 401 | key in Open WebUI's **Connections** (database), not `.env`, must match `API_SERVER_KEY` |
| Open WebUI keeps restarting | `docker compose logs --tail 100`; `docker inspect -f '{{.State.OOMKilled}}' open-webui` -> raise `mem_limit` above `1g` or resize the instance |
| Open WebUI slow first answer | normal: Hermes may run several tools before replying; progress lines stream in the chat |
| Lost the Open WebUI admin password | `docker exec -it open-webui ...` per the Open WebUI docs ("Reset admin password"), or as a last resort `docker compose down && docker volume rm open-webui-data` (loses chats) |
| Dashboard unit exits with status 78 | auth gate on but no provider: check `HERMES_DASHBOARD_BASIC_AUTH_*` are in `~/.hermes/.env`; or another `hermes dashboard` already runs (`pgrep -af 'hermes dashboard'`) |
| Dashboard "Invalid host" / blank page / WebSocket 4403 | `HERMES_DASHBOARD_PUBLIC_URL` must be exactly `https://hermes-aws.<tailnet>.ts.net:8443` (scheme, name, port) |
| Dashboard login loops after restart | set `HERMES_DASHBOARD_BASIC_AUTH_SECRET` (otherwise a new key on every start) |
| Config change in the dashboard has no effect | restart the gateway: `sudo systemctl restart hermes-gateway`. The dashboard's own "Restart gateway" button expects a Hermes-managed service and may fail with our systemd unit. Keys managed in SSM are overwritten from SSM at every restart, so change those in SSM. |
| Homepage "Hermes API" tile red | from the Homepage CT: `curl -s https://hermes-aws.<tailnet>.ts.net:9443/health`; CT tagged `tag:homepage`? ACL applied? |
| Discord quiet but Open WebUI works | both use the same gateway, so check `journalctl -u hermes-gateway` for the Discord adapter (token, intents) |
