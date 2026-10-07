#!/usr/bin/env bash
# shellcheck disable=SC2015
#
# SC2015 is disabled for this file: `[ cond ] && check PASS || check FAIL` is
# used throughout as a compact if/else. It is safe because check() always
# returns 0, so the FAIL branch cannot run after a successful PASS.
#
# pm2-logs-agent — re-check invariants after an approved change
#
# Read-only. Compares the current state against what the audit requires and
# reports PASS / FAIL / UNKNOWN per invariant. Run after applying any CHANGE or
# SAFE action, and on a schedule, because several failure modes only appear after
# a reboot.
#
# Usage:
#   verify-post-change.sh [--env-file PATH] [--pm2-home PATH] [--json]
#
# Exit: 0 all invariants pass or are unknown, 1 at least one FAILED.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="/etc/vector/pm2-axiom.env"
PM2_HOME_DIR="${PM2_HOME:-$HOME/.pm2}"
JSON_OUT="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --pm2-home) PM2_HOME_DIR="${2:-}"; shift 2 ;;
    --json)     JSON_OUT="yes"; shift ;;
    -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'verify-post-change: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# shellcheck source=/dev/null
[ -f "$REPO_DIR/assets/vector-version.env" ] && . "$REPO_DIR/assets/vector-version.env"

RESULTS=""
FAILED=0

jstr() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$s"
}

# check <name> <PASS|FAIL|UNKNOWN> <detail>
#
# Always returns 0, so the `[ cond ] && check PASS || check FAIL` idiom below
# cannot double-fire (which is what shellcheck SC2015 warns about). That warning
# is suppressed at each site rather than restructuring ~10 call sites.
check() {
  local entry
  entry=$(printf '{"check":%s,"status":%s,"detail":%s}' "$(jstr "$1")" "$(jstr "$2")" "$(jstr "$3")")
  if [ -z "$RESULTS" ]; then RESULTS="$entry"; else RESULTS="$RESULTS,$entry"; fi
  [ "$2" = "FAIL" ] && FAILED=1
  [ "$JSON_OUT" = "yes" ] || printf '  %-8s %-38s %s\n' "[$2]" "$1" "$3"
}

printf '\033[1mVerifying pm2-logs-agent invariants\033[0m\n\n'

# ---------------------------------------------------------------------------
# tag configuration
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  if "$REPO_DIR/scripts/validate-tags.sh" --env-file "$ENV_FILE" --quiet >/dev/null 2>&1; then
    check "tags.valid" PASS "validate-tags.sh passed for $ENV_FILE"
  else
    check "tags.valid" FAIL "validate-tags.sh reported errors; run it without --quiet for detail"
  fi
  grep -qE '^[[:space:]]*VECTOR_TAG_MACHINE=.+' "$ENV_FILE" \
    && check "tags.machine_present" PASS "VECTOR_TAG_MACHINE is set" \
    || check "tags.machine_present" FAIL "VECTOR_TAG_MACHINE missing — events will be unattributable"
  m="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '?')"
  case "$m" in 600|400) check "tags.env_permissions" PASS "mode $m" ;;
    *) check "tags.env_permissions" FAIL "mode $m — the Axiom token is readable by others" ;; esac
else
  check "tags.valid" UNKNOWN "env file $ENV_FILE not present"
fi

# AXIOM_REGION is optional; only flag a malformed value if it IS set
if [ -f "$ENV_FILE" ] && grep -qE '^[[:space:]]*AXIOM_REGION=.+' "$ENV_FILE"; then
  r="$(grep -E '^[[:space:]]*AXIOM_REGION=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
  case "$r" in
    http://*|https://*|*/|*/*) check "axiom.region_format" FAIL "'$r' has a scheme or path; expected a bare domain" ;;
    *) check "axiom.region_format" PASS "'$r'" ;;
  esac
else
  check "axiom.region_format" PASS "unset (Axiom default base domain will be used)"
fi

# ---------------------------------------------------------------------------
# collector
# ---------------------------------------------------------------------------
if command -v vector >/dev/null 2>&1; then
  cur="$(vector --version 2>/dev/null | awk '{print $2}' | tr -d 'v')"
  if [ "$cur" = "${VECTOR_VERSION:-}" ]; then
    check "vector.version" PASS "matches pin $cur"
  elif [ "$(printf '%s\n%s\n' "$cur" "${VECTOR_VERSION:-0}" | sort -V | head -1)" = "$cur" ]; then
    check "vector.version" FAIL "installed $cur is older than the pin ${VECTOR_VERSION:-}; config options may differ"
  else
    check "vector.version" PASS "installed $cur is newer than the pin (fine; do not downgrade)"
  fi

  if systemctl is-active --quiet vector 2>/dev/null; then
    check "vector.running" PASS "systemd unit active"
  else
    check "vector.running" FAIL "vector service is not active"
  fi

  # The boot-survival half of the silent-blackout matrix
  if systemctl is-enabled vector >/dev/null 2>&1; then
    check "vector.enabled_at_boot" PASS "collector survives reboot"
  else
    check "vector.enabled_at_boot" FAIL "collector is not enabled at boot — logs will vanish on reboot even though apps return"
  fi

  for cfg in /etc/vector/pm2-axiom.toml /etc/vector/pm2-axiom.yaml; do
    [ -f "$cfg" ] || continue
    if vector validate --no-environment "$cfg" >/dev/null 2>&1; then
      check "vector.config_valid" PASS "$cfg"
    else
      check "vector.config_valid" FAIL "$cfg failed vector validate: $(vector validate --no-environment "$cfg" 2>&1 | grep -m1 '^x' || echo 'see output')"
    fi
    break
  done
else
  check "vector.running" UNKNOWN "vector not installed"
fi

# ---------------------------------------------------------------------------
# PM2 restart survival
# ---------------------------------------------------------------------------
UNIT="pm2-$(id -un).service"
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
  check "pm2.restart_survival" UNKNOWN "containerised — pm2 save/startup do not apply; use a container CMD"
elif command -v systemctl >/dev/null 2>&1; then
  if systemctl cat "$UNIT" >/dev/null 2>&1; then
    check "pm2.unit_present" PASS "$UNIT exists"
    systemctl is-enabled "$UNIT" >/dev/null 2>&1 \
      && check "pm2.unit_enabled" PASS "enabled at boot" \
      || check "pm2.unit_enabled" FAIL "$UNIT is not enabled — apps will not return after a reboot"

    es="$(systemctl show "$UNIT" --property=ExecStart --value 2>/dev/null)"
    nd="$(printf '%s' "$es" | grep -oE '/[^ ]*/(node|bin/pm2)' | head -1 | sed 's#/\(node\|bin/pm2\)$##')"
    if [ -n "$nd" ]; then
      [ -d "$nd" ] \
        && check "pm2.unit_node_path" PASS "ExecStart node dir exists: $nd" \
        || check "pm2.unit_node_path" FAIL "ExecStart references $nd, which is gone — the unit fails silently at boot. Fix: pm2 unstartup && pm2 startup && pm2 save (RISKY)"
    else
      check "pm2.unit_node_path" UNKNOWN "could not parse ExecStart"
    fi
  else
    check "pm2.unit_present" FAIL "$UNIT does not exist — nothing resurrects apps after a reboot (RISKY: pm2 startup)"
  fi
else
  check "pm2.restart_survival" UNKNOWN "systemctl unavailable"
fi

DUMP="$PM2_HOME_DIR/dump.pm2"
if [ -f "$DUMP" ]; then
  check "pm2.dump_present" PASS "$DUMP (mtime $(date -r "$DUMP" '+%Y-%m-%d %H:%M' 2>/dev/null))"
  if command -v pm2 >/dev/null 2>&1 && pm2 ping >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    live="$(pm2 jlist 2>/dev/null | jq -c '[.[].name]' 2>/dev/null)"
    dump="$(jq -c '[.[].name]' "$DUMP" 2>/dev/null)"
    at_risk="$(jq -n --argjson d "$dump" --argjson l "$live" '[ $d[] | select(. as $x | ($l | index($x)) == null) ]' 2>/dev/null)"
    n="$(printf '%s' "$at_risk" | jq 'length' 2>/dev/null || echo 0)"
    if [ "$n" = "0" ]; then
      check "pm2.save_no_data_loss" PASS "dump matches the live process list; 'pm2 save' would lose nothing"
    else
      check "pm2.save_no_data_loss" FAIL "'pm2 save' WOULD DROP: $(printf '%s' "$at_risk" | jq -r 'join(", ")'). Start them first or accept the loss deliberately (RISKY)"
    fi
  else
    check "pm2.save_no_data_loss" UNKNOWN "pm2 daemon or jq unavailable"
  fi
else
  check "pm2.dump_present" FAIL "no dump.pm2 — nothing will be resurrected after a reboot (RISKY: pm2 save)"
fi

# ---------------------------------------------------------------------------
# log paths
# ---------------------------------------------------------------------------
if [ -d "$PM2_HOME_DIR/logs" ]; then
  n="$(find "$PM2_HOME_DIR/logs" -maxdepth 1 -name '*.log' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ] && check "logs.files_present" PASS "$n log file(s) in $PM2_HOME_DIR/logs" \
                || check "logs.files_present" FAIL "no .log files in $PM2_HOME_DIR/logs"
else
  check "logs.files_present" FAIL "$PM2_HOME_DIR/logs does not exist"
fi
[ -f "$PM2_HOME_DIR/pm2.log" ] \
  && check "logs.daemon_log" PASS "pm2.log present (must be included explicitly — it sits outside logs/)" \
  || check "logs.daemon_log" UNKNOWN "no pm2.log (fine if the daemon has never logged)"

# ---------------------------------------------------------------------------
# network identity drift
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ] && grep -qE '^[[:space:]]*VECTOR_TAG_PUBLIC_IP=.+' "$ENV_FILE"; then
  stored="$(grep -E '^[[:space:]]*VECTOR_TAG_PUBLIC_IP=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
  live_ip="$("$REPO_DIR/scripts/probe-network.sh" --json --timeout 5 2>/dev/null | jq -r '.public_ip' 2>/dev/null)"
  if [ -n "$live_ip" ] && [ "$live_ip" != "$stored" ]; then
    check "network.public_ip_drift" FAIL "env file has $stored but this host now presents $live_ip. Axiom rows will carry a stale IP; update the tag"
  elif [ -n "$live_ip" ]; then
    check "network.public_ip_drift" PASS "stored IP matches current ($stored)"
  else
    check "network.public_ip_drift" UNKNOWN "could not probe the current public IP"
  fi
fi

# ---------------------------------------------------------------------------
# capacity
# ---------------------------------------------------------------------------
if [ -d /var/lib/vector ]; then
  check "capacity.data_dir" PASS "/var/lib/vector exists"
else
  check "capacity.data_dir" UNKNOWN "/var/lib/vector does not exist (created on first run)"
fi

printf '\n'
if [ "$FAILED" -eq 1 ]; then
  printf '\033[31mOne or more invariants FAILED.\033[0m Re-run audit-pm2-logs.sh for the full picture.\n'
else
  printf '\033[32mAll checked invariants pass.\033[0m\n'
fi

if [ "$JSON_OUT" = "yes" ]; then
  printf '{"failed":%s,"checks":[%s]}\n' "$FAILED" "$RESULTS"
fi

[ "$FAILED" -eq 1 ] && exit 1
exit 0