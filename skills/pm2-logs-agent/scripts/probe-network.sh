#!/usr/bin/env bash
# pm2-logs-agent — probe network identity for optional log tagging
#
# Determines the public IPv4 and, when present, the Tailscale IPv4. Both are
# OPTIONAL: an absent value simply means the corresponding VECTOR_TAG_* line is
# omitted from the env file, and the field is then absent from every event.
#
# This script NEVER fails the setup. A host with no outbound internet is normal
# in many environments, and no route to an IP echo service is not an error.
#
# Usage:
#   probe-network.sh [--json] [--timeout SECONDS]
#
# Exit: 0 always (including when nothing could be probed).

set -uo pipefail

TIMEOUT=5
JSON_OUT="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --json)    JSON_OUT="yes"; shift ;;
    --timeout) TIMEOUT="${2:-5}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'probe-network: unknown option: %s\n' "$1" >&2; exit 0 ;;
  esac
done

jstr() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$s"
}

is_ipv4() {
  printf '%s' "$1" | grep -qE '^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' || return 1
  local o
  for o in $(printf '%s' "$1" | tr '.' ' '); do
    [ "$o" -gt 255 ] 2>/dev/null && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# public IPv4
# ---------------------------------------------------------------------------
# -4 forces IPv4 so a host with both stacks reports v4. --max-time bounds each
# probe so a blackholed route cannot stall the audit.

PUBLIC_IP=""
PUBLIC_IP_SOURCE=""
if command -v curl >/dev/null 2>&1; then
  for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://checkip.amazonaws.com" "https://icanhazip.com"; do
    cand="$(curl -4 -s --max-time "$TIMEOUT" "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$cand" && [ "$cand" != "0.0.0.0" ]; then
      PUBLIC_IP="$cand"; PUBLIC_IP_SOURCE="$url"; break
    fi
  done
fi

# ---------------------------------------------------------------------------
# Tailscale IPv4
# ---------------------------------------------------------------------------

TS_INSTALLED=false
TS_ACTIVE=false
TS_IP=""
TS_METHOD=""

if command -v tailscale >/dev/null 2>&1; then
  TS_INSTALLED=true
  # `tailscale status` exits non-zero when the daemon is not logged in, which
  # is different from tailscale being absent.
  if tailscale status >/dev/null 2>&1; then
    TS_ACTIVE=true
    # Preferred: the CLI knows the real address.
    cand="$(tailscale ip -4 2>/dev/null | head -1 | tr -d '[:space:]')"
    if is_ipv4 "$cand"; then TS_IP="$cand"; TS_METHOD="tailscale-cli"; fi
    # Fallback: read the interface directly (works when the CLI is present
    # but restricted, or on a host with the daemon but no CLI on PATH).
    if [ -z "$TS_IP" ] && command -v ip >/dev/null 2>&1; then
      cand="$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
      if is_ipv4 "$cand"; then TS_IP="$cand"; TS_METHOD="interface"; fi
    fi
    # Tailscale v4 addresses live in 100.64.0.0/10. Anything else means we
    # picked up an unrelated interface address, so discard it.
    if [ -n "$TS_IP" ]; then
      case "$TS_IP" in
        100.*) : ;;
        *) TS_IP=""; TS_ACTIVE=false; TS_METHOD="" ;;
      esac
    fi
  fi
fi

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------

if [ "$JSON_OUT" = "yes" ]; then
  printf '{"public_ip":%s,"public_ip_source":%s,"tailscale_installed":%s,"tailscale_active":%s,"tailscale_ip":%s,"tailscale_ip_method":%s}\n' \
    "$(jstr "$PUBLIC_IP")" "$(jstr "$PUBLIC_IP_SOURCE")" \
    "$TS_INSTALLED" "$TS_ACTIVE" "$(jstr "$TS_IP")" "$(jstr "$TS_METHOD")"
else
  if [ -n "$PUBLIC_IP" ]; then
    printf 'public ipv4    : %s  (via %s)\n' "$PUBLIC_IP" "$PUBLIC_IP_SOURCE"
    printf '                add  VECTOR_TAG_PUBLIC_IP=%s\n' "$PUBLIC_IP"
  else
    printf 'public ipv4    : not available (no outbound route, or curl missing)\n'
    printf '                omit the VECTOR_TAG_PUBLIC_IP line; the field is simply absent\n'
  fi
  if [ "$TS_ACTIVE" = true ] && [ -n "$TS_IP" ]; then
    printf 'tailscale ipv4 : %s  (via %s)\n' "$TS_IP" "$TS_METHOD"
    printf '                add  VECTOR_TAG_TAILSCALE_IP=%s\n' "$TS_IP"
  elif [ "$TS_INSTALLED" = true ]; then
    printf 'tailscale ipv4 : tailscale is installed but not connected; omit the tag\n'
  else
    printf 'tailscale ipv4 : tailscale not installed; omit the tag\n'
  fi
  printf '\nPrivacy note: a public IP may count as personal data under GDPR-style\n'
  printf 'regimes. Including it is your decision, not a default.\n'
fi

exit 0