#!/usr/bin/env bash
# setup-hermes-user.sh — least-privilege Proxmox VE 8 identity for Hermes Agent.
#
# Run as root on the PVE host. Idempotent: safe to re-run; existing objects
# are updated in place. The API token secret is only shown when the token is
# created (or re-created with --rotate-token).
#
# Usage: ./setup-hermes-user.sh [--no-auditor] [--rotate-token]
#   --no-auditor    do not grant PVEAuditor on / (read-only cluster-wide view)
#   --rotate-token  delete and re-create hermes@pve!agent (prints new secret)
set -euo pipefail

# ---- Configuration ---------------------------------------------------------
POOL="${POOL:-agent-pool}"
STORAGES="${STORAGES:-local-lvm local}"   # disks on local-lvm, ISO/templates/snippets on local
BRIDGE="${BRIDGE:-vmbr0}"
SDN_ZONE="${SDN_ZONE:-localnetwork}"      # default zone that exposes classic Linux bridges
ROLE="HermesAgent"
USER_ID="hermes@pve"
TOKEN_NAME="agent"
TOKEN_ID="${USER_ID}!${TOKEN_NAME}"
SSM_PARAM="/hermes/env/PROXMOX_TOKEN_SECRET"

# PVE 8 privilege names. VM.Monitor is intentionally absent (removed in newer
# PVE; it would also grant raw QEMU monitor access).
PRIVS=(
  VM.Allocate VM.Audit VM.Clone
  VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk
  VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options
  VM.Console VM.PowerMgmt VM.Snapshot VM.Snapshot.Rollback VM.Backup
  Datastore.AllocateSpace Datastore.Audit
  Pool.Audit Sys.Audit SDN.Use
)

GRANT_AUDITOR=1
ROTATE_TOKEN=0
for arg in "$@"; do
  case "$arg" in
    --no-auditor)   GRANT_AUDITOR=0 ;;
    --rotate-token) ROTATE_TOKEN=1 ;;
    -h|--help)      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ---- Preconditions ---------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Must run as root on the PVE host." >&2; exit 1; }
command -v pveum >/dev/null || { echo "pveum not found — is this a Proxmox VE host?" >&2; exit 1; }
command -v pvesh >/dev/null || { echo "pvesh not found." >&2; exit 1; }

exists() { pvesh get "$1" >/dev/null 2>&1; }
log()    { printf '[hermes-setup] %s\n' "$*"; }

# Validate privilege names against what this PVE build actually knows.
# The built-in Administrator role holds every privilege of the running version.
valid_privs="$(pvesh get /access/roles/Administrator --output-format json 2>/dev/null || true)"
for p in "${PRIVS[@]}"; do
  if [[ -n "$valid_privs" && "$valid_privs" != *"\"$p\""* ]]; then
    echo "Privilege '$p' is not known to this PVE version — edit PRIVS." >&2
    exit 1
  fi
done

# ---- Pool ------------------------------------------------------------------
if exists "/pools/${POOL}"; then
  log "pool ${POOL} exists"
else
  pveum pool add "$POOL" --comment "VMs/CTs managed by Hermes Agent"
  log "created pool ${POOL}"
fi

# ---- Role ------------------------------------------------------------------
PRIV_STR="${PRIVS[*]}"
if exists "/access/roles/${ROLE}"; then
  pveum role modify "$ROLE" --privs "${PRIV_STR// /,}"   # replaces privilege set
  log "updated role ${ROLE}"
else
  pveum role add "$ROLE" --privs "${PRIV_STR// /,}"
  log "created role ${ROLE}"
fi

# ---- User (pve realm, no password => cannot log into the GUI) -------------
if exists "/access/users/${USER_ID}"; then
  log "user ${USER_ID} exists"
else
  pveum user add "$USER_ID" --comment "Hermes Agent (API token only)"
  log "created user ${USER_ID}"
fi

# ---- Token (privsep=1: token rights = intersection of user ACLs and its own)
TOKEN_SECRET=""
if exists "/access/users/${USER_ID}/token/${TOKEN_NAME}" && [[ $ROTATE_TOKEN -eq 1 ]]; then
  pveum user token remove "$USER_ID" "$TOKEN_NAME"
  log "removed old token ${TOKEN_ID} (rotation)"
fi
if exists "/access/users/${USER_ID}/token/${TOKEN_NAME}"; then
  log "token ${TOKEN_ID} exists (secret not retrievable; use --rotate-token for a new one)"
else
  out="$(pveum user token add "$USER_ID" "$TOKEN_NAME" --privsep 1 \
          --comment "Hermes Agent on AWS EC2" --output-format json)"
  TOKEN_SECRET="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"
  log "created token ${TOKEN_ID}"
fi

# ---- ACLs (applied to both user and token; privsep tokens need their own) --
grant() {  # grant <path> <role>
  pveum acl modify "$1" --users "$USER_ID" --tokens "$TOKEN_ID" --roles "$2" --propagate 1
  log "ACL ${2} on ${1}"
}

grant "/pool/${POOL}" "$ROLE"
for s in $STORAGES; do
  grant "/storage/${s}" PVEDatastoreUser        # Datastore.AllocateSpace + Datastore.Audit
done
grant "/sdn/zones/${SDN_ZONE}/${BRIDGE}" PVESDNUser   # SDN.Use on the bridge only

if [[ $GRANT_AUDITOR -eq 1 ]]; then
  grant "/" PVEAuditor                          # read-only view of nodes/VMs/storage
else
  pveum acl delete / --users "$USER_ID" --tokens "$TOKEN_ID" --roles PVEAuditor >/dev/null 2>&1 || true
  log "PVEAuditor on / not granted (--no-auditor)"
fi

# ---- Summary ---------------------------------------------------------------
cat <<EOF

Done. Effective permissions for the token:
  pveum user token permissions ${USER_ID} ${TOKEN_NAME}

Notes:
  * Hermes can only touch guests that are members of pool '${POOL}'. Add
    templates it should clone from to the pool as well (VM.Clone is checked
    on the source), and pass --pool ${POOL} when creating guests.
  * Hermes env: PROXMOX_TOKEN_ID=${TOKEN_ID}
EOF

if [[ -n "$TOKEN_SECRET" ]]; then
  cat <<EOF

=====================================================================
 WARNING: the token secret is shown ONCE and cannot be retrieved again.
 Store it now in AWS SSM (SecureString), then clear your scrollback:

   aws ssm put-parameter --name ${SSM_PARAM} --type SecureString \\
     --overwrite --value '<secret>'

 PROXMOX_TOKEN_SECRET=${TOKEN_SECRET}
=====================================================================
EOF
fi
