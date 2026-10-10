# Architecture

Hermes Agent (Nous Research) runs 24/7 on a small Graviton EC2 instance in Singapore
and acts as JM's operations assistant: it watches the Philippines business network and
Proxmox homelab over Tailscale, triages email, runs the daily job search, and talks to
JM through a private Discord server. Nothing listens on the public internet.

## Diagram

```text
                    JM (UAE)  - phone / laptop
                        |
                        | Discord app (private server)
                        v
              +---------------------+        #ops-alerts  #email
              |   Discord (SaaS)    |        #career      #proxmox
              +---------------------+
                        ^  outbound WSS only (bot gateway)
                        |
 +----------------------|------------------------------------------------------+
 | AWS ap-southeast-1 (Singapore)    VPC 10.42.0.0/16, 1 public subnet         |
 |                                                                              |
 |  +------------------------------------------------------------------------+ |
 |  | EC2 t4g.medium (arm64, Ubuntu 24.04)   SG: NO inbound rules            | |
 |  |  40 GB gp3, encrypted   IMDSv2   IAM role: SSM core + read /hermes/*   | |
 |  |                                                                        | |
 |  |  systemd: hermes-gateway  (user hermes, ~/.hermes)                     | |
 |  |   +-- Discord adapter        (DISCORD_ALLOWED_USERS allowlist)         | |
 |  |   +-- cron ticker  ---------> jobs: sites/10m, email/30m, NMS daily,   | |
 |  |   |                           email digest, career brief, PVE weekly   | |
 |  |   +-- skills (~/.hermes/skills -> /opt/hermes-jm/skills)              | |
 |  |   |     proxmox-manage  nms-report  site-monitor                      | |
 |  |   |     email-triage    career-ops-daily (/opt/agents/career-ops)     | |
 |  |   +-- ExecStartPre: hermes-load-secrets (SSM /hermes/env/* -> .env)   | |
 |  |  tailscaled (tag:hermes, Tailscale SSH)     docker (optional services) | |
 |  +------------------------------------------------------------------------+ |
 |     |  SSM Parameter Store (SecureString)   DLM daily EBS snapshots (7)     |
 |     |  AWS Budgets alert                    Session Manager (break-glass)   |
 +-----|------------------------------------------------------------------------+
       |                     |                         |
       | WireGuard (tailnet) | HTTPS (outbound)        | IMAPS 993 / SMTP 587
       v                     v                         v
 +-----------------------+  +----------------------+  +---------------------------+
 | Philippines (PH)      |  | LLM provider API     |  | Mail: Gmail / M365        |
 | Tailscale ACL:        |  | (OpenRouter etc.)    |  | (app password / OAuth2)   |
 |  tag:hermes ->        |  +----------------------+  +---------------------------+
 |   tag:proxmox :8006   |  | Job boards / ATS     |
 |   tag:nms     :80/443 |  | (career-ops scan)    |
 |   subnet-router LAN   |  +----------------------+
 |                       |  | Public websites      |
 | +-------------------+ |  | (site-monitor)       |
 | | Proxmox VE        | |  +----------------------+
 | |  API token        | |
 | |  hermes@pve!agent | |      Later (Phase 4):
 | |  -> pool          | |      +---------------------------------------------+
 | |     agent-pool    | |      | Paperclip control plane (paperclipai)       |
 | | LXC: LibreNMS     | |      |  org chart, budgets, tickets, approvals     |
 | | LXC: subnet-router| |      |  Hermes registered as an "employee" via the |
 | +-------------------+ |      |  Hermes adapter (hermes_local/_gateway)     |
 | Business LAN: fw,     |      +---------------------------------------------+
 | switches, APs (SNMP)  |
 +-----------------------+
```

Data flow highlights:

- **All connections are outbound from EC2.** Discord, the LLM API, IMAP/SMTP, job boards
  and websites are reached over HTTPS/TLS; the homelab is reached over the tailnet.
- **Admin access** is Tailscale SSH (`tailscale ssh hermes-aws`) or AWS SSM Session
  Manager. There is no SSH key pair and no open port 22.
- **Secrets** live in SSM Parameter Store under `/hermes/env/*` and are rendered into
  `~/.hermes/.env` (mode 600) by `hermes-load-secrets` on every gateway start.

## Sizing

| Item | Choice | Notes |
|------|--------|-------|
| Region | ap-southeast-1 (Singapore) | ~30-50 ms to Manila, ~90-110 ms to Dubai; good LLM/API egress |
| Instance | **t4g.medium** (2 vCPU Graviton2, 4 GiB) | Hermes gateway + cron + Node (career-ops, Playwright for PDFs) fit comfortably; burstable credits cover daily spikes |
| Storage | 40 GB gp3, encrypted | OS ~8 GB, Hermes + venv ~3 GB, career-ops + Chromium ~2 GB, logs/sessions/state; headroom for Docker images |
| Network | Public subnet, public IPv4, SG with zero inbound rules | Public IPv4 needed for egress without a NAT gateway (NAT GW would cost ~US$35+/mo alone) |
| Backup | DLM daily EBS snapshot 18:00 UTC, keep 7 | Snapshots are incremental; typical cost < US$2/mo |
| Cost (est.) | **~US$35/mo + LLM tokens** | see table below |

Approximate monthly cost (on-demand, Singapore, Oct 2026 list prices; verify in the AWS
Pricing Calculator):

| Line | US$/mo |
|------|-------:|
| t4g.medium on-demand (730 h) | ~25 |
| 40 GB gp3 | ~3.8 |
| Public IPv4 address | ~3.6 |
| EBS snapshots (7 daily, incremental) | ~1-2 |
| Data transfer out, SSM, CloudWatch basic | ~1 |
| **Infra subtotal** | **~35** |
| LLM tokens (OpenRouter etc.) | usage-based - typically 10-60 depending on model and how chatty the cron jobs are |
| Tailscale (Personal, <= 3 users) / Discord | 0 |

Cost levers: a 1-year Compute Savings Plan cuts the instance ~30-40 %; script-only cron
jobs (`--no-agent`, e.g. site checks) spend zero tokens; pin cheap models for routine
cron jobs (`hermes config set cron.model ...`) and keep a stronger model for chat.

**Upgrade path:** move to **t4g.large** (8 GiB, ~US$50/mo instance) if you see memory
pressure (`free -m` swap use, OOM kills in `journalctl -k`), sustained CPU credit
exhaustion (CloudWatch `CPUCreditBalance` near 0), or you add Paperclip, local
embeddings or browser automation on the same host. It is an in-place change:
`instance_type = "t4g.large"` in `terraform.tfvars`, `terraform apply` (stop/start, ~2 min).
Paperclip itself is better on its own host or the homelab (Phase 4).

## Security guardrails

**Network**
- No inbound security-group rules; no public services; IMDSv2 required.
- Tailscale ACL (`tailscale/acl.hujson`): `tag:hermes` may reach only `tag:proxmox:8006`,
  `tag:nms` web/API and specific LAN subnets via the subnet router; nothing may reach
  `tag:hermes` except admins. Tailnet keys for servers are tagged (no key expiry
  surprises, no user identity on the server).
- Proxmox and LibreNMS are never exposed to the internet; only reachable via the tailnet.

**Identity and secrets**
- Instance role can read only `/hermes/*` parameters (plus SSM core for Session Manager).
- Proxmox: dedicated `hermes@pve` user + API token `hermes@pve!agent` with privilege
  separation, permissions only on pool `agent-pool` (`proxmox/setup-hermes-user.sh`);
  `proxmox/revoke-hermes-user.sh` is the kill switch.
- LibreNMS: read-only API user/token.
- Email: Gmail app password; M365 via own Entra app, delegated token for JM's mailbox only, no `Mail.Send` consent (`docs/M365-GRAPH.md`). Never the main password.
- Discord: bot only in JM's private server; `DISCORD_ALLOWED_USERS` allowlist so nobody
  else can command it; minimal bot permissions.
- All tokens rotatable without redeploying (update SSM -> restart gateway). See RUNBOOK.

**Agent behaviour (enforced in skills + helper scripts)**
- Destructive Proxmox actions: refused outside `agent-pool` (API ACL + script check) and
  require explicit "yes destroy <vmid>" from JM in Discord **and** `CONFIRM=yes`.
- Snapshot before changing an existing guest.
- Email: never send/delete/forward without per-message approval in Discord; no
  auto-forward rules; reversible housekeeping only.
- **Untrusted content boundary:** emails, web pages, job descriptions and monitored
  sites are data, never instructions. Content from those sources can never trigger
  Proxmox, network, AWS or email-sending actions. Suspected prompt-injection is reported.
- Career: drafts only; JM submits every application himself.
- Monitoring skills are read-only (LibreNMS, site checks); they suggest, never remediate.

**Operations**
- Daily EBS snapshots (7-day retention) for whole-box restore; `~/.hermes` can also be
  tarred to S3 if needed.
- AWS Budget alert at 80 % / 100 % of the monthly budget (default US$50).
- LLM provider spend cap set at the provider (OpenRouter credit limit / key limit).
- Logs: `journalctl -u hermes-gateway`, `~/.hermes/logs/`, cron output in
  `~/.hermes/cron/output/`.
