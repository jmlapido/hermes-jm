# LibreNMS in a Proxmox CT

Hermes reads monitoring data from LibreNMS through its REST API over
Tailscale (`tag:nms`, ports 80/443).

## 1. Create the CT

Docker inside LXC needs `nesting=1` and `keyctl=1`:

```bash
pct create 210 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname librenms --unprivileged 1 --features nesting=1,keyctl=1 \
  --cores 2 --memory 4096 --swap 512 --rootfs local-lvm:32 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.6/24,gw=192.168.1.1 \
  --onboot 1
pct start 210 && pct enter 210
```

## 2. Deploy LibreNMS

**Option A — docker compose (recommended)**, from
[librenms/docker](https://github.com/librenms/docker):

```bash
apt update && apt install -y curl git
curl -fsSL https://get.docker.com | sh
git clone https://github.com/librenms/docker.git /opt/librenms-docker
cd /opt/librenms-docker/examples/compose
# edit .env: TZ=Asia/Manila, MYSQL_PASSWORD=<strong random>
# edit librenms.env as needed
docker compose up -d
```

UI on `http://<ct-ip>:8000`. Put it behind TLS (e.g. `tailscale serve
--https=443 http://localhost:8000`) so the URL Hermes uses is HTTPS.

**Option B — official install** on Debian 12:
<https://docs.librenms.org/Installation/Install-LibreNMS/> (nginx + php-fpm +
MariaDB, then `./validate.php`).

## 3. Join the tailnet

Install Tailscale in the CT (needs the same `/dev/net/tun` passthrough as in
`lxc-subnet-router.md`) and bring it up with `--advertise-tags=tag:nms`.
Alternatively skip this and let Hermes reach the CT through the subnet router
on 80/443.

## 4. API token for Hermes

Create a dedicated read-only user (`hermes`, level *Global Read*), log in as it,
then **Settings (gear) > API > API Settings > Create API access token**.
Test:

```bash
curl -s -H "X-Auth-Token: $TOKEN" https://librenms.<tailnet>.ts.net/api/v0/devices | head
```

## 5. Store in AWS SSM

```bash
aws ssm put-parameter --name /hermes/env/LIBRENMS_URL \
  --type String --overwrite --value 'https://librenms.<tailnet>.ts.net'
aws ssm put-parameter --name /hermes/env/LIBRENMS_TOKEN \
  --type SecureString --overwrite --value '<token>'
```

## 6. Enable SNMP on devices

Prefer SNMPv3 (authPriv, SHA + AES). Allow polling only from the LibreNMS IP.

**MikroTik RouterOS**

```
/snmp community set [find default=yes] disabled=yes
/snmp community add name=librenms security=private authentication-protocol=SHA1 \
  encryption-protocol=AES authentication-password=<auth> encryption-password=<priv> \
  addresses=192.168.1.6/32 read-access=yes write-access=no
/snmp set enabled=yes contact="admin" location="PH home"
```

**Ubiquiti UniFi** — Network app > Settings > System > SNMP: enable v3 (or
v1/v2c with a non-default community); applies to adopted switches/APs.
**EdgeRouter/EdgeOS**: `set service snmp community <name> authorization ro`,
`set service snmp community <name> client 192.168.1.6`, `commit; save`.

**Managed switches (TP-Link/Netgear/Cisco etc.)** — enable SNMP in the web UI,
create a read-only v3 user or v2c community, and restrict it to the LibreNMS
host. Cisco IOS example:

```
snmp-server group LIBRE v3 priv
snmp-server user librenms LIBRE v3 auth sha <auth> priv aes 128 <priv>
```

Then add devices: **Devices > Add Device** or
`lnms device:add --v3 -a SHA -A <auth> -x AES -X <priv> -u librenms 192.168.1.1`.
Never enable SNMP write access.
