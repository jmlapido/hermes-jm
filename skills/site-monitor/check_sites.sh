#!/usr/bin/env bash
# check_sites.sh - website/HTTPS monitor for the Hermes `site-monitor` skill.
#
# For each URL: DNS resolution, HTTP status + total time, TLS certificate days to expiry.
# Prints one JSON object per site (JSON lines). State is kept in
# ${HERMES_HOME:-~/.hermes}/state/sites.json so that, with --alerts-only, output is
# produced ONLY when a site changes state (up<->down) or its certificate expires in
# < SSL_WARN_DAYS days (SSL warnings repeat at most once per day per site).
# Empty stdout == nothing to report (Hermes no-agent cron treats that as a silent tick).
#
# Usage: check_sites.sh [--alerts-only] [--text] [sites_file]
#   sites_file default: ${SITES_FILE:-${HERMES_HOME:-~/.hermes}/sites.txt}
#   line format: <url> [expected_status_regex]   (# comments and blank lines ignored)
# Env: SSL_WARN_DAYS (14), FAIL_THRESHOLD (2 consecutive failures before "down"),
#      HTTP_TIMEOUT (15 s), STATE_FILE.

set -uo pipefail

HH="${HERMES_HOME:-$HOME/.hermes}"
SSL_WARN_DAYS="${SSL_WARN_DAYS:-14}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-15}"
STATE_FILE="${STATE_FILE:-$HH/state/sites.json}"
ALERTS_ONLY=0
TEXT=0
SITES="${SITES_FILE:-$HH/sites.txt}"

for a in "$@"; do
  case "$a" in
    --alerts-only) ALERTS_ONLY=1 ;;
    --text) TEXT=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) SITES="$a" ;;
  esac
done

for c in curl jq openssl; do command -v "$c" >/dev/null || { echo "check_sites.sh: missing $c" >&2; exit 1; }; done
[[ -r "$SITES" ]] || { echo "check_sites.sh: sites file not found: $SITES" >&2; exit 1; }

mkdir -p "$(dirname "$STATE_FILE")"
[[ -s "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1 || echo '{}' > "$STATE_FILE"
STATE=$(cat "$STATE_FILE")
NOW=$(date -u +%FT%TZ)
TODAY=$(date -u +%F)

resolve() {
  local host="$1"
  if command -v getent >/dev/null; then
    getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | head -5 | paste -sd, -
  elif command -v dig >/dev/null; then
    dig +short "$host" A "$host" AAAA 2>/dev/null | grep -E '^[0-9a-f.:]+$' | head -5 | paste -sd, -
  else
    echo "n/a"   # no resolver tool available; let curl decide
  fi
}

ssl_days() {
  local host="$1" port="$2" end end_s
  end=$(echo | timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  [[ -n "$end" ]] || { echo ""; return; }
  end_s=$(date -d "$end" +%s 2>/dev/null) || { echo ""; return; }
  echo $(( (end_s - $(date +%s)) / 86400 ))
}

emit() {  # $1 = json object
  if (( TEXT )); then
    jq -r '
      (if .alert_reason == "recovered" then "RECOVERED" elif .alert_reason == "down" then "DOWN"
       elif .alert_reason == "ssl_expiring" then "SSL" else (.status|ascii_upcase) end) as $tag
      | "\($tag) \(.url) - http \(.http_code // "-") in \(.time_s // "-")s"
        + (if .ssl_days != null then ", cert \(.ssl_days)d" else "" end)
        + (if .error then ", \(.error)" else "" end)' <<<"$1"
  else
    echo "$1"
  fi
}

while read -r -u 3 url expect _rest; do
  [[ -z "${url:-}" || "$url" == \#* ]] && continue
  expect="${expect:-^[23][0-9][0-9]$}"
  proto="${url%%://*}"
  hostport="${url#*://}"; hostport="${hostport%%/*}"; hostport="${hostport##*@}"
  host="${hostport%%:*}"
  port="443"; [[ "$hostport" == *:* ]] && port="${hostport##*:}"
  [[ "$proto" == "http" && "$hostport" != *:* ]] && port="80"

  dns=$(resolve "$host")
  code=""; ttotal=""; err=""
  if [[ -z "$dns" ]]; then
    err="dns_resolution_failed"
  else
    out=$(curl -sS -o /dev/null -L --max-redirs 5 --max-time "$HTTP_TIMEOUT" \
          -A "hermes-site-monitor/1.0" -w '%{http_code} %{time_total}' "$url" 2>&1)
    rc=$?
    if (( rc == 0 )); then
      code="${out%% *}"; ttotal="${out##* }"
    else
      err="curl_exit_${rc}: $(tail -n1 <<<"$out" | tr -d '"' | cut -c1-120)"
      code="${out: -9:3}"; [[ "$code" =~ ^[0-9]{3}$ ]] || code=""
    fi
  fi

  sdays=""
  [[ "$proto" == "https" && -n "$dns" ]] && sdays=$(ssl_days "$host" "$port")

  ok=0
  [[ -z "$err" && "$code" =~ $expect ]] && ok=1
  [[ -z "$err" && $ok -eq 0 ]] && err="unexpected_status"

  prev=$(jq -c --arg u "$url" '.[$u] // {status:"unknown", fails:0, ssl_alerted:""}' <<<"$STATE")
  prev_status=$(jq -r '.status' <<<"$prev")
  fails=$(jq -r '.fails // 0' <<<"$prev")
  ssl_alerted=$(jq -r '.ssl_alerted // ""' <<<"$prev")

  if (( ok )); then fails=0; status="up"
  else
    fails=$((fails + 1))
    if (( fails >= FAIL_THRESHOLD )); then status="down"
    else status="${prev_status/unknown/up}"   # tolerate a single blip
    fi
  fi

  reason=""
  if [[ "$prev_status" != "unknown" && "$status" != "$prev_status" ]]; then
    [[ "$status" == "down" ]] && reason="down" || reason="recovered"
  elif [[ "$prev_status" == "unknown" && "$status" == "down" ]]; then
    reason="down"
  fi
  if [[ -z "$reason" && -n "$sdays" && "$sdays" -lt "$SSL_WARN_DAYS" && "$ssl_alerted" != "$TODAY" ]]; then
    reason="ssl_expiring"
  fi
  [[ -n "$sdays" && "$sdays" -lt "$SSL_WARN_DAYS" && -n "$reason" ]] && ssl_alerted="$TODAY"

  rec=$(jq -cn --arg url "$url" --arg ts "$NOW" --arg status "$status" --arg code "$code" \
        --arg t "$ttotal" --arg sd "$sdays" --arg dns "$dns" --arg err "$err" \
        --arg reason "$reason" --argjson fails "$fails" '{
          ts: $ts, url: $url, status: $status,
          http_code: (if $code == "" then null else ($code|tonumber) end),
          time_s: (if $t == "" then null else ($t|tonumber) end),
          ssl_days: (if $sd == "" then null else ($sd|tonumber) end),
          dns: $dns, consecutive_failures: $fails,
          error: (if $err == "" then null else $err end),
          alert: ($reason != ""), alert_reason: (if $reason == "" then null else $reason end)}')

  STATE=$(jq --arg u "$url" --arg s "$status" --argjson f "$fails" --arg sa "$ssl_alerted" \
          --arg ts "$NOW" --argjson last "$rec" \
          '.[$u] = {status: $s, fails: $f, ssl_alerted: $sa, checked: $ts, last: $last}' <<<"$STATE")

  if (( ALERTS_ONLY )); then
    [[ -n "$reason" ]] && emit "$rec"
  else
    emit "$rec"
  fi
done 3< "$SITES"

tmp="${STATE_FILE}.tmp.$$"
echo "$STATE" > "$tmp" && mv "$tmp" "$STATE_FILE"
exit 0
