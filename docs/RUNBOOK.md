# Runbook - Hermes Agent for JM

End-to-end rollout and day-2 operations for Hermes Agent on AWS EC2 (Singapore),
managing the Philippines business network + Proxmox homelab, email, and the job search,
with Discord as the control surface. Architecture and guardrails: [ARCHITECTURE.md](ARCHITECTURE.md).

Conventions: run AWS CLI commands from your workstation with `R=ap-southeast-1`.
"On the box" means `tailscale ssh hermes@hermes-aws` (or SSM Session Manager, then
`sudo -iu hermes`). Hermes CLI syntax below matches the Hermes docs as of Oct 2026
(`hermes cron create|list|edit|pause|resume|run|remove`, skills under `~/.hermes/skills/`);
if a flag has moved, `hermes cron create --help` is authoritative.

---

## Phase 1 - Foundation (AWS, Tailscale, Hermes, Discord)

### 1.1 Discord server and bot

1. Create a **private Discord server** (e.g. "JM Ops") with text channels:
   `#ops-alerts` (sites, NMS), `#email`, `#career`, `#proxmox`. Keep it invite-only.
2. Discord Developer Portal -> **New Application** ("Hermes") -> **Bot**:
   - Reset/copy the **bot token** (goes to SSM, never to chat or git).
   - Enable **Message Content Intent** (required - without it Discord refuses the
     connection) and Server Members Intent.
   - Turn off "Public Bot".
3. **OAuth2 -> URL Generator**: scopes `bot` + `applications.commands`; bot permissions
   **View Channels, Send Messages, Read Message History, Attach Files, Use Slash
   Commands** (add Embed Links / Add Reactions if you like). Open the URL and add the bot
   to the private server only.
4. Discord -> Settings -> Advanced -> Developer Mode on; right-click your user -> Copy
   User ID (for `DISCORD_ALLOWED_USERS`). Copy the `#ops-alerts` channel ID if you want it
   as the home channel.

### 1.2 Tailscale

1. Apply `tailscale/acl.hujson` in the admin console (tags `tag:hermes`, `tag:proxmox`,
   `tag:nms`, `tag:subnet-router`).
2. Create a **reusable=false, pre-approved, tagged** auth key with `tag:hermes`.

### 1.3 SSM parameters

Create all as `SecureString` in `ap-southeast-1`. Everything under `/hermes/env/` becomes
`KEY=value` in `/home/hermes/.hermes/.env` at each gateway start.

| Parameter | Phase | Example / notes |
|-----------|:-----:|-----------------|
| `/hermes/tailscale_authkey` | 1 | `tskey-auth-...` (tag:hermes), used once at bootstrap |
| `/hermes/env/OPENROUTER_API_KEY` | 1 | LLM provider key (or `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`) - set a spend limit on the key |
| `/hermes/env/DISCORD_BOT_TOKEN` | 1 | bot token from 1.1 |
| `/hermes/env/DISCORD_ALLOWED_USERS` | 1 | JM's Discord user ID(s), comma-separated |
| `/hermes/env/DISCORD_HOME_CHANNEL` | 1 | optional: `#ops-alerts` channel ID (default `deliver: discord` target) |
| `/hermes/env/HERMES_TIMEZONE` | 1 | `Asia/Dubai` (cron schedules + agent clock) |
| `/hermes/env/PROXMOX_HOST` | 2 | `https://pve.<tailnet>.ts.net:8006` (`pve.sh` also accepts `PROXMOX_URL=.../api2/json`) |
| `/hermes/env/PROXMOX_TOKEN_ID` | 2 | `hermes@pve!agent` |
| `/hermes/env/PROXMOX_TOKEN_SECRET` | 2 | from `proxmox/setup-hermes-user.sh` |
| `/hermes/env/PROXMOX_CA_FILE` | 2 | optional, e.g. `/home/hermes/.hermes/pve-ca.pem` (else TLS verify skipped) |
| `/hermes/env/LIBRENMS_URL` | 2 | `http://librenms.<tailnet>.ts.net` |
| `/hermes/env/LIBRENMS_TOKEN` | 2 | LibreNMS API token (read-only user) |
| `/hermes/env/EMAIL_IMAP_HOST` | 3 | `imap.gmail.com` / `outlook.office365.com` |
| `/hermes/env/EMAIL_IMAP_PORT` | 3 | `993` |
| `/hermes/env/EMAIL_SMTP_HOST` | 3 | `smtp.gmail.com` / `smtp.office365.com` |
| `/hermes/env/EMAIL_SMTP_PORT` | 3 | `587` |
| `/hermes/env/EMAIL_USER` | 3 | mailbox login |
| `/hermes/env/EMAIL_APP_PASSWORD` | 3 | Gmail app password (M365 uses Graph instead, see `docs/M365-GRAPH.md`) |
| `/hermes/env/MS365_MCP_CLIENT_ID` | 3 | Entra app (client) ID, see `docs/M365-GRAPH.md` |
| `/hermes/env/MS365_MCP_TENANT_ID` | 3 | Entra tenant ID |
| `/hermes/env/MS365_MCP_TOKEN_CACHE_PATH` | 3 | `/home/hermes/.hermes/ms365/token-cache.json` |
| `/hermes/env/EMAIL2_*` | 3 | optional second mailbox, same keys with `EMAIL2_` prefix |
| `/hermes/env/SSL_WARN_DAYS` | 3 | optional, default 14 |

```bash
R=ap-southeast-1
put() { aws ssm put-parameter --region $R --type SecureString --overwrite --name "$1" --value "$2"; }
put /hermes/tailscale_authkey 'tskey-auth-...'
put /hermes/env/OPENROUTER_API_KEY 'sk-or-...'
put /hermes/env/DISCORD_BOT_TOKEN '...'
put /hermes/env/DISCORD_ALLOWED_USERS '123456789012345678'
put /hermes/env/HERMES_TIMEZONE 'Asia/Dubai'
```

Avoid putting secrets in shell history: prefix commands with a space (with
`HISTCONTROL=ignorespace`) or use `--value file://secret.txt` and shred the file.

### 1.4 Deploy

Follow [`infra/README.md`](../infra/README.md): `cd infra/terraform`,
`cp terraform.tfvars.example terraform.tfvars`, set `budget_alert_email`,
`terraform init && terraform apply`. Cloud-init installs Docker, Tailscale, the AWS CLI
and Hermes (as user `hermes`), loads secrets and starts `hermes-gateway.service`.

Verify (on the box):

```bash
tailscale status                         # hermes-aws online, tag:hermes
sudo systemctl status hermes-gateway
sudo journalctl -u hermes-gateway -n 100 --no-pager
sudo -iu hermes hermes doctor
```

If the installer needed interaction: `sudo -iu hermes hermes setup` (pick provider/model),
then `sudo systemctl restart hermes-gateway`. Set the agent timezone in
`~/.hermes/config.yaml` (`timezone: "Asia/Dubai"`) if you did not set `HERMES_TIMEZONE`.

### 1.5 Discord allowlist check

DM the bot or post in `#ops-alerts`: "hello". It should answer only you. From a second
Discord account (or ask a friend) confirm it ignores non-allowlisted users. To add a
user later: update `/hermes/env/DISCORD_ALLOWED_USERS` and restart the gateway.

### 1.6 Install the skills

```bash
sudo mkdir -p /opt/hermes-jm && sudo chown hermes:hermes /opt/hermes-jm
sudo -iu hermes git clone https://github.com/<you>/hermes-jm.git /opt/hermes-jm

# Option A - symlink (git pull updates skills in place; preferred)
sudo -iu hermes bash -c 'for d in /opt/hermes-jm/skills/*/; do ln -sfn "$d" ~/.hermes/skills/$(basename "$d"); done'

# Option B - copy (frozen snapshot)
sudo -iu hermes bash -c 'cp -r /opt/hermes-jm/skills/* ~/.hermes/skills/'

# Option C - external skills dir in ~/.hermes/config.yaml:
#   skills:
#     external_dirs: [/opt/hermes-jm/skills]

# Cron script-only jobs must live in ~/.hermes/scripts/:
sudo -iu hermes bash -c 'mkdir -p ~/.hermes/scripts ~/.hermes/state && \
  cp /opt/hermes-jm/skills/site-monitor/sites.example.txt ~/.hermes/sites.txt'
sudo -iu hermes hermes skills list | grep -E 'proxmox|nms|site|email|career'
```

Hermes' default skill layout groups skills by category (`~/.hermes/skills/<category>/<skill>`);
flat top-level skill directories also load. Skills that declare
`required_environment_variables` (proxmox-manage, nms-report, email-triage) get those
variables passed through to the terminal tool automatically. If a script reports a
missing variable anyway, add it to `terminal.env_passthrough` in `~/.hermes/config.yaml`.

---

## Phase 2 - Proxmox + NMS

1. On the PVE host run `proxmox/setup-hermes-user.sh` -> creates `hermes@pve`, pool
   `agent-pool` and token `hermes@pve!agent` (privilege-separated, pool-scoped). Store
   the printed secret in SSM (`PROXMOX_TOKEN_SECRET`), then delete it from your terminal.
2. Build the subnet router CT ([`proxmox/lxc-subnet-router.md`](../proxmox/lxc-subnet-router.md))
   and LibreNMS CT ([`proxmox/lxc-librenms.md`](../proxmox/lxc-librenms.md)); add SNMP devices.
3. Put the `PROXMOX_*` / `LIBRENMS_*` parameters in SSM; `sudo systemctl restart hermes-gateway`.
4. Smoke tests (on the box, as hermes):

   ```bash
   set -a; . ~/.hermes/.env; set +a
   ~/.hermes/skills/proxmox-manage/pve.sh version
   ~/.hermes/skills/proxmox-manage/pve.sh list
   ~/.hermes/skills/nms-report/nms.sh summary | jq '.devices, .alerts'
   ```

5. In Discord `#proxmox`: "list my Proxmox guests", then "create a test debian CT called
   hermes-test, 1 core 512MB 4GB" -> expect VMID + IP. Then "destroy hermes-test" -> it
   must ask for `yes destroy <vmid>` before acting.

## Phase 3 - Monitoring, email, career-ops

### 3.1 Sites
Edit `~/.hermes/sites.txt`; test with `~/.hermes/skills/site-monitor/check_sites.sh --text`.
Create the cron wrapper (no-agent jobs cannot pass arguments to scripts):

```bash
cat > ~/.hermes/scripts/site-alerts.sh <<'EOF'
#!/usr/bin/env bash
exec ~/.hermes/skills/site-monitor/check_sites.sh --alerts-only --text
EOF
chmod +x ~/.hermes/scripts/site-alerts.sh
```

### 3.2 Email
**Microsoft 365:** follow `docs/M365-GRAPH.md` (Entra app without `Mail.Send`, device-code
login, `m365` MCP server). For the M365 cron jobs below, use the MCP tools instead of
`--skill himalaya`.

**Gmail / IMAP:** configure himalaya per `skills/email-triage/SKILL.md` (`~/.config/himalaya/config.toml`,
mode 600), put `EMAIL_*` in SSM, restart the gateway, then in `#email`: "triage my inbox
now, don't change anything". Create Gmail labels / folders `Hermes/FYI`,
`Hermes/Newsletter`, `Hermes/Spam-suspect` (or let the first run create them).

### 3.3 career-ops

```bash
sudo mkdir -p /opt/agents && sudo chown hermes:hermes /opt/agents
sudo -iu hermes bash -lc '
  git clone https://github.com/santifer/career-ops.git /opt/agents/career-ops
  cd /opt/agents/career-ops && npm ci && npx playwright install --with-deps chromium || true
  cp config/profile.example.yml config/profile.yml
  cp templates/portals.example.yml portals.yml
  node doctor.mjs'
```

Then add `cv.md`, edit `config/profile.yml` (targets: IT Manager / Infrastructure /
Network, UAE/GCC + remote, comp range, visa status) and `portals.yml` (Bayt, GulfTalent,
Naukrigulf, LinkedIn, company career pages). Playwright system deps may need `sudo`.
Run once by hand in `#career`: "run the career-ops daily pipeline now".

### 3.4 Cron jobs

Timezone: the agent is set to **Asia/Dubai**, and Hermes evaluates cron expressions in
the configured agent timezone (one timezone for all jobs). Manila is Dubai +4 h, so
"07:00 Asia/Manila" is written as `0 3 * * *`. Deliver targets use Discord channel
names (`discord:#channel`).

| Job | Schedule (Dubai TZ) | Local intent | Type | Skill(s) | Deliver |
|-----|---------------------|--------------|------|----------|---------|
| site-alerts | `every 10m` | - | script-only (0 tokens) | site-monitor | `discord:#ops-alerts` |
| email-triage | `*/30 * * * *` | every 30 min | agent | email-triage, himalaya | `discord:#email` |
| nms-daily | `0 3 * * *` | 07:00 Asia/Manila | agent | nms-report | `discord:#ops-alerts` |
| email-digest | `30 7 * * *` | 07:30 Asia/Dubai | agent | email-triage, himalaya | `discord:#email` |
| career-brief | `0 8 * * *` | 08:00 Asia/Dubai | agent (workdir career-ops) | career-ops-daily | `discord:#career` |
| pve-inventory | `30 8 * * 1` | Mon 08:30 Dubai | agent | proxmox-manage | `discord:#proxmox` |

```bash
hermes cron create "every 10m" --no-agent --script site-alerts.sh \
  --deliver "discord:#ops-alerts" --name site-alerts

hermes cron create "*/30 * * * *" \
  "Triage new mail since the last run per the email-triage skill. Housekeeping only (labels/archive), save reply drafts, never send or delete. If nothing urgent, reply only [SILENT]." \
  --skill email-triage --skill himalaya --deliver "discord:#email" --name email-triage

hermes cron create "0 3 * * *" \
  "Produce the NMS daily report (07:00 Manila) using nms-report. Read-only." \
  --skill nms-report --deliver "discord:#ops-alerts" --name nms-daily

hermes cron create "30 7 * * *" \
  "Send the email morning digest (since 18:00 yesterday) per the email-triage skill, listing drafts awaiting approval." \
  --skill email-triage --skill himalaya --deliver "discord:#email" --name email-digest

hermes cron create "0 8 * * *" \
  "Run the career-ops daily pipeline and send the morning brief. Drafts only - never apply or contact anyone." \
  --skill career-ops-daily --workdir /opt/agents/career-ops --deliver "discord:#career" --name career-brief

hermes cron create "30 8 * * 1" \
  "Weekly Proxmox inventory: list all guests and agent-pool members, flag stopped >7 days and old snapshots. Read-only - do not change anything." \
  --skill proxmox-manage --deliver "discord:#proxmox" --name pve-inventory

hermes cron list
hermes cron run <job_id>        # test any job immediately
```

You can also create these by chatting ("every weekday at 8 Dubai time run the
career-ops brief and post it in #career"); Hermes calls its `cronjob` tool. Use a cheaper
model for cron (`hermes config set cron.model <model>`) to control spend.

## Phase 4 - Paperclip AI integration (later)

[Paperclip](https://github.com/paperclipai/paperclip) is an orchestration/control plane
that models a "company" of AI agents: org chart, goals, tickets, budgets, approvals and
audit trail. Plan:

1. **Host it separately** (homelab LXC/VM in `agent-pool` with 2-4 GB RAM, or a second
   small EC2). Install per its README (`npx paperclipai@latest onboard`, Node 24+;
   or the Docker image). Bind to the tailnet only (`--bind tailnet` / authenticated mode)
   - do not expose it publicly. Add a `tag:paperclip` to the Tailscale ACL.
2. **Register Hermes as an agent/employee.** At the time of writing Paperclip ships
   built-in Hermes adapters - `hermes_local` (Paperclip spawns the local `hermes` CLI;
   requires same host) and `hermes_gateway` (calls an already-running Hermes API server
   over HTTP). Adapter names and options change between releases: check Paperclip's
   adapter list/docs at install time. For our split-host setup the gateway-style adapter
   (or running Paperclip on the Hermes box with `hermes_local`) are the two options;
   if using the gateway adapter, expose the Hermes API server only on the tailnet and
   allow `tag:paperclip -> tag:hermes` on that one port in the ACL.
3. **Budgets and limits:** give the Hermes employee a monthly token/cost budget in
   Paperclip (start ~US$30/mo), a role (e.g. "IT Ops Engineer") reporting to JM, and
   require board/human approval for anything tagged destructive. Keep the provider-side
   key limit as the hard cap.
4. **Keep guardrails in Hermes.** Paperclip tickets are another untrusted input: the
   skills' rules (agent-pool only, explicit destroy confirmation in Discord, no email
   sends without approval) still apply regardless of who assigns the task.
5. Optionally move routines (career brief, weekly inventory) from Hermes cron to
   Paperclip routines once it is stable - but not both (avoid double runs).

---

## Day-2 operations

### Token / secret rotation

| Secret | Rotate | How |
|--------|--------|-----|
| LLM API key | 90 days or on leak | create new key at provider -> `put /hermes/env/OPENROUTER_API_KEY` -> restart -> revoke old |
| Discord bot token | on leak / yearly | Developer Portal -> Bot -> Reset Token -> SSM -> restart |
| Proxmox token | 90 days | `pveum user token add hermes@pve agent2 --privsep 1` + same pool ACL (or re-run `setup-hermes-user.sh`), update `PROXMOX_TOKEN_ID/SECRET`, restart, then `pveum user token remove hermes@pve agent` |
| LibreNMS token | 90 days | LibreNMS -> API -> new token -> SSM -> restart -> delete old |
| Email app password | 90 days / on leak | Google Account -> App passwords -> new -> SSM -> restart -> revoke old |
| Tailscale auth key | single use | only needed for re-bootstrap; node key itself: disable key expiry for tagged node or re-auth |

After any SSM change: `sudo systemctl restart hermes-gateway` (ExecStartPre re-renders
`.env`). Emergency kill switch for the homelab: `proxmox/revoke-hermes-user.sh` on the
PVE host, and/or remove `tag:hermes` grants in the Tailscale ACL.

### Backup / restore (DLM snapshots)

- DLM takes a daily snapshot of the root volume at 18:00 UTC (02:00 Manila), keeps 7.
- **Restore whole box:** EC2 console -> Snapshots (tag from the DLM policy) -> Create
  volume in the same AZ -> stop instance -> detach current root (`/dev/sda1`) -> attach
  restored volume as `/dev/sda1` -> start. Or create an AMI from the snapshot and point
  Terraform at it.
- **Restore a file** (e.g. `~/.hermes/cron/jobs.json`): create a volume from the
  snapshot, attach it as `/dev/sdf`, `sudo mount -o ro /dev/nvme1n1p1 /mnt/restore`
  (check `lsblk`), copy, unmount, detach and delete the volume.
- Extra safety before risky changes: `aws ec2 create-snapshot --volume-id vol-... --description pre-change`.
- What matters to back up: `~/.hermes/` (config, memory, sessions, cron jobs, state),
  `/opt/agents/career-ops/{cv.md,config,data,reports,output}`, `~/.config/himalaya/`.

### Troubleshooting

| Symptom | Check |
|---------|-------|
| Bot offline in Discord | `sudo journalctl -u hermes-gateway -n 200`; "privileged Gateway Intents" -> enable Message Content Intent; 401 -> token wrong/rotated |
| Bot ignores you | your ID in `DISCORD_ALLOWED_USERS`? bot has View/Send/Read History in that channel? |
| Secrets not loaded | `sudo /usr/local/bin/hermes-load-secrets`; `aws ssm get-parameters-by-path --path /hermes/env/` from the box (role permissions) |
| Proxmox / LibreNMS unreachable | `tailscale status`, `tailscale ping pve`, `curl -sk https://pve...:8006`; ACL grants; subnet router CT up? |
| `pve.sh` HTTP 403 | guest not in `agent-pool` or token lacks privilege - expected guardrail |
| Cron jobs not firing | `hermes cron status` (stale gateway code -> restart), `hermes cron list`, output in `~/.hermes/cron/output/` |
| Wrong cron time | `hermes config get timezone` / `HERMES_TIMEZONE`; `hermes doctor` flags bad TZ names |
| No site alerts ever | run `~/.hermes/scripts/site-alerts.sh` by hand; delete `~/.hermes/state/sites.json` to reset state |
| Email auth fails | Gmail: app password + IMAP enabled; M365: re-run `ms-365-mcp-server --org-mode --login`, check Conditional Access (device code flow) |
| High LLM spend | `hermes cron list` (frequency), set `cron.model` to a cheaper model, make email-triage `[SILENT]` when idle |
| Disk full | `df -h`, `docker system prune`, rotate `~/.hermes/logs`, `career-ops/output` |
| Memory pressure | `free -m`, `journalctl -k | grep -i oom` -> consider t4g.large |

Useful commands:

```bash
sudo systemctl restart hermes-gateway
sudo journalctl -u hermes-gateway -f
sudo -iu hermes hermes doctor
sudo -iu hermes hermes cron list
tailscale status && tailscale netcheck
```

## Cost

| Item | US$/mo (est.) |
|------|--------------:|
| EC2 t4g.medium on-demand, Singapore | ~25 |
| EBS 40 GB gp3 | ~3.8 |
| Public IPv4 | ~3.6 |
| EBS snapshots (7 daily, incremental) | ~1-2 |
| SSM Parameter Store (standard), Session Manager | 0 |
| Data transfer / misc | ~1 |
| **AWS subtotal** | **~35** |
| LLM tokens | 10-60 (model + cron frequency dependent) |
| Tailscale Personal, Discord | 0 |
| Optional: t4g.large instead of medium | +~25 |
| Optional: Paperclip host (homelab LXC) | 0 (on-prem) |

AWS Budgets alerts at 80 % and 100 % of `monthly_budget_usd` (default 50).
