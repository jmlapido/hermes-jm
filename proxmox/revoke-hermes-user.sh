#!/usr/bin/env bash
# revoke-hermes-user.sh — remove Hermes Agent's Proxmox identity.
#
# Removes token hermes@pve!agent, user hermes@pve (and with it all of their
# ACL entries) and role HermesAgent. The pool and the guests in it are kept.
#
# Usage: ./revoke-hermes-user.sh [-y]
set -euo pipefail

ROLE="HermesAgent"
USER_ID="hermes@pve"
TOKEN_NAME="agent"
POOL="${POOL:-agent-pool}"

[[ $EUID -eq 0 ]] || { echo "Must run as root on the PVE host." >&2; exit 1; }
command -v pveum >/dev/null || { echo "pveum not found." >&2; exit 1; }

exists() { pvesh get "$1" >/dev/null 2>&1; }

if [[ "${1:-}" != "-y" ]]; then
  echo "This will delete: token ${USER_ID}!${TOKEN_NAME}, user ${USER_ID}, role ${ROLE}."
  echo "Pool '${POOL}' and its guests are NOT touched."
  read -r -p "Type 'revoke' to continue: " answer
  [[ "$answer" == "revoke" ]] || { echo "Aborted."; exit 1; }
fi

if exists "/access/users/${USER_ID}/token/${TOKEN_NAME}"; then
  pveum user token remove "$USER_ID" "$TOKEN_NAME"
  echo "removed token ${USER_ID}!${TOKEN_NAME}"
fi

if exists "/access/users/${USER_ID}"; then
  pveum user delete "$USER_ID"      # also drops the user's ACL entries
  echo "removed user ${USER_ID}"
fi

if exists "/access/roles/${ROLE}"; then
  pveum role delete "$ROLE"
  echo "removed role ${ROLE}"
fi

echo "Done. Also delete the SSM parameter /hermes/env/PROXMOX_TOKEN_SECRET."
