#!/usr/bin/env bash
# Publish the Hermes dashboards on the tailnet from hermes-aws (EC2). Run as root:
#   sudo /opt/hermes-jm/dashboards/tailscale-serve.sh          # apply (idempotent)
#   sudo /opt/hermes-jm/dashboards/tailscale-serve.sh status   # show current config
#   sudo /opt/hermes-jm/dashboards/tailscale-serve.sh off      # remove all three handlers
#
#   https://hermes-aws.<tailnet>.ts.net/       -> http://127.0.0.1:3000  Open WebUI (chat)
#   https://hermes-aws.<tailnet>.ts.net:8443/  -> http://127.0.0.1:9119  Hermes web dashboard
#   https://hermes-aws.<tailnet>.ts.net:9443/health -> http://127.0.0.1:8642/health
#        Hermes API liveness only, for the Homepage NOC tile (tag:homepage). Only the /health
#        path is mounted on 9443; the API itself (/v1/...) stays on loopback.
#
# Tailnet only. This script never enables Funnel (public internet) and turns it off on these
# ports if it finds it on. Who on the tailnet may connect is decided by the Tailscale ACL
# (tailscale/acl.hujson: autogroup:admin reaches everything; tag:homepage only 443/8443/9443).
#
# Homepage (the NOC start page) does NOT run here: it lives in its own Proxmox LXC with its own
# `tailscale serve` (see dashboards/homepage/README.md).
#
# Requirements: MagicDNS and HTTPS certificates enabled for the tailnet
# (admin console > DNS > HTTPS Certificates). Serve config persists across reboots.
set -euo pipefail

OPENWEBUI_PORT=3000
DASHBOARD_PORT=9119
API_PORT=8642
HTTPS_CHAT=443
HTTPS_ADMIN=8443
HTTPS_HEALTH=9443

die() { echo "tailscale-serve: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
command -v tailscale >/dev/null || die "tailscale not installed"
command -v jq >/dev/null || die "jq not installed"

status_json() { tailscale serve status --json 2>/dev/null || echo '{}'; }

fqdn="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
[ -n "$fqdn" ] || die "tailscale is not up (no MagicDNS name); run 'tailscale up' first"

case "${1:-apply}" in
  status)
    tailscale serve status
    exit 0
    ;;
  off)
    tailscale serve --https="$HTTPS_CHAT" off 2>/dev/null || true
    tailscale serve --https="$HTTPS_ADMIN" off 2>/dev/null || true
    tailscale serve --https="$HTTPS_HEALTH" off 2>/dev/null || true
    tailscale serve status || true
    exit 0
    ;;
  apply) ;;
  *) die "usage: $0 [apply|status|off]" ;;
esac

# Safety: Funnel must never be on for this node. Turn it off per port if present.
for p in "$HTTPS_CHAT" "$HTTPS_ADMIN" "$HTTPS_HEALTH"; do
  if status_json | jq -e --arg hp "$fqdn:$p" '(.AllowFunnel // {})[$hp] == true' >/dev/null; then
    echo "tailscale-serve: Funnel was ON for $fqdn:$p - turning it off"
    tailscale funnel --https="$p" off
  fi
done

warn_if_down() {
  local name="$1" port="$2"
  if ! curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$port/"; then
    echo "WARN: $name is not answering on 127.0.0.1:$port yet (serve is configured anyway)"
  fi
}
warn_if_down "Open WebUI" "$OPENWEBUI_PORT"
warn_if_down "Hermes dashboard" "$DASHBOARD_PORT"
if ! curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$API_PORT/health"; then
  echo "WARN: Hermes API server /health not answering on 127.0.0.1:$API_PORT (API_SERVER_ENABLED=true?)"
fi

# Re-running replaces the same handler, so this is idempotent. --yes skips prompts.
tailscale serve --bg --yes --https="$HTTPS_CHAT"  "http://127.0.0.1:$OPENWEBUI_PORT"
tailscale serve --bg --yes --https="$HTTPS_ADMIN" "http://127.0.0.1:$DASHBOARD_PORT"
# Health only: mount /health and nothing else on this port (other paths return 404).
tailscale serve --bg --yes --https="$HTTPS_HEALTH" --set-path=/health "http://127.0.0.1:$API_PORT/health"

# Final check: still no Funnel anywhere on this node.
if status_json | jq -e '((.AllowFunnel // {}) | to_entries | map(select(.value == true)) | length) > 0' >/dev/null; then
  die "Funnel is enabled on this node - run 'tailscale funnel reset' and investigate"
fi

echo
tailscale serve status
cat <<EOF

Open WebUI (chat):   https://$fqdn/
Hermes dashboard:    https://$fqdn:$HTTPS_ADMIN/
Hermes API health:   https://$fqdn:$HTTPS_HEALTH/health   (Homepage tile)
  -> HERMES_DASHBOARD_PUBLIC_URL must be exactly https://$fqdn:$HTTPS_ADMIN
  -> Open WebUI .env: WEBUI_URL=https://$fqdn
EOF
