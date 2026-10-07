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
# pm2-logs-agent — undo an installation
#
# REQUIRES ROOT. Removes what scripts/install.sh created. Does NOT touch the
# Axiom dataset, the PM2 apps, or anything else install.sh did not create.
#
# Usage:
#   uninstall.sh [--config-dir PATH] [--lib-dir PATH] [--unit NAME]
#                [--vector-user NAME] [--pm2-home PATH]
#                [--keep-logrotate] [--purge-credentials] [--yes] [--plan]
#
# Options:
#   --config-dir PATH       default /etc/vector
#   --lib-dir PATH          default /opt/pm2-logs-agent
#   --unit NAME             default pm2-logs-agent
#   --vector-user NAME      for removing ACLs, default vector
#   --pm2-home PATH         for removing ACLs; detected from the unit if omitted
#   --keep-logrotate        do NOT uninstall pm2-logrotate
#   --purge-credentials     also delete pm2-axiom.env (the Axiom token)
#   --yes                   skip the confirmation prompt
#   --plan                  show what would be removed, change nothing
#
# pm2-logrotate is only uninstalled when this script installed it. If it was
# already present, it is left alone, because removing it would silently stop
# rotation on logs this skill does not own. Pass --keep-logrotate to force
# leaving it even if we installed it.
#
# Exit: 0 success, 1 a step failed, 2 usage error.

set -uo pipefail


CONFIG_DIR="/etc/vector"
LIB_DIR="/opt/pm2-logs-agent"
UNIT_NAME="pm2-logs-agent"
VECTOR_USER="vector"
PM2_HOME_DIR=""
KEEP_LOGROTATE="no"
PURGE_CREDS="no"
ASSUME_YES="no"
PLAN_ONLY="no"
MARKER="/var/lib/pm2-logs-agent/.installed-logrotate"

while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir)   CONFIG_DIR="${2:-}"; shift 2 ;;
    --lib-dir)      LIB_DIR="${2:-}"; shift 2 ;;
    --unit)         UNIT_NAME="${2:-}"; shift 2 ;;
    --vector-user)  VECTOR_USER="${2:-}"; shift 2 ;;
    --pm2-home)     PM2_HOME_DIR="${2:-}"; shift 2 ;;
    --keep-logrotate) KEEP_LOGROTATE="yes"; shift ;;
    --purge-credentials) PURGE_CREDS="yes"; shift ;;
    --yes)          ASSUME_YES="yes"; shift ;;
    --plan)         PLAN_ONLY="yes"; shift ;;
    -h|--help)      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'uninstall: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

info() { printf '   %s\n' "$1"; }

# ---------------------------------------------------------------------------
# what exists
# ---------------------------------------------------------------------------
UNIT_FILE="/etc/systemd/system/$UNIT_NAME.service"
LOG_CONFIG="$CONFIG_DIR/pm2-axiom.toml"
INSIGHTS_CONFIG="$CONFIG_DIR/host-insights.toml"
ENV_FILE="$CONFIG_DIR/pm2-axiom.env"
INSIGHTS_BIN="$LIB_DIR/host-insights.sh"

[ -n "$PM2_HOME_DIR" ] && [ -d "$PM2_HOME_DIR" ] || {
  PM2_HOME_DIR="$(grep -oE '/home/[A-Za-z0-9._-]+/\.pm2' "$UNIT_FILE" 2>/dev/null | head -1)"
}
[ -n "$PM2_HOME_DIR" ] && [ -d "$PM2_HOME_DIR" ] || PM2_HOME_DIR=""

UNIT_PRESENT=false; [ -f "$UNIT_FILE" ] && UNIT_PRESENT=true
LOG_PRESENT=false; [ -f "$LOG_CONFIG" ] && LOG_PRESENT=true
INS_PRESENT=false;  [ -f "$INSIGHTS_CONFIG" ] && INS_PRESENT=true
ENV_PRESENT=false;  [ -f "$ENV_FILE" ] && ENV_PRESENT=true
BIN_PRESENT=false;  [ -f "$INSIGHTS_BIN" ] && BIN_PRESENT=true
WE_INSTALLED_LOGROTATE=false; [ -f "$MARKER" ] && WE_INSTALLED_LOGROTATE=true

if [ "$PLAN_ONLY" = "yes" ]; then
  cat <<PLAN
pm2-logs-agent removal plan
============================

Will remove:
  systemd unit      : $UNIT_FILE [$UNIT_PRESENT]
  log config        : $LOG_CONFIG [$LOG_PRESENT]
  insights config   : $INSIGHTS_CONFIG [$INS_PRESENT]
  credentials       : $ENV_FILE [$ENV_PRESENT] $( [ "$PURGE_CREDS" = yes ] && echo "(will be DELETED, token lost)" || echo "(kept; pass --purge-credentials to remove)")
  insights script   : $INSIGHTS_BIN [$BIN_PRESENT]
  lib directory     : $LIB_DIR
  ACLs for user     : $VECTOR_USER on $PM2_HOME_DIR
  pm2-logrotate     : $( [ "$KEEP_LOGROTATE" = yes ] && echo "no (--keep-logrotate)" || { [ "$WE_INSTALLED_LOGROTATE" = true ] && echo "yes (this skill installed it)" || echo "no (was already present, left alone)"; } )

Will NOT touch:
  the Axiom dataset and its data
  the Axiom API token itself (revoke it at Axiom -> Settings -> Tokens)
  the Vector binary (use apt remove vector, or leave it)
  PM2 apps, their process list, and their logs
  /var/lib/vector checkpoints
PLAN
  exit 0
fi

[ "$(id -u)" = "0" ] || { printf 'uninstall: must run as root\n' >&2; exit 2; }

# ---------------------------------------------------------------------------
# confirm
# ---------------------------------------------------------------------------
if [ "$ASSUME_YES" != "yes" ]; then
  cat <<CONFIRM
This will REMOVE the pm2-logs-agent pipeline from this host.

  unit      : $UNIT_NAME.service
  configs   : $LOG_CONFIG $INSIGHTS_CONFIG
  script    : $INSIGHTS_BIN
  ACLs      : $VECTOR_USER on $PM2_HOME_DIR
$( [ "$PURGE_CREDS" = yes ] && echo "  credentials: $ENV_FILE WILL BE DELETED (Axiom token lost from this host)" )

The Axiom dataset and its data are NOT deleted. Log files are NOT deleted.

Type 'remove' to continue:
CONFIRM
  read -r answer
  [ "$answer" = "remove" ] || { printf 'aborted\n'; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. stop the service
# ---------------------------------------------------------------------------
if [ "$UNIT_PRESENT" = true ]; then
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 && info "stopped and disabled $UNIT_NAME" || info "could not stop $UNIT_NAME (may already be stopped)"
fi

# ---------------------------------------------------------------------------
# 2. unit file (keep the .bak if present)
# ---------------------------------------------------------------------------
if [ "$UNIT_PRESENT" = true ]; then
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  info "removed $UNIT_FILE"
  [ -f "$UNIT_FILE.bak" ] && info "restored unit available at $UNIT_FILE.bak" || true
fi

# ---------------------------------------------------------------------------
# 3. configs and credentials
# ---------------------------------------------------------------------------
for f in "$LOG_CONFIG" "$INSIGHTS_CONFIG"; do
  if [ -f "$f" ]; then
    if [ -f "$f.bak" ]; then
      mv -f "$f.bak" "$f"
      info "restored $f from backup"
    else
      rm -f "$f"
      info "removed $f"
    fi
  fi
done

if [ "$ENV_PRESENT" = true ]; then
  if [ "$PURGE_CREDS" = yes ]; then
    rm -f "$ENV_FILE"
    info "removed $ENV_FILE (Axiom token no longer on this host)"
  else
    info "kept $ENV_FILE (contains the Axiom token)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. lib dir
# ---------------------------------------------------------------------------
if [ "$BIN_PRESENT" = true ]; then
  rm -f "$INSIGHTS_BIN"
  rmdir "$LIB_DIR" 2>/dev/null && info "removed $LIB_DIR" || info "removed $INSIGHTS_BIN (kept $LIB_DIR: not empty)"
fi

# ---------------------------------------------------------------------------
# 5. ACLs
# ---------------------------------------------------------------------------
if command -v setfacl >/dev/null 2>&1 && [ -n "$PM2_HOME_DIR" ]; then
  setfacl -x "u:$VECTOR_USER" "$PM2_HOME_DIR/logs" 2>/dev/null && info "removed default ACL on $PM2_HOME_DIR/logs"
  setfacl -R -x "u:$VECTOR_USER" "$PM2_HOME_DIR" 2>/dev/null && info "removed recursive ACLs on $PM2_HOME_DIR"
  for d in "$PM2_HOME_DIR" "$(dirname "$PM2_HOME_DIR")" /root; do
    [ -d "$d" ] || continue
    case "$d" in /) continue ;; esac
    setfacl -x "u:$VECTOR_USER" "$d" 2>/dev/null && info "removed traverse ACL on $d"
  done
  info "review with: getfacl -p $PM2_HOME_DIR/logs"
else
  info "skipped ACL removal (setfacl unavailable or PM2_HOME unknown)"
fi

# ---------------------------------------------------------------------------
# 6. pm2-logrotate, only if we installed it
# ---------------------------------------------------------------------------
if [ "$KEEP_LOGROTATE" = "yes" ]; then
  info "kept pm2-logrotate (--keep-logrotate)"
elif [ "$WE_INSTALLED_LOGROTATE" = true ]; then
  command -v pm2 >/dev/null 2>&1 && pm2 uninstall pm2-logrotate >/dev/null 2>&1 \
    && info "uninstalled pm2-logrotate (this skill had installed it)" \
    || info "could not uninstall pm2-logrotate"
  rm -f "$MARKER"
else
  info "kept pm2-logrotate (it was already installed; not ours to remove)"
fi

# ---------------------------------------------------------------------------
# 7. data dir
# ---------------------------------------------------------------------------
info "left /var/lib/vector in place (checkpoints). Remove it manually if you"
info "want a clean slate: rm -rf /var/lib/vector"

printf '\n\033[1mRemaining\033[0m\n'
printf '  The Vector binary is still installed: %s\n' "$(command -v vector || echo 'not found')"
printf '  Remove it with: apt remove vector\n'
printf '  Revoke the Axiom token at Axiom -> Settings -> Tokens if this host is being decommissioned.\n'
exit 0