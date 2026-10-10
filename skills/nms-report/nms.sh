#!/usr/bin/env bash
# nms.sh - LibreNMS API helper for the Hermes `nms-report` skill.
#
# Required env:
#   LIBRENMS_URL    e.g. http://librenms.tailnet  (the script appends /api/v0)
#   LIBRENMS_TOKEN  API token (Settings -> API -> Create API access token)
# Optional env:
#   LIBRENMS_CA_FILE        CA bundle for HTTPS; LIBRENMS_INSECURE=1 to skip TLS verify
#   NMS_ERR_THRESHOLD       min in+out error delta per poll to report a port (default 1)
#
# Output: JSON on stdout.

set -euo pipefail

die() { echo "nms.sh: $*" >&2; exit 1; }
command -v curl >/dev/null || die "missing curl"
command -v jq   >/dev/null || die "missing jq"

: "${LIBRENMS_URL:?LIBRENMS_URL not set}"
: "${LIBRENMS_TOKEN:?LIBRENMS_TOKEN not set}"
BASE="${LIBRENMS_URL%/}"
BASE="${BASE%/api/v0}/api/v0"
THRESH="${NMS_ERR_THRESHOLD:-1}"

TLS=()
if [[ -n "${LIBRENMS_CA_FILE:-}" ]]; then TLS=(--cacert "$LIBRENMS_CA_FILE")
elif [[ "${LIBRENMS_INSECURE:-0}" == "1" ]]; then
  echo "nms.sh: WARNING: TLS verification disabled" >&2; TLS=(-k)
fi

api() {
  local path="$1"; shift
  local resp http body
  resp=$(curl -sS "${TLS[@]}" --max-time 60 -H "X-Auth-Token: ${LIBRENMS_TOKEN}" \
    -w $'\n%{http_code}' --get "$@" "${BASE}${path}") || die "request failed: $path"
  http="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  [[ "$http" =~ ^2 ]] || { echo "nms.sh: HTTP $http on $path: $body" >&2; exit 2; }
  echo "$body"
}

devices_all() { api /devices; }

devices_down() {
  api /devices --data-urlencode type=down | jq '[.devices[]? | {
      device_id, hostname, sysName, display, ip, location, hardware, os,
      status_reason, last_polled, uptime}]'
}

alerts_active() {
  local alerts devs rules
  alerts=$(api /alerts --data-urlencode state=1)
  devs=$(devices_all | jq '[.devices[]? | {key: (.device_id|tostring), value: (.display // .sysName // .hostname)}] | from_entries')
  rules=$(api /rules 2>/dev/null | jq '[.rules[]? | {key: (.id|tostring), value: {name, severity}}] | from_entries' 2>/dev/null || echo '{}')
  jq -n --argjson a "$alerts" --argjson d "$devs" --argjson r "$rules" '
    [$a.alerts[]? | {
      id, device_id,
      device: ($d[(.device_id|tostring)] // .hostname // "?"),
      rule_id,
      rule: ($r[(.rule_id|tostring)].name // .name // "?"),
      severity: (.severity // $r[(.rule_id|tostring)].severity // "?"),
      since: .timestamp,
      state
    }] | sort_by(.severity)'
}

ports_errors() {
  local devs
  devs=$(devices_all | jq '[.devices[]? | {key: (.device_id|tostring), value: (.display // .sysName // .hostname)}] | from_entries')
  api /ports --data-urlencode "columns=port_id,device_id,ifName,ifAlias,ifOperStatus,ifInErrors_delta,ifOutErrors_delta,ifInErrors_rate,ifOutErrors_rate" \
    | jq --argjson d "$devs" --argjson t "$THRESH" '
      [.ports[]?
        | .in  = ((.ifInErrors_delta  // 0) | tonumber? // 0)
        | .out = ((.ifOutErrors_delta // 0) | tonumber? // 0)
        | select((.in + .out) >= $t)
        | {port_id, device: ($d[(.device_id|tostring)] // .device_id), ifName, ifAlias,
           ifOperStatus, in_errors_delta: .in, out_errors_delta: .out,
           in_err_rate: .ifInErrors_rate, out_err_rate: .ifOutErrors_rate}]
      | sort_by(-(.in_errors_delta + .out_errors_delta))'
}

summary() {
  local all down alerts ports
  all=$(devices_all)
  down=$(devices_down)
  alerts=$(alerts_active)
  ports=$(ports_errors)
  jq -n --argjson all "$all" --argjson down "$down" --argjson alerts "$alerts" --argjson ports "$ports" '{
    generated_at: (now | todate),
    devices: {
      total: ($all.devices | length),
      up: ([$all.devices[] | select(.status == 1 or .status == "1")] | length),
      down: ($down | length),
      disabled: ([$all.devices[] | select(.disabled == 1 or .disabled == "1")] | length)
    },
    alerts: {
      active: ($alerts | length),
      by_severity: ($alerts | group_by(.severity) | map({key: .[0].severity, value: length}) | from_entries)
    },
    ports_with_errors: ($ports | length),
    down_devices: $down,
    active_alerts: $alerts,
    top_error_ports: ($ports | .[:10])
  }'
}

usage() {
  cat <<'EOF'
Usage: nms.sh <command>
  down       devices currently down
  alerts     active alerts (device + rule names resolved)
  ports      ports with input/output errors in the last poll (>= NMS_ERR_THRESHOLD)
  summary    everything above in one JSON document (for the daily report)
  devices    raw device list
EOF
}

case "${1:-}" in
  down)    devices_down ;;
  alerts)  alerts_active ;;
  ports)   ports_errors ;;
  summary) summary ;;
  devices) devices_all | jq '[.devices[]? | {device_id, hostname, display, status, os, location, uptime}]' ;;
  *) usage; exit 1 ;;
esac
