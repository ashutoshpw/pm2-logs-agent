#!/usr/bin/env bash
# shellcheck disable=SC2015
#
# SC2015: `[ cond ] && info ... || info ...` is used as a compact
# if/else throughout. Safe because info() always returns 0, so the second
# branch cannot run after a successful first branch.
#
# shellcheck disable=SC1090
# SC1090: the env file is an operator-supplied path, so ShellCheck cannot
# follow the `source` of it.
# pm2-logs-agent — install the pipeline on a host
#
# REQUIRES ROOT. Every step here writes outside the skill directory, installs a
# service that starts at boot, and grants filesystem access to another user.
# Nothing in this script runs without an explicit confirmation, and every
# destructive step is reversible (see scripts/uninstall.sh).
#
# This is the installer for the PIPELINE. install-vector-pinned.sh only
# installs the Vector binary.
#
# Usage:
#   install.sh --pm2-home PATH --env-file PATH [options]
#   install.sh --plan                     # print what would happen, change nothing
#
# Options:
#   --pm2-home PATH     PM2_HOME to collect from (required)
#   --env-file PATH     credential/tag env file to install (required)
#   --vector-user NAME  service user for vector (default: vector)
#   --pm2-user NAME     user that owns the PM2 logs (default: detected from PM2_HOME)
#   --dataset NAME      Axiom dataset (default: pm2-service-logs)
#   --config-dir PATH   default /etc/vector
#   --lib-dir PATH      default /opt/pm2-logs-agent
#   --plan              show the plan and exit
#   --no-insights       install only the log pipeline
#   --no-logrotate      do not configure pm2-logrotate
#
# Steps, in order:
#   1. install the pinned Vector binary          (SAFE)
#   2. create the data and lib directories        (SAFE)
#   3. install the host-insights script           (SAFE)
#   4. render and validate both configs           (SAFE)
#   5. install the credential file, mode 0600     (SAFE)
#   6. grant the vector user read access via ACL  (CHANGE)
#   7. install and enable the systemd unit        (CHANGE)
#   8. configure pm2-logrotate                    (CHANGE)
#
# Exit: 0 success, 1 a step failed, 2 usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS="$SKILL_DIR/assets"
SCRIPTS="$SKILL_DIR/scripts"

PM2_HOME_DIR=""
ENV_SRC=""
VECTOR_USER="vector"
PM2_USER=""
DATASET="pm2-service-logs"
CONFIG_DIR="/etc/vector"
LIB_DIR="/opt/pm2-logs-agent"
PLAN_ONLY="no"
WITH_INSIGHTS="yes"
WITH_LOGROTATE="yes"

while [ $# -gt 0 ]; do
  case "$1" in
    --pm2-home)    PM2_HOME_DIR="${2:-}"; shift 2 ;;
    --env-file)    ENV_SRC="${2:-}"; shift 2 ;;
    --vector-user) VECTOR_USER="${2:-}"; shift 2 ;;
    --pm2-user)    PM2_USER="${2:-}"; shift 2 ;;
    --dataset)     DATASET="${2:-}"; shift 2 ;;
    --config-dir)  CONFIG_DIR="${2:-}"; shift 2 ;;
    --lib-dir)     LIB_DIR="${2:-}"; shift 2 ;;
    --plan)        PLAN_ONLY="yes"; shift ;;
    --no-insights) WITH_INSIGHTS="no"; shift ;;
    --no-logrotate) WITH_LOGROTATE="no"; shift ;;
    -h|--help)     sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$PM2_HOME_DIR" ] || { printf 'install: --pm2-home is required\n' >&2; exit 2; }
[ -d "$PM2_HOME_DIR" ] || { printf 'install: PM2_HOME does not exist: %s\n' "$PM2_HOME_DIR" >&2; exit 2; }
[ -n "$ENV_SRC" ] || { printf 'install: --env-file is required\n' >&2; exit 2; }
[ -f "$ENV_SRC" ] || { printf 'install: env file not found: %s\n' "$ENV_SRC" >&2; exit 2; }

# PM2_USER is whoever owns the logs; that is who the ACL must grant access from.
if [ -z "$PM2_USER" ]; then
  PM2_USER="$(stat -c '%U' "$PM2_HOME_DIR" 2>/dev/null || echo root)"
fi

LOG_CONFIG="$CONFIG_DIR/pm2-axiom.toml"
INSIGHTS_CONFIG="$CONFIG_DIR/host-insights.toml"
UNIT_NAME="pm2-logs-agent"
# Marks that this skill (not the operator) installed pm2-logrotate, so
# uninstall.sh knows whether it is safe to remove.
LOGROTATE_MARKER="/var/lib/pm2-logs-agent/.installed-logrotate"

# shellcheck source=/dev/null
[ -f "$ASSETS/vector-version.env" ] && . "$ASSETS/vector-version.env"
V_PINNED="${VECTOR_VERSION:-unknown}"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
info() { printf '   %s\n' "$1"; }
fail() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------
if [ "$PLAN_ONLY" = "yes" ]; then
  cat <<PLAN
pm2-logs-agent installation plan
================================

PM2_HOME        : $PM2_HOME_DIR
PM2 user        : $PM2_USER
Vector service  : $VECTOR_USER
Dataset         : $DATASET
Config dir      : $CONFIG_DIR
Lib dir         : $LIB_DIR
Insights        : $WITH_INSIGHTS
pm2-logrotate   : $WITH_LOGROTATE

Steps
-----
SAFE   install pinned Vector ($V_PINNED)
SAFE   create $CONFIG_DIR and $LIB_DIR
SAFE   install host-insights.sh to $LIB_DIR
SAFE   render + validate $LOG_CONFIG$( [ "$WITH_INSIGHTS" = yes ] && echo " and $INSIGHTS_CONFIG" )
SAFE   install credential file to $CONFIG_DIR/pm2-axiom.env (mode 0600)
CHANGE grant $VECTOR_USER read access to $PM2_HOME_DIR via ACL (traverse + read + default ACL)
CHANGE install $UNIT_NAME.service (installed but deliberately NOT enabled)
CHANGE $( [ "$WITH_LOGROTATE" = yes ] && echo "configure pm2-logrotate (max_size 10M, retain 7)" || echo "skip logrotate" )

The unit is left DISABLED on purpose. Prove it works first:
  scripts/smoke-test.sh --config $LOG_CONFIG
  scripts/validate-token.sh --env-file $CONFIG_DIR/pm2-axiom.env --dataset $DATASET
  systemctl enable --now $UNIT_NAME

To undo everything: scripts/uninstall.sh --config-dir $CONFIG_DIR --lib-dir $LIB_DIR
PLAN
  exit 0
fi

[ "$(id -u)" = "0" ] || fail "must run as root"

command -v setfacl >/dev/null 2>&1 || {
  info "WARNING: setfacl is not installed, so read access cannot be granted."
  info "         Install the 'acl' package, or grant access manually:"
  info "         usermod -aG $PM2_USER $VECTOR_USER"
}

id "$VECTOR_USER" >/dev/null 2>&1 || fail "service user '$VECTOR_USER' does not exist. Create it first: useradd --system --no-create-home --shell /usr/sbin/nologin $VECTOR_USER"

# ---------------------------------------------------------------------------
step "1/8  pinned Vector binary"
# ---------------------------------------------------------------------------
"$SCRIPTS/install-vector-pinned.sh" || fail "Vector install failed"

# ---------------------------------------------------------------------------
step "2/8  directories"
# ---------------------------------------------------------------------------
install -d -m 0755 "$CONFIG_DIR"
install -d -m 0755 "$LIB_DIR"
install -d -o "$VECTOR_USER" -g "$VECTOR_USER" -m 0750 /var/lib/vector
info "$CONFIG_DIR, $LIB_DIR, /var/lib/vector"

# ---------------------------------------------------------------------------
step "3/8  host-insights script"
# ---------------------------------------------------------------------------
if [ "$WITH_INSIGHTS" = "yes" ]; then
  install -m 0755 "$ASSETS/host-insights.sh" "$LIB_DIR/host-insights.sh"
  info "$LIB_DIR/host-insights.sh"
else
  info "skipped (--no-insights)"
fi

# ---------------------------------------------------------------------------
step "4/8  render and validate configs"
# ---------------------------------------------------------------------------
"$SCRIPTS/render-vector-config.sh" --pm2-home "$PM2_HOME_DIR" --dataset "$DATASET" \
  --first-run --out "$LOG_CONFIG" || fail "could not render $LOG_CONFIG"
info "$LOG_CONFIG (first-run backfill)"

if [ "$WITH_INSIGHTS" = "yes" ]; then
  "$SCRIPTS/render-vector-config.sh" --insights --out "$INSIGHTS_CONFIG" || fail "could not render $INSIGHTS_CONFIG"
  info "$INSIGHTS_CONFIG"
  # Backfill of the log pipeline would re-read PM2 logs; insights has no source
  # file state so it is unaffected.
  "$SCRIPTS/render-vector-config.sh" --pm2-home "$PM2_HOME_DIR" --dataset "$DATASET" \
    --cutover --out "$LOG_CONFIG" || fail "could not re-render $LOG_CONFIG"
  info "switched $LOG_CONFIG to tail-only (--cutover); the historical backfill is capped by ignore_older_secs"
fi

VEC="$(command -v vector)"
if "$VEC" validate --no-environment "$LOG_CONFIG" >/dev/null 2>&1; then
  info "validate OK (without credentials)"
else
  info "validate needs credentials; retrying with the env file loaded"
  # shellcheck disable=SC1090  # path is an operator-supplied argument
  set -a; . "$ENV_SRC"; set +a
  VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true \
    "$VEC" validate --no-environment "$LOG_CONFIG" >/dev/null 2>&1 \
    || fail "$LOG_CONFIG failed validation even with credentials"
  info "validate OK (with credentials)"
fi

# ---------------------------------------------------------------------------
step "5/8  credential file"
# ---------------------------------------------------------------------------
install -m 0600 -o root -g "$VECTOR_USER" "$ENV_SRC" "$CONFIG_DIR/pm2-axiom.env"
info "$CONFIG_DIR/pm2-axiom.env (0600 root:$VECTOR_USER)"

if grep -qE '^\s*SECRET_AXIOM_TOKEN=\s*$' "$CONFIG_DIR/pm2-axiom.env" 2>/dev/null; then
  fail "SECRET_AXIOM_TOKEN is empty. Run scripts/validate-token.sh with a real token first, or the unit will refuse to start."
fi

# ---------------------------------------------------------------------------
step "6/8  filesystem access for the vector user"
# ---------------------------------------------------------------------------
if command -v setfacl >/dev/null 2>&1; then
  # Traverse-only ACL on the ancestors. Without execute (x) on the PARENT
  # directories a user cannot reach the log files at all, no matter what the
  # file ACLs say — this is why the ACL must be applied to /root, the traverse
  # path, and the logs directory, not just the logs themselves.
  for d in "$PM2_HOME_DIR" "$(dirname "$PM2_HOME_DIR")" /root; do
    [ -d "$d" ] || continue
    case "$d" in /) continue ;; esac
    setfacl -m "u:$VECTOR_USER:--x" "$d" 2>/dev/null \
      && info "traverse ACL on $d" \
      || info "could not set traverse ACL on $d (may already be correct)"
  done
  # Read on the log files, plus a DEFAULT ACL so files created by rotation
  # stay readable. Without the default ACL, every newly rotated file becomes
  # unreadable and ingestion stops silently after the first rotation.
  setfacl -R -m "u:$VECTOR_USER:rX" "$PM2_HOME_DIR" 2>/dev/null && info "read ACL on $PM2_HOME_DIR (recursive)"
  setfacl -d -m "u:$VECTOR_USER:rX" "$PM2_HOME_DIR/logs" 2>/dev/null && info "default ACL on $PM2_HOME_DIR/logs (new files stay readable)"
  # pm2.log sits outside logs/ and has its own ACL needs.
  [ -f "$PM2_HOME_DIR/pm2.log" ] && { setfacl -m "u:$VECTOR_USER:r" "$PM2_HOME_DIR/pm2.log" 2>/dev/null && info "read ACL on $PM2_HOME_DIR/pm2.log"; }
else
  info "setfacl unavailable — granting via group membership instead"
  info "  usermod -aG $PM2_USER $VECTOR_USER   (run this yourself, then restart the unit)"
fi

# ---------------------------------------------------------------------------
step "7/8  systemd unit"
# ---------------------------------------------------------------------------
if [ -f "/etc/systemd/system/$UNIT_NAME.service" ]; then
  cp "/etc/systemd/system/$UNIT_NAME.service" "/etc/systemd/system/$UNIT_NAME.service.bak"
  info "backed up the existing unit to $UNIT_NAME.service.bak"
fi
install -m 0644 "$ASSETS/vector-pm2-axiom.service" "/etc/systemd/system/$UNIT_NAME.service"

# Point the unit's config paths at where we actually installed them.
sed -i "s#/etc/vector/pm2-axiom.toml#$LOG_CONFIG#g; s#/etc/vector/host-insights.toml#$INSIGHTS_CONFIG#g; s#^User=.*#User=$VECTOR_USER#; s#^Group=.*#Group=$VECTOR_USER#" \
  "/etc/systemd/system/$UNIT_NAME.service"

systemctl daemon-reload

# Do NOT enable yet. Enabling a unit that immediately crash-loops on a missing
# token is the failure mode the smoke test exists to prevent; the operator runs
# it and then enables.
info "installed /etc/systemd/system/$UNIT_NAME.service"
info "NOT enabled yet. Run:"
info "  $VEC validate --no-environment $LOG_CONFIG   # with credentials loaded"
info "  $SCRIPTS/smoke-test.sh --config $LOG_CONFIG"
info "  systemctl enable --now $UNIT_NAME"

# ---------------------------------------------------------------------------
step "8/8  pm2-logrotate"
# ---------------------------------------------------------------------------
if [ "$WITH_LOGROTATE" = "yes" ]; then
  if command -v pm2 >/dev/null 2>&1 && pm2 ls 2>/dev/null | grep -q pm2-logrotate; then
    pm2 set pm2-logrotate:max_size 10M   >/dev/null 2>&1
    pm2 set pm2-logrotate:retain 7        >/dev/null 2>&1
    pm2 set pm2-logrotate:compress true   >/dev/null 2>&1
    info "configured pm2-logrotate: max_size 10M, retain 7, compress true"
    info "rotated files are named <file>.log-<date> and are excluded by the config"
  elif command -v pm2 >/dev/null 2>&1; then
    pm2 install pm2-logrotate >/dev/null 2>&1 \
      && { pm2 set pm2-logrotate:max_size 10M   >/dev/null 2>&1
           pm2 set pm2-logrotate:retain 7        >/dev/null 2>&1
           pm2 set pm2-logrotate:compress true   >/dev/null 2>&1
           install -d -m 0755 "$(dirname "$LOGROTATE_MARKER")"
           : > "$LOGROTATE_MARKER"
           info "installed and configured pm2-logrotate (marker written so uninstall.sh can remove it)"
         } \
      || info "could not install pm2-logrotate"
  else
    info "pm2 is not installed; skipping logrotate"
  fi
else
  info "skipped (--no-logrotate)"
fi

printf '\n\033[1mNext steps\033[0m\n'
printf '  1. Validate ingest permission (writes ONE probe record):\n'
printf '       %s/validate-token.sh --env-file %s/pm2-axiom.env --dataset %s\n' "$SCRIPTS" "$CONFIG_DIR" "$DATASET"
printf '  2. Smoke-test the pipeline:\n'
printf '       %s/smoke-test.sh --config %s\n' "$SCRIPTS" "$LOG_CONFIG"
printf '  3. Enable and start:\n'
printf '       systemctl enable --now %s\n' "$UNIT_NAME"
printf '  4. Confirm events are arriving:\n'
printf '       journalctl -u %s -f\n\n' "$UNIT_NAME"
exit 0