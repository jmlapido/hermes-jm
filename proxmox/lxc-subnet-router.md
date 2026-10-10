# Tailscale subnet router in an unprivileged LXC (Debian 12)

Advertises the home LAN `192.168.1.0/24` to the tailnet so Hermes (on EC2,
`tag:hermes`) can reach LAN devices. What it may reach is limited by
`tailscale/acl.hujson`.

## 1. Create the CT

```bash
# on the PVE host
pveam update && pveam download local debian-12-standard_12.7-1_amd64.tar.zst
pct create 200 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname ts-router --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 0 --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.5/24,gw=192.168.1.1 \
  --onboot 1
```

(Check `pveam available --section system` for the current template file name.)

## 2. Pass through `/dev/net/tun`

Append to `/etc/pve/lxc/200.conf` (CT stopped):

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Then `pct start 200 && pct enter 200`.

## 3. Install Tailscale and enable forwarding (inside the CT)

```bash
apt update && apt install -y curl
curl -fsSL https://tailscale.com/install.sh | sh

cat >/etc/sysctl.d/99-tailscale.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf
```

## 4. Bring it up

Use a tagged, pre-authorized auth key (Admin console > Settings > Keys, tag
`tag:subnet-router`), so the node is not owned by a person and its key does
not expire with a user:

```bash
tailscale up --auth-key=tskey-auth-XXXX \
  --advertise-routes=192.168.1.0/24 \
  --advertise-tags=tag:subnet-router
```

The route is auto-approved by `autoApprovers` in the ACL; otherwise approve it
under Machines > ts-router > Edit route settings.

## 5. Verify

```bash
tailscale status
ls -l /dev/net/tun                       # inside CT: character device present
# from the Hermes EC2 host (needs --accept-routes on Linux clients):
sudo tailscale set --accept-routes
ping -c1 192.168.1.1
```

Notes:
- Do not run the subnet router on the PVE host itself; keeping it in a CT
  isolates it and lets you snapshot/rollback.
- If the LAN uses a different range, change `--advertise-routes`, the
  `autoApprovers` entry and the `192.168.1.0/24` grant together.
- Disable key expiry for this node in the admin console.
