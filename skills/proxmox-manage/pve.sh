#!/usr/bin/env bash
# pve.sh - minimal Proxmox VE API helper for the Hermes `proxmox-manage` skill.
#
# Auth: API token (hermes@pve!agent), scoped to pool `agent-pool`.
# Required env:
#   PROXMOX_URL           e.g. https://pve.tailnet:8006/api2/json
#                         (PROXMOX_HOST=https://pve.tailnet:8006 also accepted; /api2/json is appended)
#   PROXMOX_TOKEN_ID      e.g. hermes@pve!agent
#   PROXMOX_TOKEN_SECRET  UUID secret
# Optional env:
#   PROXMOX_CA_FILE       PEM CA bundle for the PVE cert (otherwise TLS verify is skipped, with a warning)
#   PROXMOX_POOL          pool name (default: agent-pool) - create-ct always uses it
#   PROXMOX_SSH_PUBKEYS   path to an authorized_keys file injected into new containers
#   CONFIRM=yes           required for `destroy`
#
# All output is JSON (the API's .data) unless noted, so it pipes cleanly into jq.

set -euo pipefail

POOL="${PROXMOX_POOL:-agent-pool}"

die() { echo "pve.sh: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: pve.sh <command> [args]

Read-only:
  version                                   PVE version
  nodes                                     list nodes
  list                                      all VMs/CTs (cluster/resources type=vm)
  pool                                      members of the agent pool
  nextid                                    next free VMID
  templates <node> <storage>                CT templates (vztmpl) on a storage
  status <node> <lxc|qemu> <vmid>           current status
  ip <node> <vmid>                          LXC interfaces (IP addresses)
  task <node> <upid>                        task status
  wait <node> <upid> [timeout_s]            poll a task until it stops (default 300s)

Mutating (pool: agent-pool only):
  create-ct <node> <name> <cores> <memMB> <diskGB> <ostemplate> [bridge] [storage]
                                            unprivileged LXC, DHCP on net0, started
  start|stop|shutdown <node> <lxc|qemu> <vmid>
  snapshot <node> <lxc|qemu> <vmid> <snapname>
  destroy <node> <lxc|qemu> <vmid>          requires CONFIRM=yes and pool membership
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need curl
need jq

# Accept PROXMOX_URL (preferred) or PROXMOX_HOST (https://host:8006, as in infra/README.md).
PROXMOX_URL="${PROXMOX_URL:-${PROXMOX_HOST:-}}"
[[ -n "$PROXMOX_URL" ]] || die "PROXMOX_URL (or PROXMOX_HOST) not set (e.g. https://pve.tailnet:8006/api2/json)"
: "${PROXMOX_TOKEN_ID:?PROXMOX_TOKEN_ID not set}"
: "${PROXMOX_TOKEN_SECRET:?PROXMOX_TOKEN_SECRET not set}"
PROXMOX_URL="${PROXMOX_URL%/}"
[[ "$PROXMOX_URL" == */api2/json ]] || PROXMOX_URL="${PROXMOX_URL}/api2/json"

CURL_TLS=()
if [[ -n "${PROXMOX_CA_FILE:-}" ]]; then
  [[ -r "$PROXMOX_CA_FILE" ]] || die "PROXMOX_CA_FILE not readable: $PROXMOX_CA_FILE"
  CURL_TLS=(--cacert "$PROXMOX_CA_FILE")
else
  echo "pve.sh: WARNING: PROXMOX_CA_FILE not set - TLS verification disabled (-k). Traffic is inside the tailnet, but pin the CA when you can." >&2
  CURL_TLS=(-k)
fi

# api METHOD PATH [curl --data-urlencode args...]
api() {
  local method="$1" path="$2"; shift 2
  local resp http body
  resp=$(curl -sS "${CURL_TLS[@]}" --max-time 60 -X "$method" \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
    -w $'\n%{http_code}' "$@" "${PROXMOX_URL}${path}") || die "request failed: $method $path"
  http="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$http" -lt 200 || "$http" -ge 300 ]]; then
    echo "pve.sh: HTTP $http on $method $path" >&2
    echo "$body" >&2
    exit 2
  fi
  echo "$body" | jq '.data'
}

check_type() { [[ "$1" == "lxc" || "$1" == "qemu" ]] || die "type must be lxc or qemu (got '$1')"; }
check_id()   { [[ "$1" =~ ^[0-9]+$ ]] || die "vmid must be numeric (got '$1')"; }

# wait_task NODE UPID [timeout_s] -> prints final task status JSON
wait_task() {
  local node="$1" upid="$2" timeout="${3:-300}" waited=0 enc st
  enc=$(jq -rn --arg u "$upid" '$u|@uri')
  while :; do
    st=$(api GET "/nodes/${node}/tasks/${enc}/status")
    if [[ $(jq -r '.status' <<<"$st") == "stopped" ]]; then echo "$st"; return 0; fi
    (( waited >= timeout )) && die "timeout waiting for $upid"
    sleep 3; waited=$((waited + 3))
  done
}

in_pool() {
  local vmid="$1"
  api GET "/pools/${POOL}" | jq -e --argjson id "$vmid" '[.members[]? | select(.vmid == $id)] | length > 0' >/dev/null
}

cmd="${1:-}"; [[ -n "$cmd" ]] || { usage; exit 1; }; shift || true

case "$cmd" in
  version)  api GET /version ;;
  nodes)    api GET /nodes | jq '[.[] | {node, status, cpu, maxcpu, mem, maxmem, uptime}]' ;;
  list)     api GET /cluster/resources --get --data-urlencode type=vm \
              | jq '[.[] | {vmid, name, type, node, status, pool, maxcpu, maxmem, maxdisk, uptime}] | sort_by(.vmid)' ;;
  pool)     api GET "/pools/${POOL}" | jq '[.members[]? | {vmid, name, type, node, status}]' ;;
  nextid)   api GET /cluster/nextid ;;
  templates)
    [[ $# -eq 2 ]] || die "usage: templates <node> <storage>"
    api GET "/nodes/$1/storage/$2/content" --get --data-urlencode content=vztmpl | jq '[.[] | {volid, size}]' ;;
  status)
    [[ $# -eq 3 ]] || die "usage: status <node> <lxc|qemu> <vmid>"
    check_type "$2"; check_id "$3"
    api GET "/nodes/$1/$2/$3/status/current" | jq '{vmid, name, status, cpu, mem, maxmem, uptime, lock}' ;;
  ip)
    [[ $# -eq 2 ]] || die "usage: ip <node> <vmid>"
    check_id "$2"
    api GET "/nodes/$1/lxc/$2/interfaces" ;;
  task)
    [[ $# -eq 2 ]] || die "usage: task <node> <upid>"
    api GET "/nodes/$1/tasks/$(jq -rn --arg u "$2" '$u|@uri')/status" ;;
  wait)
    [[ $# -ge 2 ]] || die "usage: wait <node> <upid> [timeout_s]"
    wait_task "$1" "$2" "${3:-300}" ;;
  create-ct)
    [[ $# -ge 6 ]] || die "usage: create-ct <node> <name> <cores> <memMB> <diskGB> <ostemplate> [bridge] [storage]"
    node="$1"; name="$2"; cores="$3"; mem="$4"; disk="$5"; tmpl="$6"
    bridge="${7:-vmbr0}"; storage="${8:-local-lvm}"
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || die "invalid hostname '$name'"
    for n in "$cores" "$mem" "$disk"; do [[ "$n" =~ ^[0-9]+$ ]] || die "cores/mem/disk must be integers"; done
    vmid=$(api GET /cluster/nextid | jq -r '.')
    args=(
      --data-urlencode "vmid=${vmid}"
      --data-urlencode "hostname=${name}"
      --data-urlencode "ostemplate=${tmpl}"
      --data-urlencode "cores=${cores}"
      --data-urlencode "memory=${mem}"
      --data-urlencode "rootfs=${storage}:${disk}"
      --data-urlencode "net0=name=eth0,bridge=${bridge},ip=dhcp,ip6=auto,firewall=1"
      --data-urlencode "pool=${POOL}"
      --data-urlencode "unprivileged=1"
      --data-urlencode "features=nesting=1"
      --data-urlencode "onboot=1"
      --data-urlencode "start=1"
      --data-urlencode "description=Created by Hermes agent $(date -u +%FT%TZ)"
    )
    if [[ -n "${PROXMOX_SSH_PUBKEYS:-}" ]]; then
      [[ -r "$PROXMOX_SSH_PUBKEYS" ]] || die "PROXMOX_SSH_PUBKEYS not readable"
      args+=(--data-urlencode "ssh-public-keys@${PROXMOX_SSH_PUBKEYS}")
    fi
    upid=$(api POST "/nodes/${node}/lxc" "${args[@]}" | jq -r '.')
    jq -n --arg vmid "$vmid" --arg upid "$upid" --arg node "$node" --arg pool "$POOL" \
      '{vmid: ($vmid|tonumber), node: $node, pool: $pool, upid: $upid,
        next: "pve.sh wait \($node) <upid>; then pve.sh ip \($node) \($vmid)"}' ;;
  start|stop|shutdown)
    [[ $# -eq 3 ]] || die "usage: $cmd <node> <lxc|qemu> <vmid>"
    check_type "$2"; check_id "$3"
    in_pool "$3" || die "vmid $3 is not in pool ${POOL}; refusing to $cmd it"
    api POST "/nodes/$1/$2/$3/status/${cmd}" ;;
  snapshot)
    [[ $# -eq 4 ]] || die "usage: snapshot <node> <lxc|qemu> <vmid> <snapname>"
    check_type "$2"; check_id "$3"
    [[ "$4" =~ ^[A-Za-z][A-Za-z0-9_-]{1,39}$ ]] || die "snapname must start with a letter, [A-Za-z0-9_-], 2-40 chars"
    in_pool "$3" || die "vmid $3 is not in pool ${POOL}; refusing to snapshot"
    api POST "/nodes/$1/$2/$3/snapshot" --data-urlencode "snapname=$4" \
      --data-urlencode "description=Hermes pre-change snapshot $(date -u +%FT%TZ)" ;;
  destroy)
    [[ $# -eq 3 ]] || die "usage: destroy <node> <lxc|qemu> <vmid>"
    check_type "$2"; check_id "$3"
    [[ "${CONFIRM:-}" == "yes" ]] || die "refusing to destroy without CONFIRM=yes (and explicit user approval in chat)"
    in_pool "$3" || die "vmid $3 is not a member of pool ${POOL}; refusing to destroy"
    if [[ $(api GET "/nodes/$1/$2/$3/status/current" | jq -r '.status') == "running" ]]; then
      upid=$(api POST "/nodes/$1/$2/$3/status/stop" | jq -r '.')
      wait_task "$1" "$upid" 120 >/dev/null
    fi
    api DELETE "/nodes/$1/$2/$3" --get --data-urlencode "purge=1" --data-urlencode "destroy-unreferenced-disks=1" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
