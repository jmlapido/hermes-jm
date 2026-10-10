# Microsoft 365 mail via Microsoft Graph (self-hosted MCP)

Hermes reaches your M365 mailbox through the open-source
[Softeria `ms-365-mcp-server`](https://github.com/Softeria/ms-365-mcp-server), running as a
local stdio MCP server on the EC2 instance. It uses **your own Entra ID app registration**
and **delegated** sign-in (device code). No third party sits in the mail path, and no IMAP
or SMTP basic auth is involved.

Why delegated rather than app-only: a delegated token can only open the signed-in user's
mailbox, so you don't need an Application Access Policy or RBAC for Applications to stop it
reading other mailboxes in the tenant. App-only plus RBAC for Applications is only worth it
for a shared mailbox nobody signs in to.

## 1. Entra ID app registration (about 10 minutes)

Entra admin center → **App registrations** → **New registration**

| Setting | Value |
|---|---|
| Name | `hermes-mail` |
| Supported account types | Single tenant (this org only) |
| Redirect URI | leave empty |

Then:

1. **Authentication** → *Advanced settings* → **Allow public client flows = Yes**. Device code
   login needs this. No client secret is needed.
2. **API permissions** → Microsoft Graph → **Delegated**:
   - `User.Read`
   - `offline_access`
   - `Mail.ReadWrite` (read, label/categorise, move, create drafts)
   - **Do not add `Mail.Send`.** Without it the agent cannot send mail, whatever the prompt or
     tool config says. Drafts show up in Outlook's Drafts folder and you press Send yourself.
     Add it later only if you want "send e12" from Discord to work.
3. **Grant admin consent** for the tenant.
4. Copy the **Application (client) ID** and **Directory (tenant) ID**.

Optional hardening:
- **Enterprise applications** → `hermes-mail` → Properties → *Assignment required = Yes*, and
  assign only your own user.
- **Conditional Access:** if a policy blocks the *device code flow* (Microsoft recommends
  blocking it by default), exclude this app or your user from that policy for the one-time
  login. You can also limit it to the EC2's public IP as a named location.

## 2. Secrets in SSM

| Parameter | Value |
|---|---|
| `/hermes/env/MS365_MCP_CLIENT_ID` | Application (client) ID |
| `/hermes/env/MS365_MCP_TENANT_ID` | Directory (tenant) ID (not `common`) |
| `/hermes/env/MS365_MCP_TOKEN_CACHE_PATH` | `/home/hermes/.hermes/ms365/token-cache.json` |

Store them as SecureString, then run `sudo systemctl restart hermes-gateway` so they land in
`~/.hermes/.env`.

## 3. Install on EC2 (as user `hermes`)

```bash
sudo -iu hermes
# Node 20+ is required; Ubuntu 24.04's apt nodejs is too old
node -v || { curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs; }

# Install a pinned version, not "latest" (an npm supply-chain incident would otherwise hit you on restart)
npm view @softeria/ms-365-mcp-server version     # note the version
npm install -g @softeria/ms-365-mcp-server@<version>

mkdir -p ~/.hermes/ms365 && chmod 700 ~/.hermes/ms365
set -a; . ~/.hermes/.env; set +a

# One-time device-code login: open https://microsoft.com/devicelogin on your phone and enter the code
ms-365-mcp-server --org-mode --login
```

Refresh tokens roll over as long as the 30-minute triage keeps using them. If the agent is
off for more than about 90 days, or you change your password or MFA, run `--login` again.

## 4. Register the MCP server in Hermes (`~/.hermes/config.yaml`)

```yaml
mcp_servers:
  m365:
    command: ms-365-mcp-server
    args: ["--org-mode", "--preset", "mail"]
    env:
      MS365_MCP_CLIENT_ID: "${MS365_MCP_CLIENT_ID}"
      MS365_MCP_TENANT_ID: "${MS365_MCP_TENANT_ID}"
      MS365_MCP_TOKEN_CACHE_PATH: "${MS365_MCP_TOKEN_CACHE_PATH}"
    tools:
      # Defence in depth on top of the missing Mail.Send scope
      exclude: ["send-mail", "send-draft-message", "delete-mail-message"]
```

Run `/reload-mcp` in a Hermes chat, or restart the gateway. Tools appear as `mcp_m365_<tool>`.
Check the exact tool names with "list your m365 tools" in Discord, and adjust `exclude` if
upstream renames them.

Smoke test in `#email`: *"Using m365, list my 5 newest unread emails (sender + subject only)."*

## 5. Layers of protection

| Layer | Stops |
|---|---|
| No `Mail.Send` consent in Entra | Any send, even if a tool is called |
| `tools.exclude` in Hermes | Agent never sees send or delete tools |
| email-triage hard rules | Prompt injection in mail, actions without approval |
| Delegated token | Access to any mailbox except yours |
| Assignment required + Conditional Access | Other users or locations using the app |

## 6. Rotation and revocation

- Revoke at once: Entra → Enterprise applications → `hermes-mail` → *Users and groups* (remove
  yourself), or **My Sign-ins** → revoke sessions. Then delete
  `~/.hermes/ms365/token-cache.json`.
- There is no secret to rotate (public client). Re-run `--login` after a revoke.
- The token cache lives on the EBS volume, so it's in the daily snapshots. Treat snapshots as
  sensitive and keep them unshared.
