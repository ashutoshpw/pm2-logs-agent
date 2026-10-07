#!/usr/bin/env bash
# pm2-logs-agent — read-only audit of PM2 logging and restart survivability
#
# THIS SCRIPT IS STRICTLY READ-ONLY.
#
# It must never write to disk, restart a service, or run `pm2 save`. The whole
# point of the audit phase is that a human can ask "check my setup" and get a
# trustworthy answer without anything changing underneath them. The remediation
# step is a separate, explicitly-confirmed phase.
#
# Emits JSON on stdout:
#   {
#     "schema": 1,
#     "generated_at": "...",
#     "host": {...},
#     "pm2": {...},
#     "restart": {...},
#     "logs": {...},
#     "collectors": {...},
#     "network": {...},
#     "capacity": {...},
#     "findings": [ {id,severity,title,detail,evidence} ]
#   }
#
# Usage:
#   audit-pm2-logs.sh [--pm2-home PATH] [--user NAME] [--json] [--quiet]
#
# Exit: 0 always (an audit of a broken host is a successful audit).
# Findings are reported in the JSON, not via exit code.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PM2_HOME_DIR="${PM2_HOME:-$HOME/.pm2}"
TARGET_USER="${USER:-$(id -un)}"
QUIET="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --pm2-home) PM2_HOME_DIR="${2:-}"; shift 2 ;;
    --user)     TARGET_USER="${2:-}"; shift 2 ;;
    --quiet)    QUIET="yes"; shift ;;
    --json)     : ;; # JSON is the only format
    -h|--help)  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'audit-pm2-logs: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

FINDINGS_JSON=""
add_finding() {
  # $1 id, $2 severity (critical|high|medium|low|info), $3 title, $4 detail
  # $5 evidence (JSON array literal)
  local entry
  entry=$(printf '{"id":%s,"severity":%s,"title":%s,"detail":%s,"evidence":%s}' \
    "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$3")" "$(json_str "$4")" "${5:-[]}")
  if [ -z "$FINDINGS_JSON" ]; then FINDINGS_JSON="$entry"; else FINDINGS_JSON="$FINDINGS_JSON,$entry"; fi
  [ "$QUIET" = "yes" ] || printf '%-8s %s\n' "[$2]" "$3" >&2
}

json_str() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$s"
}

json_bool() { if [ "${1:-}" = "true" ] || [ "${1:-}" = "1" ]; then printf 'true'; else printf 'false'; fi; }

# Evidence is a JSON array of "key=value" strings.
#
# Each element must be escaped and quoted exactly ONCE. Two traps, both hit
# during development:
#
#  1. Calling json_str on a value and splicing it into a hand-written
#     ["k=%s"] template yields nested quotes: ["ip="1.2.3.4""], invalid JSON.
#     ev_list escapes the whole "k=v" string instead.
#
#  2. Command substitution inside a "$(...)" argument is evaluated BEFORE the
#     surrounding command runs, so "$1"/"$2" inside ev_list saw the caller's
#     positional parameters (empty), not ev_list's own. Hence the inline
#     expansion below rather than relying on $1/$2.
ev_list() {
  local out="" item
  for item in "$@"; do
    [ -n "$out" ] && out="$out,"
    # json_str reads its value from $1, so pass it as an argument. Piping into
    # it instead silently produced empty strings, because a piped call passes
    # no positional parameters and json_str does not read stdin.
    out="$out$(json_str "$item")"
  done
  printf '[%s]' "$out"
}

# ===========================================================================
# platform
# ===========================================================================

CONTAINERIZED="false"
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -qaE '(docker|containerd|kubepods|lxc)' /proc/1/cgroup 2>/dev/null; then
  CONTAINERIZED="true"
fi
add_finding "platform.container" "$(if [ "$CONTAINERIZED" = true ]; then echo medium; else echo info; fi)" \
  "Platform" \
  "$(if [ "$CONTAINERIZED" = true ]; then
      echo "Running inside a container. pm2 save / pm2 startup are NOT the right mechanism here: there is no systemd unit to enable and no PM2_HOME that persists across container restarts. Use a container CMD/ENTRYPOINT with pm2-runtime or pm2 resurrect instead. The audit still reports save state because it is worth knowing, but treat those findings as informational."
    else
      echo "Bare metal or VM with a real init system. pm2 save plus pm2 startup are the correct restart-survival mechanism."
    fi)"

# ===========================================================================
# vector version + pin
# ===========================================================================

# shellcheck source=/dev/null
[ -f "$REPO_DIR/assets/vector-version.env" ] && . "$REPO_DIR/assets/vector-version.env"
PINNED_VERSION="${VECTOR_VERSION:-unknown}"
FLOOR_VERSION="${VECTOR_KNOWN_GOOD_FLOOR:-unknown}"

VECTOR_INSTALLED="false"
VECTOR_VERSION_DETECTED=""
if command -v vector >/dev/null 2>&1; then
  VECTOR_INSTALLED="true"
  VECTOR_VERSION_DETECTED="$(vector --version 2>/dev/null | awk '{print $2}' | tr -d 'v')"
fi

VECTOR_DRIFT="unknown"
if [ "$VECTOR_INSTALLED" = "true" ] && [ "$PINNED_VERSION" != "unknown" ]; then
  # Deliberate asymmetry: OLDER than the pin is a real risk, NEWER is fine.
  # Telling someone to downgrade a working collector is the wrong instinct.
  if [ "$(printf '%s\n%s\n' "$VECTOR_VERSION_DETECTED" "$PINNED_VERSION" | sort -V | head -1)" = "$VECTOR_VERSION_DETECTED" ] \
     && [ "$VECTOR_VERSION_DETECTED" != "$PINNED_VERSION" ]; then
    VECTOR_DRIFT="older"
    add_finding "vector.version.older" "medium" "Installed Vector is older than the pinned version" \
      "Installed $VECTOR_VERSION_DETECTED, pinned $PINNED_VERSION. Config options may be unsupported or may have changed meaning. Review the config against the installed version, or upgrade." \
      "[\"installed=$VECTOR_VERSION_DETECTED\",\"pinned=$PINNED_VERSION\",\"known_good_floor=$FLOOR_VERSION\"]"
  elif [ "$VECTOR_VERSION_DETECTED" = "$PINNED_VERSION" ]; then
    VECTOR_DRIFT="match"
  else
    VECTOR_DRIFT="newer"
    add_finding "vector.version.newer" "info" "Installed Vector is newer than the pinned version" \
      "Installed $VECTOR_VERSION_DETECTED, pinned $PINNED_VERSION. This is normally fine and is reported for awareness only. Do NOT downgrade a working collector to match the pin." \
      "[\"installed=$VECTOR_VERSION_DETECTED\",\"pinned=$PINNED_VERSION\"]"
  fi
fi

# ===========================================================================
# PM2 runtime
# ===========================================================================

PM2_INSTALLED="false"
PM2_DAEMON_ALIVE="false"
PM2_VERSION=""
PM2_JLIST="[]"
APPS_JSON=""
LIVE_APP_COUNT=0

if command -v pm2 >/dev/null 2>&1; then
  PM2_INSTALLED="true"
  PM2_VERSION="$(pm2 --version 2>/dev/null | tr -d '\n')"
  if pm2 ping >/dev/null 2>&1; then PM2_DAEMON_ALIVE="true"; fi
  if [ "$PM2_DAEMON_ALIVE" = "true" ]; then
    PM2_JLIST="$(pm2 jlist 2>/dev/null || echo '[]')"
    # unstable_restarts and restart_time come from pm2_env. A high unstable
    # count means PM2 has been killing and restarting the process repeatedly,
    # which looks like a logging gap but is actually an application crash loop.
    APPS_JSON="$(printf '%s' "$PM2_JLIST" | jq -c '[.[] | {name, pm_id, status:(.pm2_env.status // "unknown"), out_file:(.pm2_env.pm_out_log_path // ""), error_file:(.pm2_env.pm_err_log_path // ""), log_type:(.pm2_env.log_type // "raw"), merge_logs:(.pm2_env.merge_logs // false), instances:(.pm2_env.instances // 1), unstable_restarts:(.pm2_env.unstable_restarts // 0), restart_time:(.pm2_env.restart_time // null), pm_uptime:(.pm2_env.pm_uptime // null), exec_mode:(.pm2_env.exec_mode // "fork")}]' 2>/dev/null || echo '[]')"
    LIVE_APP_COUNT="$(printf '%s' "$APPS_JSON" | jq 'length' 2>/dev/null || echo 0)"
  fi
fi

[ "$PM2_INSTALLED" = "true" ] || add_finding "pm2.missing" "critical" "PM2 is not installed" \
  "No pm2 binary on PATH for user $TARGET_USER. If this host is meant to run PM2 apps, that is itself the problem."

if [ "$PM2_INSTALLED" = "true" ] && [ "$PM2_DAEMON_ALIVE" = "false" ]; then
  add_finding "pm2.daemon.down" "critical" "PM2 daemon is not responding" \
    "pm2 is installed but \`pm2 ping\` failed. No apps are running under this user right now. Start them with: pm2 resurrect (if you have previously run pm2 save), or pm2 start <ecosystem>."
fi

# Errored / stopped apps: informational context, not a logging finding.
ERRORED_APPS=""
if [ "$LIVE_APP_COUNT" -gt 0 ] 2>/dev/null; then
  ERRORED_APPS="$(printf '%s' "$APPS_JSON" | jq -c '[.[] | select(.status == "errored") | .name]' 2>/dev/null || echo '[]')"
  ERRORED_COUNT="$(printf '%s' "$ERRORED_APPS" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$ERRORED_COUNT" -gt 0 ]; then
    add_finding "pm2.apps.errored" "high" "Apps in errored state" \
      "$ERRORED_COUNT app(s) are in errored status. These are not producing healthy logs, which can look like a logging pipeline failure when it is actually an application failure. Check with: pm2 logs <name>" \
      "$(printf '%s' "$ERRORED_APPS")"
  fi

  # Restart loops. The log files keep growing across restarts so the pipeline
  # looks healthy, but the app never stays up — worth surfacing so a "no
  # recent logs" question is answered by the right cause.
  LOOPING="$(printf '%s' "$APPS_JSON" | jq -c '[.[] | select((.unstable_restarts // 0) >= 5) | {name, unstable_restarts}]' 2>/dev/null || echo '[]')"
  LOOP_COUNT="$(printf '%s' "$LOOPING" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$LOOP_COUNT" -gt 0 ]; then
    add_finding "pm2.apps.restart_loop" "high" "Apps are restart-looping" \
      "$LOOP_COUNT app(s) have 5 or more unstable restarts. Their log files are being written and rotated normally, so the logging pipeline looks healthy, but the app is not staying up. PM2's unstable-restart threshold is 16 within 15 minutes. Check with: pm2 logs <name>" \
      "$(printf '%s' "$LOOPING")"
  fi
fi

# ===========================================================================
# restart survivability: pm2-<user>.service + dump.pm2
# ===========================================================================

PM2_UNIT_NAME="pm2-$TARGET_USER.service"
PM2_UNIT_PRESENT="false"
PM2_UNIT_ENABLED="unknown"
PM2_UNIT_EXECSTART=""
PM2_UNIT_NODE_VALID="unknown"

if command -v systemctl >/dev/null 2>&1 && [ "$CONTAINERIZED" = "false" ]; then
  if systemctl cat "$PM2_UNIT_NAME" >/dev/null 2>&1; then
    PM2_UNIT_PRESENT="true"
    PM2_UNIT_EXECSTART="$(systemctl show "$PM2_UNIT_NAME" --property=ExecStart --value 2>/dev/null | head -c 500)"
    if systemctl is-enabled "$PM2_UNIT_NAME" >/dev/null 2>&1; then PM2_UNIT_ENABLED="true"; else PM2_UNIT_ENABLED="false"; fi

    # The unit hardcodes a versioned node path. After a Node upgrade that path
    # is gone and the unit fails AT BOOT with no obvious cause.
    NODE_BIN="$(printf '%s' "$PM2_UNIT_EXECSTART" | grep -oE '/[^ ]*/(node|bin/pm2)' | head -1)"
    if [ -n "$NODE_BIN" ]; then
      # Strip a trailing /node or /bin/pm2 to get the directory to test.
      NODE_DIR="$(printf '%s' "$NODE_BIN" | sed 's#/\(node\|bin/pm2\)$##')"
      if [ -d "$NODE_DIR" ]; then PM2_UNIT_NODE_VALID="true"; else PM2_UNIT_NODE_VALID="false"; fi
    fi

    # --hp must match the current home dir.
    HP_MISMATCH="false"
    HP_IN_UNIT="$(printf '%s' "$PM2_UNIT_EXECSTART" | grep -oE '\-\-hp[= ][^ ]*' | head -1 | sed 's/--hp[= ]*//')"
    if [ -n "$HP_IN_UNIT" ] && [ "$HP_IN_UNIT" != "$HOME" ]; then HP_MISMATCH="true"; fi

    if [ "$PM2_UNIT_NODE_VALID" = "false" ]; then
      add_finding "restart.unit.dead_node" "critical" "PM2 systemd unit points at a Node path that no longer exists" \
        "The unit's ExecStart references $NODE_DIR, which is not present. The unit will FAIL silently at boot and no apps will come back. PM2 docs require 'pm2 unstartup' then 'pm2 startup' after a Node version upgrade — the path cannot be hand-edited reliably. This fix is RISKY tier." \
        "$(ev_list "unit=$PM2_UNIT_NAME" "exec_start=$PM2_UNIT_EXECSTART" "missing_dir=$NODE_DIR")"
    fi
    [ "$HP_MISMATCH" = "true" ] && add_finding "restart.unit.hp_mismatch" "high" "PM2 unit --hp does not match the current home directory" \
      "Unit was generated for a different home path. Regenerate with pm2 unstartup && pm2 startup." \
      "$(ev_list "unit_hp=$HP_IN_UNIT" "current_home=$HOME")"
  else
    PM2_UNIT_PRESENT="false"
    PM2_UNIT_ENABLED="false"
    if [ "$PM2_DAEMON_ALIVE" = "true" ] && [ "$LIVE_APP_COUNT" -gt 0 ]; then
      add_finding "restart.unit.missing" "critical" "PM2 apps are running but there is no systemd unit to resurrect them" \
        "$LIVE_APP_COUNT app(s) are live, yet $PM2_UNIT_NAME does not exist. A reboot takes every one of them down permanently. Run 'pm2 startup' then 'pm2 save'. RISKY tier." \
        "$(ev_list "live_apps=$LIVE_APP_COUNT" "unit=$PM2_UNIT_NAME")"
    fi
  fi
fi

DUMP_PATH="$PM2_HOME_DIR/dump.pm2"
DUMP_PRESENT="false"
DUMP_MTIME=""
DUMP_APP_COUNT=0
DUMP_APPS="[]"
if [ -f "$DUMP_PATH" ]; then
  DUMP_PRESENT="true"
  DUMP_MTIME="$(date -r "$DUMP_PATH" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || stat -c %y "$DUMP_PATH" 2>/dev/null)"
  if command -v jq >/dev/null 2>&1; then
    DUMP_APPS="$(jq -c '[.[] | .name]' "$DUMP_PATH" 2>/dev/null || echo '[]')"
    DUMP_APP_COUNT="$(printf '%s' "$DUMP_APPS" | jq 'length' 2>/dev/null || echo 0)"
  fi
fi

# ---- the critical drift analysis -----------------------------------------
#
# `pm2 save` OVERWRITES dump.pm2 with the CURRENT process list. It is not a
# merge. So saving when the dump is a superset of what is running SILENTLY
# DROPS those apps from the next boot. This is the single most dangerous thing
# an operator can do reflexively, so it is reported at critical severity with
# the names that would be lost.
#
SAVE_HAZARD="none"
APPS_AT_RISK="[]"

if [ "$PM2_DAEMON_ALIVE" = "true" ] && [ "$DUMP_PRESENT" = "true" ] && command -v jq >/dev/null 2>&1; then
  LIVE_NAMES="$(printf '%s' "$APPS_JSON" | jq -c '[.[].name]' 2>/dev/null || echo '[]')"
  AT_RISK="$(jq -n --argjson dump "$DUMP_APPS" --argjson live "$LIVE_NAMES" \
    '[ $dump[] | select(. as $d | ($live | index($d)) == null) ]' 2>/dev/null || echo '[]')"
  RISK_COUNT="$(printf '%s' "$AT_RISK" | jq 'length' 2>/dev/null || echo 0)"
  UNSAVED="$(jq -n --argjson dump "$DUMP_APPS" --argjson live "$LIVE_NAMES" \
    '[ $live[] | select(. as $l | ($dump | index($l)) == null) ]' 2>/dev/null || echo '[]')"
  UNSAVED_COUNT="$(printf '%s' "$UNSAVED" | jq 'length' 2>/dev/null || echo 0)"

  if [ "$RISK_COUNT" -gt 0 ]; then
    SAVE_HAZARD="would_drop_apps"
    APPS_AT_RISK="$AT_RISK"
    add_finding "restart.save.would_drop" "critical" "DO NOT run 'pm2 save' yet — it would drop apps from the reboot snapshot" \
    "dump.pm2 references $RISK_COUNT app(s) that are not currently running: $(printf '%s' "$AT_RISK" | jq -r 'join(", ")'). 'pm2 save' overwrites dump.pm2 with the CURRENT list rather than merging, so running it now would remove those apps permanently from the next reboot. Decide deliberately whether those apps are meant to run, start them, and only then save." \
    "$(ev_list "dump_apps=$DUMP_APP_COUNT" "live_apps=$LIVE_APP_COUNT" "would_be_dropped=$(printf '%s' "$AT_RISK" | jq -r 'join(", ")')" "would_be_added=$(printf '%s' "$UNSAVED" | jq -r 'join(", ")')")"
  elif [ "$UNSAVED_COUNT" -gt 0 ]; then
    SAVE_HAZARD="unsaved_apps"
    add_finding "restart.save.unsaved" "critical" "Running apps are not in the reboot snapshot" \
    "$UNSAVED_COUNT app(s) are running but absent from dump.pm2: $(printf '%s' "$UNSAVED" | jq -r 'join(", ")'). They will NOT come back after a reboot. Fix: pm2 save (RISKY tier — confirm first)." \
    "$(ev_list "unsaved=$(printf '%s' "$UNSAVED" | jq -r 'join(", ")')")"
  else
    SAVE_HAZARD="clean"
  fi
elif [ "$PM2_DAEMON_ALIVE" = "true" ] && [ "$DUMP_PRESENT" = "false" ]; then
  SAVE_HAZARD="no_dump"
  add_finding "restart.save.missing" "critical" "No dump.pm2 — nothing will be resurrected after a reboot" \
    "pm2 save has never been run (or PM2_HOME points somewhere unexpected). A reboot leaves no apps running. Fix: pm2 save after confirming the process list is correct." \
    "$(ev_list "expected_dump_path=$DUMP_PATH")"
fi

# ===========================================================================
# log paths — the thing hand-written globs get wrong
# ===========================================================================

LOGS_JSON="[]"
OUTSIDE_DEFAULT="[]"
DEVNULL_APPS="[]"
LOG_TOTAL_BYTES=0

DEFAULT_LOG_DIR="$PM2_HOME_DIR/logs"
if [ -d "$DEFAULT_LOG_DIR" ]; then
  LOG_TOTAL_BYTES="$(du -sb "$DEFAULT_LOG_DIR" 2>/dev/null | awk '{print $1}')"
  [ -z "$LOG_TOTAL_BYTES" ] && LOG_TOTAL_BYTES=0
fi

if [ "$LIVE_APP_COUNT" -gt 0 ] 2>/dev/null && command -v jq >/dev/null 2>&1; then
  # Build the per-app log facts in the SHELL, where stat/exists can actually
  # be evaluated, and emit one flat JSON object per app. Doing the existence
  # checks inside jq is not possible — jq cannot see the filesystem.
  #
  # The earlier jq-only version produced [] because it tried to test
  # file existence as a jq expression, which is always false/undefined.
  # jq -c on an ARRAY prints the whole array on ONE line, so `while read` sees
  # a single line and (once json_str added no newlines) the loop body runs once
  # with the full array, which jq then fails to parse as one app. Emit one
  # object per line with `jq -c '.[]'` so the loop iterates per app.
  LOGS_JSON="$(printf '%s' "$APPS_JSON" | jq -c '.[]' | while IFS= read -r app; do
    [ -z "$app" ] && continue
    of=$(printf '%s' "$app" | jq -r '.out_file')
    ef=$(printf '%s' "$app" | jq -r '.error_file')

    out_exists=false;  [ -f "$of" ] && out_exists=true
    err_exists=false;  [ -f "$ef" ] && err_exists=true
    out_devnull=false; [ "$of" = "/dev/null" ] && out_devnull=true
    err_devnull=false; [ "$ef" = "/dev/null" ] && err_devnull=true

    out_bytes=0
    if [ "$out_exists" = true ]; then out_bytes=$(wc -c < "$of" 2>/dev/null | tr -d ' ') || out_bytes=0; fi

    # "Outside the default dir" is evaluated PER PATH, not once for the app.
    # A single combined flag marks an app out-of-tree when only one of its two
    # files is, which over-reports and hides which file is actually missing.
    # An absolute path counts as out-of-tree unless it sits under
    # $DEFAULT_LOG_DIR. /dev/null is a deliberate no-log config, not a
    # misdirected path.
    out_outside=false; err_outside=false
    case "$of" in
      "$DEFAULT_LOG_DIR"/*|/dev/null) : ;;
      /*) out_outside=true ;;
    esac
    case "$ef" in
      "$DEFAULT_LOG_DIR"/*|/dev/null) : ;;
      /*) err_outside=true ;;
    esac

    printf '%s\n' "$app" | jq -c \
      --argjson out_exists "$out_exists" \
      --argjson err_exists "$err_exists" \
      --argjson out_devnull "$out_devnull" \
      --argjson err_devnull "$err_devnull" \
      --argjson out_bytes "${out_bytes:-0}" \
      --argjson out_outside "$out_outside" \
      --argjson err_outside "$err_outside" \
      '. + {out_exists:$out_exists, error_exists:$err_exists,
            out_is_devnull:$out_devnull, error_is_devnull:$err_devnull,
            out_bytes:$out_bytes,
            out_outside_default:$out_outside,
            error_outside_default:$err_outside}'
  done | jq -sc '.' 2>/dev/null || echo '[]')"

  OUTSIDE_DEFAULT="$(printf '%s' "$LOGS_JSON" | jq -c '[.[] | select(.out_outside_default or .error_outside_default) | .name]' 2>/dev/null || echo '[]')"
  DEVNULL_APPS="$(printf '%s' "$LOGS_JSON" | jq -c '[.[] | select(.out_is_devnull or .error_is_devnull) | .name]' 2>/dev/null || echo '[]')"

  OUTSIDE_COUNT="$(printf '%s' "$OUTSIDE_DEFAULT" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$OUTSIDE_COUNT" -gt 0 ]; then
    add_finding "logs.outside_default_dir" "high" "Some apps write logs outside the default PM2 log directory" \
      "$OUTSIDE_COUNT app(s) log outside $DEFAULT_LOG_DIR: $(printf '%s' "$OUTSIDE_DEFAULT" | jq -r 'join(", ")'). A config that only globs $DEFAULT_LOG_DIR/*.log silently misses them. scripts/render-vector-config.sh derives the include globs from pm2 jlist for exactly this reason." \
      "$(ev_list "apps=$(printf '%s' "$OUTSIDE_DEFAULT" | jq -r 'join(", ")')" "default_dir=$DEFAULT_LOG_DIR")"
  fi

  DEVNULL_COUNT="$(printf '%s' "$DEVNULL_APPS" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$DEVNULL_COUNT" -gt 0 ]; then
    add_finding "logs.devnull" "medium" "Logging is disabled for some apps" \
      "$DEVNULL_COUNT app(s) have out_file or error_file set to /dev/null, so they produce no logs at all: $(printf '%s' "$DEVNULL_APPS" | jq -r 'join(", ")'). This is a deliberate PM2 configuration, not a pipeline fault — confirm it is intended." \
      "$(ev_list "apps=$(printf '%s' "$DEVNULL_APPS" | jq -r 'join(", ")')")"
  fi
fi

# ===========================================================================
# existing collectors — avoid double ingest
# ===========================================================================

COLLECTORS_JSON="[]"
COLL=""
# Enumerate collector UNITS, not binaries.
#
# `command -v vector` plus `systemctl is-enabled vector` conflates unrelated
# things: a host can run vector.service from a hand-installed binary under
# ~/.vector for Docker logs, which has nothing to do with PM2, and the audit
# then reports a collector that this skill does not control as "enabled at
# boot". Read each unit's ExecStart and config path so every collector is
# attributed correctly.
COLLECTOR_UNITS="[]"
VECTOR_MANAGED_UNIT=""
VECTOR_MANAGED_ENABLED="unknown"
if command -v systemctl >/dev/null 2>&1; then
  UNITS="$(systemctl list-unit-files --no-legend --no-pager 2>/dev/null \
            | awk '$1 ~ /(vector|fluent-bit|filebeat|logstash|promtail|rsyslog)/ {print $1}' \
            | grep -vE '^$|\.service$|^/' )"
  [ -n "$UNITS" ] && UNITS="$(printf '%s\n' "$UNITS" | grep '\.service$' || true)"
  for u in $UNITS; do
    es="$(systemctl show "$u" --property=ExecStart --value 2>/dev/null | head -c 400)"
    bin="$(printf '%s' "$es" | grep -oE '[^ ;]*/vector([[:space:]]|$)' | head -1 | sed 's/[[:space:]]*$//')"
    ver="unknown"; [ -n "$bin" ] && [ -x "$bin" ] && ver="$("$bin" --version 2>/dev/null | awk '{print $2}' | tr -d 'v')"
    cfgs="$(systemctl show "$u" --property=ExecStart --value 2>/dev/null | grep -oE '\-\-config[= ][^ ;]*' | sed 's/--config[= ]*//' | tr '\n' ',')"
    en=false; systemctl is-enabled "$u" >/dev/null 2>&1 && en=true
    ac=false; systemctl is-active "$u" >/dev/null 2>&1 && ac=true
    ent=$(printf '{"unit":%s,"binary":%s,"version":%s,"config_paths":%s,"enabled":%s,"active":%s}' \
      "$(json_str "$u")" "$(json_str "$bin")" "$(json_str "$ver")" \
      "$(if [ -n "$cfgs" ]; then printf '["%s"]' "$(printf '%s' "$cfgs" | sed 's/,$//')"; else printf 'null'; fi)" \
      "$en" "$ac")
    if [ -z "$COLLECTOR_UNITS" ] || [ "$COLLECTOR_UNITS" = "[]" ]; then
      COLLECTOR_UNITS="[$ent]"
    else
      COLLECTOR_UNITS="${COLLECTOR_UNITS%\]}],[$ent]"
    fi
    # The unit this skill owns is the one running OUR config path.
    case "$cfgs" in
      */pm2-axiom.toml*|*host-insights.toml*) VECTOR_MANAGED_UNIT="$u"; VECTOR_MANAGED_ENABLED="$en" ;;
    esac
  done
fi

if [ "$VECTOR_INSTALLED" = "true" ]; then
  COLL="$COLL{\"name\":\"vector-binary\",\"version\":\"$VECTOR_VERSION_DETECTED\",\"managed_unit\":$(json_str "$VECTOR_MANAGED_UNIT")}"
fi
for agent in fluent-bit filebeat logstash prometheus; do
  if command -v "$agent" >/dev/null 2>&1 || systemctl list-unit-files "${agent}.service" >/dev/null 2>&1; then
    [ -n "$COLL" ] && COLL="$COLL,"
    COLL="$COLL{\"name\":\"$agent\",\"installed\":true}"
  fi
done
if command -v rsyslogd >/dev/null 2>&1; then
  [ -n "$COLL" ] && COLL="$COLL,"
  COLL="$COLL{\"name\":\"rsyslog\",\"installed\":true}"
fi
[ -n "$COLL" ] && COLLECTORS_JSON="[$COLL]"

VECTOR_CONFIGS_FOUND="[]"
VECTOR_CFG_COUNT=0
if [ -d /etc/vector ]; then
  # Skip non-config directories. The Vector deb package ships
  # /etc/vector/examples/, and a bare find counted all of those as "configs",
  # overstating how many collectors exist. Also skip editor backups.
  VECTOR_CFG_PATHS="$(find /etc/vector -maxdepth 2 \
      \( -path '*/examples' -o -path '*/examples/*' -o -path '*/.git' -o -path '*/backup*' \) -prune -o \
      -type f \( -name '*.toml' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) \
      ! -name '*.bak' ! -name '*~' ! -name '*.orig' -print 2>/dev/null | sort)"
  VECTOR_CFG_COUNT="$(printf '%s' "$VECTOR_CFG_PATHS" | grep -c . || true)"
  [ -z "$VECTOR_CFG_COUNT" ] && VECTOR_CFG_COUNT=0
  VECTOR_CONFIGS_FOUND="null"
  [ "$VECTOR_CFG_COUNT" -gt 0 ] && VECTOR_CONFIGS_FOUND="[$(printf '%s\n' "$VECTOR_CFG_PATHS" | sed 's/^/"/;s/$/"/' | paste -sd, -)]"

  # Does an existing config already read PM2 logs? Adding a second pipeline over
  # the same files means duplicate ingest and double cost.
  #
  # A config this skill generated is skipped: after install, the audit would
  # otherwise report the skill's own config as a third-party conflict, which is
  # a guaranteed false positive on every subsequent run.
  FOREIGN="$(printf '%s\n' "$VECTOR_CFG_PATHS" | grep . | while IFS= read -r f; do
                [ -z "$f" ] && continue
                grep -q 'managed-by: pm2-logs-agent' "$f" 2>/dev/null && continue
                grep -l '\.pm2/logs' "$f" 2>/dev/null
              done)"
  if [ -n "$FOREIGN" ]; then
    MATCHING="$(printf '%s\n' "$FOREIGN" | sed 's/^/"/;s/$/"/' | paste -sd, -)"
    add_finding "collectors.duplicate_ingest" "critical" "Another Vector config already reads PM2 logs" \
      "Found PM2 log references in: $MATCHING. These are not managed by pm2-logs-agent. Adding a second pipeline over the same files will ingest every event twice and double the Axiom cost. Either extend that config or exclude these paths from the new one. This is a CHANGE tier action requiring review." \
      "$(ev_list "files=$MATCHING")"
  elif [ "$VECTOR_CFG_COUNT" -gt 0 ] && printf '%s\n' "$VECTOR_CFG_PATHS" | grep . \
        | xargs -r grep -l 'managed-by: pm2-logs-agent' 2>/dev/null | grep -q .; then
    add_finding "collectors.managed_config_present" "info" "pm2-logs-agent config found" \
      "Existing config(s) managed by pm2-logs-agent were found and skipped in the duplicate-ingest check. Re-run the audit after a config change to re-verify." \
      "$(ev_list "count=$VECTOR_CFG_COUNT")"
  fi
fi

# Does OUR collector survive a reboot? This is half of the 2x2 matrix that
# produces the two silent-blackout scenarios.
#
# Scoped to the unit that runs our config path, not to any unit named
# "vector.service": an unrelated vector.service shipping Docker logs must not be
# counted as evidence that PM2 logs will survive a reboot.
VECTOR_ENABLED="false"
[ "$VECTOR_MANAGED_UNIT" != "" ] && [ "$VECTOR_MANAGED_ENABLED" = "true" ] && VECTOR_ENABLED="true"

if [ "$VECTOR_INSTALLED" = "true" ] && [ "$VECTOR_MANAGED_UNIT" = "" ]; then
  OTHER_V="$(printf '%s' "$COLLECTOR_UNITS" | jq -r '[.[] | select(.binary != null and .binary != "")] | length' 2>/dev/null || echo 0)"
  [ "${OTHER_V:-0}" -gt 0 ] 2>/dev/null && add_finding "collectors.unrelated_vector" "medium" \
    "A Vector collector exists but it is not managed by pm2-logs-agent" \
    "Found $OTHER_V vector unit(s) running different config paths. None of them read PM2 logs for this skill, so PM2 logs will NOT survive a reboot even though a collector is enabled. Either extend that unit or install a dedicated one for this pipeline." \
    "$(ev_list "units=$(printf '%s' "$COLLECTOR_UNITS" | jq -c '[.[].unit] // []' 2>/dev/null)")"
fi

if [ "$PM2_UNIT_PRESENT" = "true" ] && [ "$PM2_UNIT_ENABLED" = "true" ] && [ "$VECTOR_INSTALLED" = "true" ] && [ "$VECTOR_ENABLED" = "false" ]; then
  add_finding "restart.matrix.logs_vanish" "critical" "PM2 survives reboot but the log collector does not — silent observability blackout" \
  "PM2 is saved and its unit is enabled, but the Vector service is NOT enabled at boot. After a reboot every app returns and NO logs reach Axiom. Nothing errors; the dashboard simply goes quiet. Fix: systemctl enable vector (CHANGE tier)." \
  "[\"pm2_unit_enabled=true\",\"vector_enabled=false\"]"
elif [ "$PM2_UNIT_PRESENT" != "true" ] && [ "$VECTOR_INSTALLED" = "true" ] && [ "$VECTOR_ENABLED" = "true" ]; then
  add_finding "restart.matrix.pipeline_idle" "high" "Collector survives reboot but PM2 does not — healthy pipeline, zero data" \
  "Vector is enabled at boot but PM2 has no enabled unit. After a reboot the collector starts, reports healthy, and receives nothing because no apps are running. This looks fine in every dashboard. Fix: pm2 startup && pm2 save (RISKY tier)." \
  "[\"pm2_unit_present=false\",\"vector_enabled=true\"]"
fi

# ===========================================================================
# can the collector actually READ these files?
# ===========================================================================
#
# The most consequential unverified assumption in this whole audit. If the
# Vector service user lacks execute permission on the parent directories or read
# permission on the files, Vector starts cleanly, reports healthy, and ingests
# nothing. Nothing in `systemctl status` says so.
#
# `sudo -u <user> test -r` is the honest test, so use it when available. When
# not (no sudo, or already unprivileged) say "unknown" rather than guessing.

READABLE_UNREADABLE="[]"
PERM_METHOD="none"
UNREADABLE_COUNT=0

# Which user does Vector run as?
VECTOR_RUN_USER=""
for u in vector _vector; do
  id "$u" >/dev/null 2>&1 && { VECTOR_RUN_USER="$u"; break; }
done

if [ "$VECTOR_RUN_USER" != "" ]; then
  if [ "$(id -un)" = "$VECTOR_RUN_USER" ]; then
    PERM_METHOD="direct"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    PERM_METHOD="sudo"
  fi
fi

if [ "$PERM_METHOD" != "none" ]; then
  READABLE_UNREADABLE="$(printf '%s' "$LOGS_JSON" | jq -c '.[]' 2>/dev/null | while IFS= read -r a; do
    [ -z "$a" ] && continue
    for key in out_file error_file; do
      p="$(printf '%s' "$a" | jq -r ".$key")"
      [ -z "$p" ] || [ "$p" = "/dev/null" ] && continue
      [ -f "$p" ] || continue
      if [ "$PERM_METHOD" = "direct" ]; then
        [ -r "$p" ] && verdict=readable || verdict=unreadable
      else
        if sudo -n -u "$VECTOR_RUN_USER" test -r "$p" >/dev/null 2>&1; then verdict=readable
        elif sudo -n -u "$VECTOR_RUN_USER" test -r "$p" >/dev/null 2>&1; then verdict=denied
        else verdict=absent; fi
      fi
      printf '%s\n' "$a" | jq -c --argjson v "$verdict" --arg k "$key" --arg p "$p" \
        '. + {($k + "_readable"): $v, ($k + "_path_checked"): $p}'
    done
  done | jq -sc '.' 2>/dev/null || echo '[]')"
  # Fold the verdicts back into per_app.
  if [ "$(printf '%s' "$READABLE_UNREADABLE" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    LOGS_JSON="$(jq -n --argjson base "$LOGS_JSON" --argjson res "$READABLE_UNREADABLE" '
      [ $base[] as $b
        | ($res | map(select(.name == $b.name)) | .[0] // {}) as $r
        | $b + ($r | del(.name, .out_file, .error_file)) ]' 2>/dev/null || echo '[]')"
  fi
  UNREADABLE_LIST="$(printf '%s' "$LOGS_JSON" | jq -c '[.[] | select(.out_readable == "unreadable" or .out_readable == "denied" or .error_readable == "unreadable" or .error_readable == "denied") | .name]' 2>/dev/null || echo '[]')"
  UNREADABLE_COUNT="$(printf '%s' "$UNREADABLE_LIST" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$UNREADABLE_COUNT" -gt 0 ]; then
    add_finding "logs.unreadable_by_collector" "critical" "The collector cannot read some log files" \
      "Tested as user '$VECTOR_RUN_USER': $UNREADABLE_COUNT app(s) have log files the Vector service cannot read. Vector will start, report healthy, and ingest NOTHING from them. Fix with a group or ACL: usermod -aG <pm2-user> $VECTOR_RUN_USER, or setfacl -R -m u:$VECTOR_RUN_USER:rX <log-dir> (CHANGE tier)." \
      "$(ev_list "apps=$(printf '%s' "$UNREADABLE_LIST" | jq -r 'join(", ")')" "tested_as=$VECTOR_RUN_USER")"
  fi
else
  # No way to test. Report the files so a human can check, rather than implying
  # access is fine.
  add_finding "logs.readability_unknown" "medium" "Cannot verify the collector can read the log files" \
    "The Vector service user '$VECTOR_RUN_USER' could not be tested (needs sudo, or run as that user). Vector will ingest nothing from files it cannot read, and that failure is silent. Verify with: sudo -u $VECTOR_RUN_USER test -r <logfile>" \
    "$(ev_list "vector_user=$VECTOR_RUN_USER")"
fi

# Files on disk that belong to no live app. Orphaned log files look like a
# pipeline problem when the real cause is an app that was removed.
ORPHAN_FILES=""
if [ -d "$DEFAULT_LOG_DIR" ] && [ "$LIVE_APP_COUNT" -gt 0 ] 2>/dev/null && command -v jq >/dev/null 2>&1; then
  KNOWN="$(printf '%s' "$APPS_JSON" | jq -r '[.[].out_file, .[].error_file] | .[]' 2>/dev/null | grep . || true)"
  ALLF="$(find "$DEFAULT_LOG_DIR" -maxdepth 1 -name '*.log' 2>/dev/null | sort)"
  ORPHAN_FILES="$(printf '%s\n' "$ALLF" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    printf '%s\n' "$KNOWN" | grep -qxF "$f" || printf '%s\n' "$f"
  done | paste -sd, - 2>/dev/null || true)"
  ORPHAN_N="$(printf '%s' "$ORPHAN_FILES" | awk -F, 'NF>0{n++} END{print n+0}')"
  if [ "${ORPHAN_N:-0}" -gt 0 ]; then
    add_finding "logs.orphan_files" "low" "Log files with no matching running app" \
      "$ORPHAN_N log file(s) in $DEFAULT_LOG_DIR belong to no currently running app: $ORPHAN_FILES. These are leftovers from removed apps, which Vector will still ingest. That is harmless but adds noise. Confirm they are genuinely orphaned before removing anything: pm2 flush deletes ALL log content (RISKY)." \
      "$(ev_list "count=$ORPHAN_N" "files=$ORPHAN_FILES")"
  fi
fi

# ===========================================================================
# rotation
# ===========================================================================

LOGROTATE_MODULE="false"
LOGROTATE_NATIVE="false"
if command -v pm2 >/dev/null 2>&1; then
  pm2 ls 2>/dev/null | grep -q 'pm2-logrotate' && LOGROTATE_MODULE="true"
fi
ls /etc/logrotate.d/pm2-* >/dev/null 2>&1 && LOGROTATE_NATIVE="true"

ROTATED_GZ_COUNT=0
if [ -d "$DEFAULT_LOG_DIR" ]; then
  ROTATED_GZ_COUNT="$(find "$DEFAULT_LOG_DIR" -maxdepth 1 -name '*.log.*.gz' 2>/dev/null | wc -l | tr -d ' ')"
fi

# ===========================================================================
# network identity
# ===========================================================================

PUBLIC_IP=""; PUBLIC_IP_SOURCE=""
for u in "https://api.ipify.org" "https://ifconfig.me/ip" "https://checkip.amazonaws.com"; do
  PUBLIC_IP="$(curl -4 -s --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
  if printf '%s' "$PUBLIC_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    PUBLIC_IP_SOURCE="$u"; break
  fi
  PUBLIC_IP=""
done
[ -n "$PUBLIC_IP" ] && add_finding "network.public_ip" "info" "Public IPv4 available" \
  "Probed $PUBLIC_IP via $PUBLIC_IP_SOURCE. Set VECTOR_TAG_PUBLIC_IP in the env file to attach it to every log line, or omit it. Note a public IP may count as personal data under GDPR-style regimes — enabling it is your decision." \
  "$(ev_list "ip=$PUBLIC_IP" "source=$PUBLIC_IP_SOURCE")"

if [ -z "$PUBLIC_IP" ]; then
  add_finding "network.public_ip_absent" "info" "Public IPv4 could not be probed" \
    "No outbound route to an IP echo service, or all probes timed out. This is expected in air-gapped environments and is not an error; the tag stays unset."
fi

TAILSCALE_INSTALLED="false"; TAILSCALE_ACTIVE="false"; TAILSCALE_IP=""
if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_INSTALLED="true"
  if tailscale status >/dev/null 2>&1; then
    TAILSCALE_ACTIVE="true"
    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -1 | tr -d '[:space:]')"
    [ -z "$TAILSCALE_IP" ] && TAILSCALE_IP="$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    # Sanity: Tailscale v4 addresses live in 100.64.0.0/10.
    if [ -n "$TAILSCALE_IP" ]; then
      case "$TAILSCALE_IP" in
        100.*) : ;;
        *) TAILSCALE_IP=""; TAILSCALE_ACTIVE="false" ;;
      esac
    fi
  fi
fi
[ "$TAILSCALE_ACTIVE" = "true" ] && add_finding "network.tailscale" "info" "Tailscale is active" \
  "Tailscale IPv4 $TAILSCALE_IP will be attached as VECTOR_TAG_TAILSCALE_IP if you enable it." \
  "$(ev_list "tailscale_ip=$TAILSCALE_IP")"

# ===========================================================================
# capacity
# ===========================================================================

DISK_FREE_PCT="null"
DISK_FREE_BYTES="null"
DISK_TOTAL_BYTES="null"
DISK_MOUNT=""

# df field positions for `df -PT`:
#   $1 filesystem  $2 type  $3 total  $4 used  $5 available  $6 capacity%  $7 mount
#
# Two mistakes made here during development, both silent:
#  - Using $2 for total returned "ext4" (that is the TYPE column), which made
#    the arithmetic below produce nulls.
#  - Reading $5 as "available" while intending "used" inverted free-space maths
#    and raised a FALSE "disk nearly full" finding.
# -B1 selects byte units; without it the size columns are 1024-blocks.
if df -PT -B1 / >/dev/null 2>&1; then
  DISK_LINE="$(df -PT -B1 / 2>/dev/null | tail -1)"
  DISK_TOTAL_BYTES="$(printf '%s' "$DISK_LINE" | awk '{print $3}')"
  DISK_FREE_BYTES="$(printf '%s' "$DISK_LINE" | awk '{print $5}')"
  DISK_MOUNT="$(printf '%s' "$DISK_LINE" | awk '{print $7}')"
else
  # Fallback for coreutils/busybox without -B1: 1024-blocks.
  DISK_LINE="$(df -PT / 2>/dev/null | tail -1)"
  DISK_TOTAL_BYTES="$(printf '%s' "$DISK_LINE" | awk '{printf "%.0f", $3*1024}')"
  DISK_FREE_BYTES="$(printf '%s' "$DISK_LINE" | awk '{printf "%.0f", $5*1024}')"
  DISK_MOUNT="$(printf '%s' "$DISK_LINE" | awk '{print $7}')"
fi

case "${DISK_TOTAL_BYTES:-}" in ''|*[!0-9]*) DISK_TOTAL_BYTES="null" ;; esac
case "${DISK_FREE_BYTES:-}"  in ''|*[!0-9]*) DISK_FREE_BYTES="null"  ;; esac

if [ "$DISK_TOTAL_BYTES" != "null" ] && [ "$DISK_FREE_BYTES" != "null" ]; then
  DISK_FREE_PCT="$(awk -v f="$DISK_FREE_BYTES" -v t="$DISK_TOTAL_BYTES" 'BEGIN{ if (t>0) printf "%.1f", (f/t)*100 }')"
fi
if [ "${DISK_FREE_PCT:-null}" != "null" ] && awk -v p="$DISK_FREE_PCT" 'BEGIN{exit !(p+0 < 15 && p != "")}' 2>/dev/null; then
  add_finding "capacity.disk_low" "high" "Root filesystem is nearly full" \
    "Only ${DISK_FREE_PCT}% free on $DISK_MOUNT. An Axiom outage will fill the disk buffer and then block log ingestion entirely. Free space or reduce buffer.max_size." \
    "$(ev_list "mount=$DISK_MOUNT" "free_pct=$DISK_FREE_PCT")"
fi

# ===========================================================================
# emit
# ===========================================================================

[ -z "$FINDINGS_JSON" ] && FINDINGS_JSON='{"id":"clean","severity":"info","title":"No findings","detail":"Nothing actionable detected.","evidence":[]}'

SEV_COUNTS="$(printf '%s' "$FINDINGS_JSON" | jq -c 'group_by(.severity) | map({(.[0].severity): length}) | add // {}' 2>/dev/null || echo '{}')"

cat <<JSON
{
  "schema": 1,
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "read_only": true,
  "host": {
    "hostname": $(json_str "$(hostname 2>/dev/null || echo unknown)"),
    "user": $(json_str "$TARGET_USER"),
    "home": $(json_str "$HOME"),
    "containerized": $(json_bool "$CONTAINERIZED")
  },
  "pm2": {
    "installed": $(json_bool "$PM2_INSTALLED"),
    "version": $(json_str "$PM2_VERSION"),
    "daemon_alive": $(json_bool "$PM2_DAEMON_ALIVE"),
    "pm2_home": $(json_str "$PM2_HOME_DIR"),
    "live_app_count": $LIVE_APP_COUNT,
    "apps": $APPS_JSON
  },
  "restart": {
    "unit_name": $(json_str "$PM2_UNIT_NAME"),
    "unit_present": $(json_bool "$PM2_UNIT_PRESENT"),
    "unit_enabled": $(json_str "$PM2_UNIT_ENABLED"),
    "unit_node_path_valid": $(json_str "$PM2_UNIT_NODE_VALID"),
    "unit_exec_start": $(json_str "$PM2_UNIT_EXECSTART"),
    "dump_present": $(json_bool "$DUMP_PRESENT"),
    "dump_path": $(json_str "$DUMP_PATH"),
    "dump_mtime": $(json_str "$DUMP_MTIME"),
    "dump_app_count": $DUMP_APP_COUNT,
    "dump_apps": $DUMP_APPS,
    "save_hazard": $(json_str "$SAVE_HAZARD"),
    "apps_at_risk_if_saved": $APPS_AT_RISK,
    "vector_enabled_at_boot": $(json_bool "$VECTOR_ENABLED")
  },
  "logs": {
    "default_dir": $(json_str "$DEFAULT_LOG_DIR"),
    "daemon_log_present": $(json_bool "$([ -f "$PM2_HOME_DIR/pm2.log" ] && echo true || echo false)"),
    "total_bytes": $LOG_TOTAL_BYTES,
    "per_app": $LOGS_JSON,
    "apps_outside_default_dir": $OUTSIDE_DEFAULT,
    "apps_with_devnull": $DEVNULL_APPS,
    "rotated_gz_count": $ROTATED_GZ_COUNT,
    "logrotate_module": $(json_bool "$LOGROTATE_MODULE"),
    "logrotate_native": $(json_bool "$LOGROTATE_NATIVE")
  },
  "collectors": {
    "vector_installed": $(json_bool "$VECTOR_INSTALLED"),
    "managed_unit": $(json_str "${VECTOR_MANAGED_UNIT:-}"),
    "managed_unit_enabled": $(json_str "${VECTOR_MANAGED_ENABLED:-unknown}"),
    "collector_units": ${COLLECTOR_UNITS:-[]},
    "vector_version": $(json_str "$VECTOR_VERSION_DETECTED"),
    "vector_pinned_version": $(json_str "$PINNED_VERSION"),
    "vector_version_drift": $(json_str "$VECTOR_DRIFT"),
    "vector_config_count": $VECTOR_CFG_COUNT,
    "vector_configs": $VECTOR_CONFIGS_FOUND,
    "others": $COLLECTORS_JSON
  },
  "network": {
    "public_ip": $(json_str "$PUBLIC_IP"),
    "public_ip_source": $(json_str "$PUBLIC_IP_SOURCE"),
    "tailscale_installed": $(json_bool "$TAILSCALE_INSTALLED"),
    "tailscale_active": $(json_bool "$TAILSCALE_ACTIVE"),
    "tailscale_ip": $(json_str "$TAILSCALE_IP")
  },
  "capacity": {
    "disk_mount": $(json_str "$DISK_MOUNT"),
    "disk_total_bytes": $(json_str "$DISK_TOTAL_BYTES"),
    "disk_free_bytes": $(json_str "$DISK_FREE_BYTES"),
    "disk_free_pct": $(json_str "$DISK_FREE_PCT")
  },
  "severity_counts": $SEV_COUNTS,
  "findings": [$FINDINGS_JSON]
}
JSON

exit 0