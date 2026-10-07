#!/usr/bin/env bash
# pm2-logs-agent — host-wide insights snapshot
#
# Emits EXACTLY ONE compact JSON object on stdout, then exits. Vector's exec
# source treats each line as one event and runs this on a schedule
# (scheduled.exec_interval_secs, default 1800 = every 30 minutes).
#
# Everything reported here is SERVER-WIDE, never scoped to the user running
# PM2. /proc/loadavg, /proc/meminfo and /proc/self/mounts are world-readable,
# so a non-root Vector service gets true host figures with no privilege
# escalation in the default case.
#
# DESIGN NOTES THAT MATTER
#
#  * Single line. The exec source splits on newlines, so pretty-printed JSON
#    would produce N bogus events.
#
#  * stderr must stay empty. Vector's exec source has include_stderr = true
#    BY DEFAULT, so any diagnostic on stderr becomes a phantom event in the
#    insights stream. Errors are reported inside the JSON payload instead.
#
#  * Capacity means the EFFECTIVE limit. Inside a container /proc/meminfo
#    reports the host's RAM and nproc reports the host's CPUs, so using those
#    as "capacity" would report a 2 GB container as using 3% of 64 GB. When
#    cgroup limits apply we use those instead and keep the host view under
#    "host".
#
#  * cgroup v1 emits memory.limit_in_bytes = 9223372036854771712 when
#    unlimited. That sentinel is detected and treated as "no limit", because
#    shipping it as a capacity would report 8 exabytes.
#
#  * Disk coverage is explicit. df/statvfs on a mount whose parent directory
#    lacks o+x fails for a non-root user. Rather than silently omitting those
#    rows, disk_coverage.failed lists them, so a partial snapshot is visible
#    in Axiom instead of inferred from a missing row.
#
# Configuration (all optional):
#   PM2_INSIGHTS_INTERVAL_SECS   cadence, default 1800
#   PM2_INSIGHTS_DISK_FS_EXCLUDE space-separated fs types to skip
#   PM2_INSIGHTS_MAX_DISKS       cap on filesystems reported, default 32
#
# Exit: always 0. Errors are reported in the payload, never on stderr.

set -uo pipefail

MAX_DISKS="${PM2_INSIGHTS_MAX_DISKS:-32}"
FS_EXCLUDE="${PM2_INSIGHTS_DISK_FS_EXCLUDE:-tmpfs devtmpfs proc sysfs cgroup cgroup2 ramfs squashfs devfs}"

# cgroup v1 "unlimited" sentinel (LONG_MAX rounded to page size).
CGROUP_V1_UNLIMITED="9223372036854771712"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

is_excluded_fs() {
  local fstype="$1" ex
  for ex in $FS_EXCLUDE; do
    [ "$fstype" = "$ex" ] && return 0
  done
  return 1
}

read_first_field() {
  [ -r "$1" ] || return 1
  awk -v n="$2" 'NR==1 {print $n; exit}' "$1" 2>/dev/null
}

json_num() {
  case "${1:-}" in
    ''|*[!0-9.]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

json_str() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$s"
}

# ---------------------------------------------------------------------------
# platform detection
# ---------------------------------------------------------------------------

SCOPE="host"
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -qaE '(docker|containerd|kubepods|lxc)' /proc/1/cgroup 2>/dev/null; then
  SCOPE="container"
fi

# ---------------------------------------------------------------------------
# CPU + load
# ---------------------------------------------------------------------------

CORES_TOTAL="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
LOAD1="$(read_first_field /proc/loadavg 1)"
LOAD5="$(read_first_field /proc/loadavg 2)"
LOAD15="$(read_first_field /proc/loadavg 3)"

# True CPU busy% from a short /proc/stat delta. Load average conflates CPU
# saturation with I/O wait, so a load-derived busy% is a guess.
CPU_BUSY_PCT="null"; CPU_USER_PCT="null"; CPU_SYS_PCT="null"; CPU_IOWAIT_PCT="null"

if [ -r /proc/stat ]; then
  read -r _lbl CPU_USER CPU_NICE CPU_SYS CPU_IDLE CPU_IOWAIT _rest < /proc/stat 2>/dev/null || true
  T1=$(( ${CPU_USER:-0} + ${CPU_NICE:-0} + ${CPU_SYS:-0} + ${CPU_IDLE:-0} + ${CPU_IOWAIT:-0} ))
  U1="${CPU_USER:-0}"; N1="${CPU_NICE:-0}"; S1="${CPU_SYS:-0}"; W1="${CPU_IOWAIT:-0}"
  sleep 0.2
  read -r _lbl CPU_USER CPU_NICE CPU_SYS CPU_IDLE CPU_IOWAIT _rest < /proc/stat 2>/dev/null || true
  T2=$(( ${CPU_USER:-0} + ${CPU_NICE:-0} + ${CPU_SYS:-0} + ${CPU_IDLE:-0} + ${CPU_IOWAIT:-0} ))
  U2="${CPU_USER:-0}"; N2="${CPU_NICE:-0}"; S2="${CPU_SYS:-0}"; W2="${CPU_IOWAIT:-0}"

  DT=$((T2 - T1))
  if [ "$DT" -gt 0 ]; then
    DBUSY=$(( (T2 - T1) - (W2 - W1) ))
    CPU_BUSY_PCT="$(awk -v b="$DBUSY" -v t="$DT" 'BEGIN{printf "%.1f", (b/t)*100}')"
    CPU_IOWAIT_PCT="$(awk -v w="$((W2 - W1))" -v t="$DT" 'BEGIN{printf "%.1f", (w/t)*100}')"
    CPU_SYS_PCT="$(awk -v s="$((S2 - S1))" -v t="$DT" 'BEGIN{printf "%.1f", (s/t)*100}')"
    CPU_USER_PCT="$(awk -v u="$((U2 - U1))" -v n="$((N2 - N1))" -v t="$DT" 'BEGIN{printf "%.1f", ((u+n)/t)*100}')"
  fi
fi

# ---------------------------------------------------------------------------
# cgroup limits (only meaningful when containerised)
# ---------------------------------------------------------------------------

CG_CPU_MAX="null"; CG_MEM_MAX="null"; CG_MEM_CUR="null"; CORES_EFFECTIVE="null"

# cgroup v2 (unified hierarchy)
if [ -r /sys/fs/cgroup/cpu.max ]; then
  CQ=""; CP=""
  read -r CQ CP < /sys/fs/cgroup/cpu.max 2>/dev/null || true
  if [ -n "$CQ" ] && [ "$CQ" != "max" ] && [ -n "$CP" ] && [ "$CP" -gt 0 ] 2>/dev/null; then
    CG_CPU_MAX="\"$CQ/$CP\""
    CORES_EFFECTIVE="$(awk -v q="$CQ" -v p="$CP" 'BEGIN{printf "%.2f", q/p}')"
  fi
fi
if [ -r /sys/fs/cgroup/memory.max ]; then
  MEMMAX="$(read_first_field /sys/fs/cgroup/memory.max 1)"
  [ -n "$MEMMAX" ] && [ "$MEMMAX" != "max" ] && CG_MEM_MAX="$(json_num "$MEMMAX")"
fi
[ -r /sys/fs/cgroup/memory.current ] && CG_MEM_CUR="$(json_num "$(read_first_field /sys/fs/cgroup/memory.current 1)")"

# cgroup v1 fallback
if [ "$CG_MEM_MAX" = "null" ] && [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
  MEMLIMIT="$(read_first_field /sys/fs/cgroup/memory/memory.limit_in_bytes 1)"
  # Detect the "unlimited" sentinel rather than reporting 8 exabytes.
  if [ -n "$MEMLIMIT" ] && [ "$MEMLIMIT" != "$CGROUP_V1_UNLIMITED" ] && [ "$MEMLIMIT" -gt 0 ] 2>/dev/null; then
    CG_MEM_MAX="$(json_num "$MEMLIMIT")"
  fi
fi
if [ "$CG_MEM_CUR" = "null" ] && [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
  CG_MEM_CUR="$(json_num "$(read_first_field /sys/fs/cgroup/memory/memory.usage_in_bytes 1)")"
fi
if [ "$CORES_EFFECTIVE" = "null" ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
  QUOTA="$(read_first_field /sys/fs/cgroup/cpu/cpu.cfs_quota_us 1)"
  PERIOD="$(read_first_field /sys/fs/cgroup/cpu/cpu.cfs_period_us 1)"
  if [ -n "$QUOTA" ] && [ "$QUOTA" != "-1" ] && [ -n "$PERIOD" ] && [ "$PERIOD" -gt 0 ] 2>/dev/null; then
    CG_CPU_MAX="\"$QUOTA/$PERIOD\""
    CORES_EFFECTIVE="$(awk -v q="$QUOTA" -v p="$PERIOD" 'BEGIN{printf "%.2f", q/p}')"
  fi
fi

# ---------------------------------------------------------------------------
# memory — server-wide
# ---------------------------------------------------------------------------

MEM_TOTAL="null"; MEM_AVAIL="null"
if [ -r /proc/meminfo ]; then
  MEM_TOTAL="$(json_num "$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo 2>/dev/null)")"
  MEM_AVAIL="$(json_num "$(awk '/^MemAvailable:/ {print $2 * 1024; exit}' /proc/meminfo 2>/dev/null)")"
fi

# Capacity is the effective limit, not the host total.
if [ "$SCOPE" = "container" ] && [ "$CG_MEM_MAX" != "null" ]; then
  MEM_CAPACITY="$CG_MEM_MAX"
else
  MEM_CAPACITY="$MEM_TOTAL"
fi

MEM_USED="null"; MEM_USED_PCT="null"
if [ "$MEM_CAPACITY" != "null" ] && [ "$MEM_AVAIL" != "null" ]; then
  # Inside a container /proc/meminfo MemAvailable is the HOST's, which is
  # routinely larger than the cgroup limit. Clamping to the effective
  # capacity keeps used_pct in 0..100 instead of reporting the nonsense
  # value -2664.4% observed on a 2 GB-capped container on a 128 GB host.
  MEM_USED="$(awk -v c="$MEM_CAPACITY" -v a="$MEM_AVAIL" 'BEGIN{u=c-a; if (u<0) u=0; if (u>c) u=c; printf "%d", u}')"
  MEM_USED_PCT="$(awk -v c="$MEM_CAPACITY" -v a="$MEM_AVAIL" 'BEGIN{u=c-a; if (u<0) u=0; if (u>c) u=c; if (c>0) printf "%.1f", (u/c)*100}')"
fi

# Load capacity is the effective CPU limit when one applies.
LOAD_CAPACITY="$CORES_EFFECTIVE"
[ "$LOAD_CAPACITY" = "null" ] && LOAD_CAPACITY="$(json_num "$CORES_TOTAL")"

LOAD_PCT="null"
if [ "$LOAD1" != "" ] && [ "$LOAD_CAPACITY" != "null" ]; then
  LOAD_PCT="$(awk -v l="$LOAD1" -v c="$LOAD_CAPACITY" 'BEGIN{ if (c>0) printf "%.1f", (l/c)*100 }')"
fi

# ---------------------------------------------------------------------------
# disks — one entry per real filesystem, never summed
# ---------------------------------------------------------------------------

DISKS_JSON=""
FAILED_MOUNTS=""
DISK_OK=0
DISK_FAIL=0

if command -v df >/dev/null 2>&1; then
  # `df` flag portability, all verified against coreutils and busybox:
  #
  #   -P and --output  -> mutually exclusive, rejected
  #   -T and --output  -> mutually exclusive, rejected
  #   -b               -> not a valid option on busybox
  #
  # So the byte-accurate form is `df -PT -B1`, which every implementation
  # accepts. That matters: plain `df -PT` reports 1024-blocks, so a "1.7T"
  # filesystem would be reported as 1777723916 bytes — off by 1024x. Sizes
  # are multiplied by 1024 below instead, which keeps the POSIX-parsing
  # fallback working on hosts where -B1 is unsupported.
  DF_B1="no"
  if df -PT -B1 >/dev/null 2>&1; then
    DF_B1="yes"
  fi

  # Mount points can contain spaces, so rejoin fields 7..N as the target.
  while read -r src fstype size used avail pct target; do
    [ -z "${target:-}" ] && continue
    case "$fstype" in
      tmpfs|devtmpfs|proc|sysfs|cgroup*|ramfs|squashfs|devfs) continue ;;
    esac
    is_excluded_fs "$fstype" && continue

    if [ "$DISK_OK" -ge "$MAX_DISKS" ]; then
      FAILED_MOUNTS="$FAILED_MOUNTS\"$target (max_disks_exceeded)\","
      DISK_FAIL=$((DISK_FAIL + 1))
      continue
    fi

    pct_num="$(printf '%s' "$pct" | tr -dc '0-9.')"

    # When df had no -B1, the three size columns are 1024-blocks.
    if [ "$DF_B1" = "yes" ]; then
      total_b="$size"; used_b="$used"; avail_b="$avail"
    else
      total_b="$(awk -v v="$size" 'BEGIN{printf "%.0f", v*1024}')"
      used_b="$(awk -v v="$used"  'BEGIN{printf "%.0f", v*1024}')"
      avail_b="$(awk -v v="$avail" 'BEGIN{printf "%.0f", v*1024}')"
    fi

    entry=$(printf '{"mount":%s,"fs_type":%s,"total_bytes":%s,"used_bytes":%s,"avail_bytes":%s,"used_pct":%s,"source":%s}' \
      "$(json_str "$target")" \
      "$(json_str "$fstype")" \
      "$(json_num "$total_b")" \
      "$(json_num "$used_b")" \
      "$(json_num "$avail_b")" \
      "$(json_num "$pct_num")" \
      "$(json_str "$src")")

    if [ -z "$DISKS_JSON" ]; then DISKS_JSON="$entry"; else DISKS_JSON="$DISKS_JSON,$entry"; fi
    DISK_OK=$((DISK_OK + 1))
  done < <(
    if [ "$DF_B1" = "yes" ]; then
      df -PT -B1 2>/dev/null | tail -n +2
    else
      df -PT 2>/dev/null | tail -n +2
    fi
  )
fi

[ -z "$DISKS_JSON" ] && DISKS_JSON=""
FAILED_MOUNTS="${FAILED_MOUNTS%,}"
[ -z "$FAILED_MOUNTS" ] && FAILED_MOUNTS="null"

# ---------------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------------

HOST_BLOCK=$(printf '{"cpus":%s,"load1":%s,"ram_total_bytes":%s}' \
  "$(json_num "$CORES_TOTAL")" "$(json_num "$LOAD1")" "$(json_num "$MEM_TOTAL")")

CGROUP_BLOCK="null"
if [ "$SCOPE" = "container" ]; then
  CGROUP_BLOCK=$(printf '{"cpu_max":%s,"effective_cpus":%s,"mem_max_bytes":%s,"mem_current_bytes":%s}' \
    "$CG_CPU_MAX" "$(json_num "$CORES_EFFECTIVE")" "$(json_num "$CG_MEM_MAX")" "$(json_num "$CG_MEM_CUR")")
fi

PAYLOAD="{\"kind\":\"host_insights\",\"scope\":\"$SCOPE\",\"interval_s\":$(json_num "${PM2_INSIGHTS_INTERVAL_SECS:-1800}"),\"host\":$HOST_BLOCK,\"cgroup\":$CGROUP_BLOCK,\"cpu\":{\"busy_pct\":$(json_num "$CPU_BUSY_PCT"),\"user_pct\":$(json_num "$CPU_USER_PCT"),\"system_pct\":$(json_num "$CPU_SYS_PCT"),\"iowait_pct\":$(json_num "$CPU_IOWAIT_PCT"),\"cores_total\":$(json_num "$CORES_TOTAL"),\"cores_effective\":$(json_num "$CORES_EFFECTIVE")},\"load\":{\"load1\":$(json_num "$LOAD1"),\"load5\":$(json_num "$LOAD5"),\"load15\":$(json_num "$LOAD15"),\"capacity_cpus\":$(json_num "$LOAD_CAPACITY"),\"pct_of_capacity\":$(json_num "$LOAD_PCT")},\"ram\":{\"total_bytes\":$(json_num "$MEM_CAPACITY"),\"host_total_bytes\":$(json_num "$MEM_TOTAL"),\"available_bytes\":$(json_num "$MEM_AVAIL"),\"used_bytes\":$(json_num "$MEM_USED"),\"used_pct\":$(json_num "$MEM_USED_PCT")},\"disks\":[$DISKS_JSON],\"disk_coverage\":{\"ok\":$DISK_OK,\"failed\":$DISK_FAIL,\"failed_mounts\":$FAILED_MOUNTS}}"

if command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -c . 2>/dev/null || printf '%s\n' "$PAYLOAD"
else
  # awk fallback for hosts without jq. The payload already has escaped
  # strings; this only guarantees single-line output.
  printf '%s\n' "$PAYLOAD" | tr -d '\n'
  printf '\n'
fi

exit 0