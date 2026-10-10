# hermes-jm

Infrastructure, skills and runbooks for running [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(Nous Research) 24/7 as JM's operations assistant.

- **Where:** AWS EC2 t4g.medium in ap-southeast-1 (Singapore), user `hermes`, config in
  `~/.hermes`, no inbound ports. Secrets in SSM Parameter Store (`/hermes/env/*`).
  About US$35/mo plus LLM tokens.
- **Talks to JM via Discord:** a private server with `#ops-alerts`, `#email`, `#career` and `#proxmox`.
- **Reaches the Philippines business network and Proxmox homelab over Tailscale.**
- **Does:**
  - Proxmox guest management, limited to `agent-pool`, with guarded destroy.
  - LibreNMS daily network report.
  - Website, TLS and DNS monitoring.
  - Email triage: drafts only, nothing is sent without approval.
  - Daily UAE/GCC IT-leadership job search via career-ops: drafts only, JM applies.
  - Later: Paperclip AI as the control plane.

## Repository layout

```text
infra/        Terraform (VPC, EC2, IAM, DLM backups, budget) + cloud-init bootstrap
proxmox/      setup-hermes-user.sh (hermes@pve!agent token scoped to agent-pool),
              revoke script, LibreNMS and Tailscale subnet-router LXC guides
tailscale/    acl.hujson - tag-based ACL (tag:hermes -> proxmox / nms / LAN only)
skills/       Hermes skills (SKILL.md + helper scripts)
  proxmox-manage/    pve.sh - PVE API: list, create-ct, start/stop, snapshot, guarded destroy
  nms-report/        nms.sh - LibreNMS: down devices, alerts, port errors, daily report
  site-monitor/      check_sites.sh - HTTP/TLS/DNS checks, alerts on state change
  email-triage/      Gmail (IMAP) + M365 (Graph MCP) triage, digest, approval-gated replies
  career-ops-daily/  daily job scan + scoring + tailored drafts via santifer/career-ops
docs/
  ARCHITECTURE.md    diagram, sizing, security guardrails
  RUNBOOK.md         phased rollout, SSM params, cron jobs, rotation, backup, troubleshooting
```

## Quickstart

1. **Discord + Tailscale + SSM:** create the Discord bot, apply the Tailscale ACL and put
   the secrets in SSM. See [RUNBOOK Phase 1](docs/RUNBOOK.md#phase-1---foundation-aws-tailscale-hermes-discord).
2. **Deploy:** `cd infra/terraform && cp terraform.tfvars.example terraform.tfvars && terraform init && terraform apply`.
   See [infra/README.md](infra/README.md).
3. **Install skills on the box:** clone to `/opt/hermes-jm` and symlink `skills/*` into `~/.hermes/skills/`.
   See [RUNBOOK 1.6](docs/RUNBOOK.md#16-install-the-skills).
4. **Homelab:** run `proxmox/setup-hermes-user.sh` on the PVE host, then set up LibreNMS and the subnet router.
   See [RUNBOOK Phase 2](docs/RUNBOOK.md#phase-2---proxmox--nms).
5. **Schedules:** set up sites, email, NMS, the career brief and the weekly inventory.
   See [RUNBOOK 3.4](docs/RUNBOOK.md#34-cron-jobs).

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the guardrails before you give the
agent any credentials. Hermes never destroys infrastructure or sends email without explicit
approval in Discord. It also treats email and web content as untrusted data.
