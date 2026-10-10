# Homepage - JM Ops NOC dashboard

[Homepage](https://gethomepage.dev) in its own Proxmox LXC, reachable only over the tailnet
(`tailscale serve`, no LAN or public port). One page shows:

| Group | Card | Source |
|---|---|---|
| Infrastructure | Proxmox VE (pve01) | `proxmox` widget, read-only API token |
| Network | LibreNMS | `customapi` x3 on the LibreNMS API (devices / down / active alerts) |
| Network | Tailscale (hermes-aws) | `tailscale` widget |
| Websites | Uptime Kuma | `uptimekuma` widget, status page `sites` |
| Hermes | Hermes API, Hermes Dashboard, Open WebUI | `siteMonitor` (green dot = up) |
| Links | AWS console, Entra, Tailscale admin, GitHub, Discord | `bookmarks.yaml` |

Homepage has no native LibreNMS widget. The LibreNMS card uses `customapi` with the
same `/api/v0` endpoints as `skills/nms-report/nms.sh`.

```text
docker-compose.yml   pinned image, 127.0.0.1:3000 only, no docker.sock
.env.example         HOMEPAGE_VAR_* secrets and URLs -> copy to .env
config/settings.yaml title, theme, colour, group layout
config/widgets.yaml  header: CT resources, Manila clock, search
config/services.yaml service cards and widgets
config/bookmarks.yaml Links group
```

## 1. Create the CT (on pve01)

```bash
pct create 220 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname homepage --unprivileged 1 --features nesting=1,keyctl=1 \
  --cores 1 --memory 1024 --swap 512 --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp --onboot 1
```

Docker needs `nesting=1,keyctl=1`. Tailscale needs `/dev/net/tun`: add the two `lxc.*`
lines from [proxmox/lxc-subnet-router.md](../../proxmox/lxc-subnet-router.md#2-pass-through-devnettun)
to `/etc/pve/lxc/220.conf`, then `pct start 220`.

## 2. Install Docker and Tailscale (inside the CT)

```bash
apt update && apt install -y curl ca-certificates
curl -fsSL https://get.docker.com | sh
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --hostname homepage        # tag it in the admin console per tailscale/acl.hujson
```

The Tailscale ACL must let this node reach pve01:8006, the LibreNMS and Uptime Kuma CTs
(directly or through the subnet router), and `hermes-aws` on 443 (Open WebUI), 8443 (admin
dashboard) and 9443 (`/health` only). Tag this CT `tag:homepage`; `tailscale/acl.hujson` grants
exactly those ports. The agent API port 8642 stays on the EC2's loopback and is never exposed.

## 3. Proxmox: a separate read-only token

Do not reuse `hermes@pve!agent`. It can create and change guests. Give Homepage its own
token with `PVEAuditor` only (run on pve01):

```bash
pveum user token add hermes@pve homepage --privsep 1 --comment "Homepage NOC (read-only)"
pveum acl modify / --tokens 'hermes@pve!homepage' --roles PVEAuditor --propagate 1
pveum user token permissions hermes@pve homepage   # check: audit privileges only
```

A privsep token gets the intersection of the user's and the token's rights.
`setup-hermes-user.sh` grants `hermes@pve` PVEAuditor on `/` by default. If you ran it with
`--no-auditor`, create a dedicated `homepage@pve` user with PVEAuditor on `/` and put the
token on that user instead. To revoke: `pveum user token remove hermes@pve homepage`.

## 4. Deploy

```bash
mkdir -p /opt/homepage && cd /opt/homepage
# copy this folder here (scp/rsync from the repo, or a git sparse checkout)
cp .env.example .env && chmod 600 .env && nano .env   # tokens, URLs, HOMEPAGE_ALLOWED_HOSTS
chown -R 1000:1000 config                              # matches PUID/PGID
docker compose up -d
docker compose logs -f homepage                        # look for errors
tailscale serve --bg 3000                              # https://homepage.<tailnet>.ts.net
tailscale serve status
```

Set `HOMEPAGE_ALLOWED_HOSTS` in `.env` to the exact name `tailscale serve status` prints, for
example `homepage.tail1234.ts.net`. If the page shows a host validation error, copy the host
from the container log into that variable and run `docker compose up -d`. Never set it to `*`.

Secrets live only in `.env`. Homepage substitutes `{{HOMEPAGE_VAR_X}}` in the YAML with the
value of the env var `HOMEPAGE_VAR_X`. To keep a secret in a file instead, mount the file and
set `HOMEPAGE_FILE_X=/path/in/container`, then reference `{{HOMEPAGE_FILE_X}}`.

Config edits apply on page reload. A new `.env` value needs `docker compose up -d`.

## Customize

- **Add a service:** add an entry under a group in `config/services.yaml` (`icon`, `href`,
  `description`, optional `siteMonitor: <url>` for an up/down dot, optional `widget:`). A
  new group also needs an entry under `layout:` in `settings.yaml` to control its position
  and columns.
- **Add a widget:** find the service on the
  [service widgets list](https://gethomepage.dev/widgets/), copy its `widget:` block into
  the service, and put its key in `.env` as `HOMEPAGE_VAR_...`. For anything with a JSON API,
  use [`customapi`](https://gethomepage.dev/widgets/services/customapi/) with `mappings`.
  Header widgets (clock, weather, search, glances) go in `widgets.yaml`.
- **Theme and colours:** `theme: dark|light` and `color:` (slate, zinc, blue, emerald and
  others) in `settings.yaml`. Also `headerStyle`, `statusStyle`, `cardBlur`.
- **Background:** set `background: https://...` to use a URL. For a local image, add the
  volume `./images:/app/public/images`, set `background: /images/noc.jpg` and restart.
- **Icons:** use a name from [dashboard-icons](https://github.com/homarr-labs/dashboard-icons)
  (`proxmox.svg`, `librenms.svg`) or a prefixed icon: `mdi-...` for Material Design, `si-...`
  for Simple Icons, `sh-...` for selfh.st. Icons load from a CDN in the browser.
- **Upgrade:** bump the image tag in `docker-compose.yml` after reading the
  [release notes](https://github.com/gethomepage/homepage/releases), then
  `docker compose pull && docker compose up -d`.

## Troubleshooting

- **The widget shows "API Error":** open the service URL from inside the container with
  `docker exec homepage wget -qO- <url>`. Tailnet names not resolving inside the container?
  Uncomment `dns: [100.100.100.100]` in the compose file.
- **The Proxmox card is empty:** check that the token ID is in the form
  `hermes@pve!homepage` and that `node` is the real node name (`pvesh get /nodes`).
  Homepage's widget proxy accepts the self-signed PVE certificate.
- **The Uptime Kuma card is empty:** the `sites` status page must exist and be published,
  with monitors added to it.
- **The Tailscale card shows an error:** API access tokens expire after at most 90 days, so
  rotate the key in `.env`.

Docs: <https://gethomepage.dev>. The config reference is under *Configs*. Widgets are under
*Widgets → Services / Info*. Install options are under *Installation*.
