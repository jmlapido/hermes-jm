# Hermes Agent on AWS (EC2, ap-southeast-1)

This sets up one Graviton EC2 instance in Singapore that runs the Nous Research **Hermes Agent** gateway around the clock. The agent talks to you over Discord and email, and it reaches the Proxmox homelab in the Philippines through Tailscale.

```
infra/
├── cloud-init.yaml          # first-boot bootstrap (templatefile)
└── terraform/               # VPC, SG, EC2, IAM, DLM snapshots, budget
```

## Design

- A dedicated VPC `10.42.0.0/16` with one public subnet and an IGW. There's no NAT gateway, to keep costs down.
- The **security group has no inbound rules.** The public IP is used only for outbound traffic: LLM APIs, the Discord gateway websocket, IMAP/SMTP and Tailscale.
- Access is through **SSM Session Manager** or **Tailscale SSH**. There's no key pair and port 22 is closed.
- Ubuntu 24.04 arm64 runs on a `t4g.medium` with a 40 GB gp3 encrypted root volume. IMDSv2 is required, with a hop limit of 2 so Docker containers can reach it.
- Secrets live in SSM Parameter Store as SecureString. The instance role can read only `/hermes/*`.
- DLM takes a daily EBS snapshot and keeps 7. A monthly AWS Budget sends email alerts at 80% and 100% of the limit.

## Prerequisites

- Terraform >= 1.5 and AWS CLI v2, with credentials for the target account.
- The AWS CLI [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
- A Tailscale tailnet with these settings:
  - `tag:hermes` defined in the ACL `tagOwners`.
  - A **reusable or pre-authorized auth key** that is tagged `tag:hermes`.
  - ACL/SSH rules that allow the node to reach the Proxmox hosts and allow you to `tailscale ssh` into it.
- A Discord bot token (Discord Developer Portal) and an email app password.

## 1. Create SSM parameters (SecureString)

Create these **before** `terraform apply`, because cloud-init reads them on first boot.

| Parameter | Purpose |
|---|---|
| `/hermes/tailscale_authkey` | Tailscale auth key (tagged `tag:hermes`) |
| `/hermes/env/OPENROUTER_API_KEY` | LLM provider key |
| `/hermes/env/DISCORD_BOT_TOKEN` | Discord bot token |
| `/hermes/env/DISCORD_ALLOWED_USERS` | Comma-separated Discord user IDs allowed to talk to the bot |
| `/hermes/env/EMAIL_IMAP_HOST` | e.g. `imap.gmail.com` |
| `/hermes/env/EMAIL_SMTP_HOST` | e.g. `smtp.gmail.com` |
| `/hermes/env/EMAIL_USER` | Mailbox username |
| `/hermes/env/EMAIL_APP_PASSWORD` | App password (not your main password) |
| `/hermes/env/PROXMOX_HOST` | e.g. `https://pve.tailnet-name.ts.net:8006` |
| `/hermes/env/PROXMOX_TOKEN_ID` | e.g. `hermes@pve!agent` |
| `/hermes/env/PROXMOX_TOKEN_SECRET` | Proxmox API token secret |
| `/hermes/env/LIBRENMS_URL` | e.g. `https://nms.tailnet-name.ts.net` |
| `/hermes/env/LIBRENMS_TOKEN` | LibreNMS read-only API token |
| `/hermes/env/HERMES_TIMEZONE` | `Asia/Dubai` (one timezone for all cron jobs) |
| `/hermes/env/DISCORD_HOME_CHANNEL` | Optional: default channel for deliveries |
| `/hermes/env/EMAIL_IMAP_PORT` / `EMAIL_SMTP_PORT` | Optional: defaults 993 / 587 |
| `/hermes/env/PROXMOX_CA_FILE` | Optional: path to Proxmox CA cert (else TLS is not verified) |

See `docs/RUNBOOK.md` for the full table. Microsoft 365 uses Microsoft Graph through a self-hosted MCP server instead (`MS365_MCP_*` params). See `docs/M365-GRAPH.md`.

Every parameter under `/hermes/env/` becomes `KEY=value` in `/home/hermes/.hermes/.env`. To add more keys, create new parameters there. Check the exact variable names Hermes expects against its docs.

```bash
R=ap-southeast-1
aws ssm put-parameter --region $R --type SecureString --name /hermes/tailscale_authkey --value 'tskey-auth-...'
aws ssm put-parameter --region $R --type SecureString --name /hermes/env/OPENROUTER_API_KEY --value 'sk-or-...'
aws ssm put-parameter --region $R --type SecureString --name /hermes/env/DISCORD_BOT_TOKEN --value '...'
aws ssm put-parameter --region $R --type SecureString --name /hermes/env/DISCORD_ALLOWED_USERS --value '123456789012345678'
# ...and so on. Use --overwrite to update a value.
```

To apply changed secrets on a running instance, restart the service: `sudo systemctl restart hermes-gateway`. Its `ExecStartPre` reloads the secrets from SSM.

## 2. Deploy

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # set budget_alert_email
terraform init
terraform plan
terraform apply
```

AWS sends a confirmation email for the budget alert subscription. Accept it.

Bootstrap takes about 5 minutes. To watch its progress:

```bash
aws ssm start-session --region ap-southeast-1 --target <instance_id>
sudo tail -f /var/log/hermes-bootstrap.log
```

## 3. Connect

```bash
# SSM (always works, needs only AWS creds)
aws ssm start-session --region ap-southeast-1 --target $(terraform output -raw instance_id)

# Tailscale SSH (once the node has joined the tailnet)
tailscale ssh hermes@hermes-aws
```

## 4. Post-install checks

```bash
sudo -iu hermes which hermes          # unit assumes /home/hermes/.local/bin/hermes
systemctl status hermes-gateway
journalctl -u hermes-gateway -f
tailscale status
```

If `which hermes` returns a different path, edit `ExecStart` in `/etc/systemd/system/hermes-gateway.service`, then run `systemctl daemon-reload && systemctl restart hermes-gateway`. If the upstream installer needed interactive input, finish it with `sudo -iu hermes hermes setup`.

## Cost estimate (ap-southeast-1, on-demand)

| Item | ~US$/month |
|---|---|
| t4g.medium (24/7) | 25–30 |
| 40 GB gp3 EBS | ~3.2 |
| Public IPv4 address | ~3.6 |
| Daily snapshots, 7 kept (incremental) | ~0.5–2 |
| SSM, Parameter Store (standard), DLM, Budgets | ~0 |
| **Total** | **~US$32–40** |

LLM API usage is billed separately by the provider. To save about 30–40% on compute, use a 1-year Compute Savings Plan or choose `t4g.small`.

## Notes

- The instance ignores `ami` and `user_data` changes, so a new Ubuntu AMI won't recreate it. To rebuild deliberately, run `terraform apply -replace=aws_instance.hermes`. Snapshots let you restore data first.
- To restore from a snapshot, create a volume from the DLM snapshot, stop the instance, and swap the root volume (or use EC2 "Replace root volume").
