# Setup Guide: Hermes Agent from zero to running

This guide puts every step in order. Each step says **who** does it, the command, and a
**Done when** check. Details are in the other docs, linked from each step.

- **YOU**: needs your accounts, MFA, root on the Proxmox host, or a secret only you should type.
- **CLAUDE**: Claude can do it from a Claude Code session if you give it access (see
  [Letting Claude do the CLAUDE steps](#letting-claude-do-the-claude-steps)). You can also do
  these steps yourself.

Total time is about 4–6 hours over a few days. The YOU parts take about 1.5 hours.

Before you start, fill in these placeholders:

| Placeholder | Example |
|---|---|
| `<tailnet>` | `tail1a2b3c` (Tailscale admin → DNS → tailnet name) |
| LAN subnet | `192.168.1.0/24`. Change it in `tailscale/acl.hujson` and `proxmox/lxc-subnet-router.md` if yours differs |
| PVE host | `pve01`, `https://192.168.1.10:8006` |

---

## Step 0: Accounts and keys (YOU, about 1 hour)

You need all of these before you deploy. Keep each secret in your password manager and
**never paste one into chat or git**.

| # | What | Where | Notes |
|---|---|---|---|
| 0.1 | AWS account with MFA on root, plus an admin IAM user for yourself | AWS console | Region **ap-southeast-1** |
| 0.2 | Tailscale: MagicDNS **and HTTPS Certificates** on | Tailscale admin → DNS | Needed for the dashboards |
| 0.3 | Discord server "JM Ops" with `#ops-alerts` `#email` `#career` `#proxmox`, and a bot | [RUNBOOK 1.1](RUNBOOK.md#11-discord-server-and-bot) | Turn on **Message Content Intent**. Copy the bot token and your user ID |
| 0.4 | LLM API key with a monthly spend limit | OpenRouter, Nous Portal or Anthropic | |
| 0.5 | Gmail app password, if you use Gmail | Google Account → Security → App passwords | Needs 2-Step Verification |
| 0.6 | Entra app `hermes-mail` (**no `Mail.Send`**), admin consent | [M365-GRAPH.md §1](M365-GRAPH.md#1-entra-id-app-registration-about-10-minutes) | Copy the client ID and tenant ID |
| 0.7 | GitHub deploy key (read-only) for `jmlapido/hermes-jm`, if the repo is private | Repo → Settings → Deploy keys | The EC2 uses it to `git clone` |

**Done when:** you have the bot token, Discord user ID, LLM key, Entra client and tenant
IDs, and (if you use Gmail) the Gmail app password.

---

## Step 1: Tailnet rules and auth key (YOU, or CLAUDE with a Tailscale API token)

1. Edit the LAN subnet in [`tailscale/acl.hujson`](../tailscale/acl.hujson) if it isn't
   `192.168.1.0/24`. Paste the file into Tailscale admin → **Access controls** → Save.
   Saving runs the built-in tests.
2. Create an auth key: **one-off, pre-approved, tag `tag:hermes`**.

**Done when:** the ACL saves with all tests passing, and you have a `tskey-auth-…` key.

---

## Step 2: Secrets into AWS Parameter Store (YOU)

From your own terminal, after `aws configure` with your admin user. Prefix each line with
a space so it stays out of shell history.

```bash
export HISTCONTROL=ignorespace
R=ap-southeast-1
put() { aws ssm put-parameter --region $R --type SecureString --overwrite --name "$1" --value "$2" >/dev/null && echo "ok $1"; }

 put /hermes/tailscale_authkey              'tskey-auth-...'
 put /hermes/env/OPENROUTER_API_KEY         'sk-or-...'
 put /hermes/env/DISCORD_BOT_TOKEN          '...'
 put /hermes/env/DISCORD_ALLOWED_USERS      '<your discord user id>'
 put /hermes/env/HERMES_TIMEZONE            'Asia/Dubai'
```

Leave the rest (Proxmox, LibreNMS, email, dashboards) for later steps. The full list is in
[RUNBOOK 1.3](RUNBOOK.md#13-ssm-parameters).

**Done when:** `aws ssm describe-parameters --region $R --query 'Parameters[].Name'` lists
the five parameters.

---

## Step 3: Deploy the EC2 (CLAUDE or YOU, about 15 minutes)

```bash
git clone https://github.com/jmlapido/hermes-jm && cd hermes-jm/infra/terraform
cp terraform.tfvars.example terraform.tfvars      # set budget_alert_email; keep t4g.medium
terraform init
terraform plan                                    # review: VPC, SG with 0 ingress, 1 instance, IAM, DLM, budget
terraform apply
```

- **Where Terraform keeps its state:** state is the record of what Terraform built, and it's
  local by default. Keep it on your laptop and back it up. If Claude deploys, it uses the
  S3 backend in `versions.tf` (bucket `hermes-jm-tfstate-<random>`), because Claude's
  session is temporary.
- **Budget alert:** accept the AWS Budgets confirmation email.
- Details: [infra/README.md](../infra/README.md).

**Done when:**
- Tailscale admin shows **hermes-aws** online with `tag:hermes`.
- `aws ssm start-session --target <instance_id>`, then
  `sudo tail -5 /var/log/hermes-bootstrap.log`, shows no errors.
- `sudo systemctl status hermes-gateway` shows active.

---

## Step 4: Hermes first run (CLAUDE, then YOU check Discord)

On the box (`tailscale ssh hermes@hermes-aws` or an SSM session):

```bash
sudo -iu hermes hermes doctor
sudo -iu hermes hermes setup          # only if doctor says no model/provider is set
sudo mkdir -p /opt/hermes-jm && sudo chown hermes:hermes /opt/hermes-jm
sudo -iu hermes git clone https://github.com/jmlapido/hermes-jm.git /opt/hermes-jm
sudo -u hermes -H bash -c 'for d in /opt/hermes-jm/skills/*/; do ln -sfn "${d%/}" ~/.hermes/skills/$(basename "$d"); done'  # not -i: it mangles $(...)
sudo -iu hermes bash -c 'mkdir -p ~/.hermes/scripts ~/.hermes/state'
sudo systemctl restart hermes-gateway
```

- **Repo access:** if the repo is private, clone over SSH with the deploy key from 0.7.
- **Branch:** until this work is merged, add `-b claude/tender-hypatia-d4vpfm` to the clone.

**YOU:** in Discord, DM the bot "hello".

**Done when:** it answers you, and it ignores anyone not on the allowlist
([RUNBOOK 1.5](RUNBOOK.md#15-discord-allowlist-check)).

---

## Step 5: Proxmox side (YOU, root on the PVE host, about 45 minutes)

Claude has no route to your Philippines LAN. These steps happen on the Proxmox host itself.

1. **Hermes user and token:**
   `bash proxmox/setup-hermes-user.sh` creates `hermes@pve`, pool `agent-pool` and token
   `hermes@pve!agent`. Copy the secret it prints **once**.
2. **Subnet router CT:** follow [proxmox/lxc-subnet-router.md](../proxmox/lxc-subnet-router.md).
   Approve the `192.168.1.0/24` route in Tailscale admin if it isn't auto-approved.
3. **LibreNMS CT:** follow [proxmox/lxc-librenms.md](../proxmox/lxc-librenms.md). Add your
   switches, MikroTik and UniFi gear over SNMP, then create a **read-only** API token.
4. **Uptime Kuma CT (optional):** gives the inside view of your websites. You can also ask
   Hermes to create it later (Step 6).
5. **Secrets (from your terminal):**

   ```bash
    put /hermes/env/PROXMOX_HOST          'https://pve01.<tailnet>.ts.net:8006'
    put /hermes/env/PROXMOX_TOKEN_ID      'hermes@pve!agent'
    put /hermes/env/PROXMOX_TOKEN_SECRET  '<secret from 5.1>'
    put /hermes/env/LIBRENMS_URL          'http://librenms.<tailnet>.ts.net'
    put /hermes/env/LIBRENMS_TOKEN        '<librenms token>'
   ```

**Done when:** the PVE host, LibreNMS CT and subnet router all show online in Tailscale admin.

---

## Step 6: Connect Hermes to Proxmox and LibreNMS (CLAUDE, YOU approve in Discord)

```bash
sudo systemctl restart hermes-gateway
sudo -iu hermes bash -lc 'set -a; . ~/.hermes/.env; set +a
  ~/.hermes/skills/proxmox-manage/pve.sh version
  ~/.hermes/skills/proxmox-manage/pve.sh list
  ~/.hermes/skills/nms-report/nms.sh summary | jq ".devices, .alerts"'
```

**YOU, in `#proxmox`:**
1. "list my Proxmox guests"
2. "create a test debian CT called hermes-test, 1 core 512MB 4GB"
3. "destroy hermes-test". It must ask you to confirm with `yes destroy <vmid>`.

**Done when:** the create works and returns an IP, and destroy asks for confirmation.

---

## Step 7: Email (YOU sign in once, CLAUDE does the rest)

### Microsoft 365
1. Put `MS365_MCP_CLIENT_ID`, `MS365_MCP_TENANT_ID` and `MS365_MCP_TOKEN_CACHE_PATH` in SSM
   ([M365-GRAPH.md §2](M365-GRAPH.md#2-secrets-in-ssm)). Then **CLAUDE** installs Node and the
   pinned MCP server and adds the `mcp_servers.m365` block (§3–4).
2. **YOU:** on the box, run `ms-365-mcp-server --org-mode --login`, then open
   microsoft.com/devicelogin on your phone and sign in with MFA.

### Gmail (optional)
`EMAIL_*` parameters in SSM, plus the himalaya config in
[skills/email-triage/SKILL.md](../skills/email-triage/SKILL.md).

**YOU, in `#email`:** "triage my inbox now, don't change anything".

**Done when:** you get a summary, and the drafts it makes appear in Outlook Drafts.

---

## Step 8: Website monitoring, career-ops and schedules (CLAUDE)

1. **Websites:** put your sites in `~/.hermes/sites.txt` (YOU give Claude the list), then
   create the `site-alerts.sh` wrapper ([RUNBOOK 3.1](RUNBOOK.md#31-sites)).
2. **career-ops:** clone and install it ([RUNBOOK 3.3](RUNBOOK.md#33-career-ops)).
   **YOU** provide `cv.md` and your targets in `config/profile.yml`.
3. **Schedules:** create all six `hermes cron create` jobs from
   [RUNBOOK 3.4](RUNBOOK.md#34-cron-jobs). For Microsoft 365 jobs, use the m365 tools
   instead of `--skill himalaya`.
4. Run each job once with `hermes cron run <id>`.

**Done when:** every job's test run posts to its Discord channel, and site alerts stay
quiet while all sites are up.

---

## Step 9: Dashboards (CLAUDE on EC2, YOU on the Homepage CT)

Everything is in [DASHBOARDS.md](DASHBOARDS.md):

1. **Secrets (YOU):** `API_SERVER_ENABLED`, `API_SERVER_KEY` and the four
   `HERMES_DASHBOARD_*` parameters in SSM. You pick the dashboard password.
2. **On the EC2 (CLAUDE):** Open WebUI with `docker compose up -d`, the admin dashboard
   systemd unit, then `sudo /opt/hermes-jm/dashboards/tailscale-serve.sh`.
3. **YOU:** open `https://hermes-aws.<tailnet>.ts.net` and **create your account first**.
   The first account becomes admin.
4. **Homepage CT (YOU):** follow [dashboards/homepage/README.md](../dashboards/homepage/README.md).
   Tag the CT `tag:homepage` and give it its own read-only `hermes@pve!homepage` token.

**Done when:**
- Open WebUI answers you and can run "list my Proxmox guests".
- `:8443` asks for a login.
- Homepage tiles show green.

---

## Step 10: Go-live checklist

- [ ] Discord: only you can command the bot.
- [ ] Website check: stop a test site, get an alert in `#ops-alerts` within 20 minutes, then a recovery message.
- [ ] Network: the 07:00 Manila report arrives in `#ops-alerts`.
- [ ] Email: the 07:30 Dubai digest arrives, and nothing is sent or deleted without you.
- [ ] Proxmox: Hermes can't touch a guest outside `agent-pool` (try it, expect a refusal).
- [ ] Career: the 08:00 brief arrives in `#career`.
- [ ] AWS: budget alert confirmed. `aws ec2 describe-security-groups` shows 0 inbound rules.
- [ ] Dashboards: nothing reachable from outside the tailnet. From mobile data with Tailscale off, every URL fails.
- [ ] Backups: a DLM snapshot exists the next day.

For Day 2 (rotating keys, restore, troubleshooting), see [RUNBOOK Day-2](RUNBOOK.md#day-2-operations).
Paperclip comes later: [RUNBOOK Phase 4](RUNBOOK.md#phase-4---paperclip-ai-integration-later).

---

## Letting Claude do the CLAUDE steps

Claude works from a cloud session that is **not** on your tailnet or LAN. It can reach AWS
APIs. Through **AWS SSM Run Command** it can run shell commands on the EC2 without SSH,
open ports or Tailscale. That covers Steps 3, 4 and 6–9 on the EC2 side.

### Give access safely
1. **Create the IAM user:** in IAM, create `claude-deployer` with **only** the policy in
   [`infra/iam/claude-deployer-policy.json`](../infra/iam/claude-deployer-policy.json):
   - EC2 in Singapore only.
   - IAM limited to the `hermes-agent-*` roles.
   - SSM: it can **write** `/hermes/*` parameters but **cannot read** them.
   - Run Command only on the instance tagged `hermes-agent`.
   - The Terraform state bucket.
2. **Add the key to the Claude environment:** create an access key and add it to the Claude
   Code environment settings as environment secrets `AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY` (plus `AWS_DEFAULT_REGION=ap-southeast-1`). Don't paste it into
   chat. A new session picks it up.
3. **Optional, Tailscale API token:** add it as `TAILSCALE_API_KEY` so Claude can apply the
   ACL and create the tagged auth key (Step 1).
4. **Revoke afterwards:** when setup is done, deactivate the access key. Re-enable it only
   when you want Claude to change something.

### Be aware
- **Run Command means root on the EC2.** Claude can't read the parameters through the AWS
  API, but a command on the box could read `~/.hermes/.env`. Claude won't print secrets, but
  only give this access if you're comfortable with that. Revoke the key when done.
- **What Claude can't do:** create your accounts, pass MFA, do the Microsoft device-code
  sign-in, choose your passwords, or run anything on the Proxmox host. Those stay YOU
  steps, by design.
