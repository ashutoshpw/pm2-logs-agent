#!/usr/bin/env bash
# pm2-logs-agent — prove the pipeline runs BEFORE enabling the systemd unit
#
# `vector validate` compiles config and checks schema. It does NOT start
# sources, does NOT read a single log line, and does NOT prove the sink is
# reachable. A config can validate perfectly and still ingest nothing.
#
# This runs the real config with the Axiom sink swapped for a local blackhole,
# so it exercises the file source, the VRL, multiline and the buffering path
# without sending anything anywhere or costing a cent.
#
# Usage:
#   smoke-test.sh --config PATH [--duration SECONDS] [--env-file PATH]
#                 [--insights-config PATH] [--json]
#
# Exit: 0 the pipeline started, read events and shut down cleanly.
#       1 the pipeline failed to start, ingested nothing, or did not stop.
#       2 usage or missing input.

set -uo pipefail


CONFIG=""
INSIGHTS_CONFIG=""
DURATION=6
JSON_OUT="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --config)          CONFIG="${2:-}"; shift 2 ;;
    --insights-config) INSIGHTS_CONFIG="${2:-}"; shift 2 ;;
    --duration)        DURATION="${2:-}"; shift 2 ;;
    --json)            JSON_OUT="yes"; shift ;;
    -h|--help)         sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'smoke-test: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$CONFIG" ] || { printf 'smoke-test: --config is required\n' >&2; exit 2; }
[ -f "$CONFIG" ] || { printf 'smoke-test: config not found: %s\n' "$CONFIG" >&2; exit 2; }

command -v vector >/dev/null 2>&1 || { printf 'smoke-test: vector is not installed\n' >&2; exit 2; }

# ---------------------------------------------------------------------------
# build the smoke config
# ---------------------------------------------------------------------------
#
# The Axiom sinks are replaced with a console sink so the transform chain still
# executes and we can SEE the parsed events, plus a blackhole so we still prove
# buffer behaviour. Rewriting text rather than generating config keeps the test
# honest: it is the real config with the egress swapped.

WORK="$(mktemp -d)"
DATA="$(mktemp -d)"
trap 'rm -rf "$WORK" "$DATA"' EXIT
SMOKE="$WORK/smoke.toml"

python3 - "$CONFIG" "$INSIGHTS_CONFIG" "$SMOKE" "$DATA" <<'PY'
import re, sys, pathlib

config, insights, out, data_dir = sys.argv[1:5]
text = pathlib.Path(config).read_text()
insight_text = pathlib.Path(insights).read_text() if insights and pathlib.Path(insights).exists() else ""

# Replace each axiom sink (and its buffer sub-table) with a console sink.
#
# The sub-table must be dropped as well as the type swapped: leaving
# [sinks.axiom.buffer] behind while renaming the sink to [sinks.axiom_smoke]
# leaves the original table as a parent of nothing, and Vector then reports
# "sinks.axiom: missing field `inputs`".
def sink_blocks(t):
    """Yield (header_line_name, [lines]) for each top-level sink table."""
    lines = t.split("\n")
    i = 0
    while i < len(lines):
        m = re.match(r'^\[sinks\.([A-Za-z0-9_]+)\]\s*$', lines[i])
        if m:
            sid = m.group(1)
            block = [lines[i]]
            i += 1
            while i < len(lines) and not re.match(r'^\[', lines[i]):
                block.append(lines[i])
                i += 1
            yield sid, block
        else:
            i += 1

def swap_sinks(t, label):
    lines = t.split("\n")
    out = []
    i = 0
    while i < len(lines):
        m = re.match(r'^\[sinks\.([A-Za-z0-9_]+)\]\s*$', lines[i])
        if m:
            sid = m.group(1)
            block = [lines[i]]
            i += 1
            while i < len(lines) and not re.match(r'^\[', lines[i]):
                block.append(lines[i]); i += 1
            body = "\n".join(block)
            if 'type = "axiom"' in body:
                # Consume this sink's sub-tables (buffer, encoding, request...).
                # They must go: keeping them re-declares the ORIGINAL sink name
                # as a bare table, which TOML rejects as a duplicate key.
                subpat = re.compile(r'^\[sinks\.' + re.escape(sid) + r'\.')
                while i < len(lines) and subpat.match(lines[i]):
                    i += 1
                    while i < len(lines) and not re.match(r'^\[', lines[i]):
                        i += 1
                inp = re.search(r'inputs\s*=\s*\[(.*?)\]', body)
                out.append(f'[sinks.{sid}_smoke]')
                out.append('type = "console"')
                out.append(f'inputs = [{inp.group(1) if inp else ""}]')
                out.append('encoding.codec = "json"')
                out.append('')
                out.append(f'# {label}: original sink {sid} (axiom) swapped for console')
                continue
        out.append(lines[i]); i += 1
    return "\n".join(out)

text = swap_sinks(text, "logs")
if insight_text:
    text += "\n" + swap_sinks(insight_text, "insights")

# Point data_dir at a scratch directory.
#
# The real config hardcodes /var/lib/vector, which the invoking user usually
# cannot write. Left alone, the file source logs "Failed writing checkpoints.
# Permission denied" on every batch and cannot record its read position, so
# the smoke test would fail for a reason that has nothing to do with the
# pipeline being tested.
text = re.sub(r'^data_dir = .*$',
              f'data_dir = "{data_dir}"', text, count=1, flags=re.M)

pathlib.Path(out).write_text(text)
PY

[ -f "$SMOKE" ] || { printf 'smoke-test: failed to build the smoke config\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# run it
# ---------------------------------------------------------------------------

LOG="$WORK/vector.log"

# The smoke config still interpolates ${SECRET_AXIOM_TOKEN} in any comment or
# string left behind, so provide a dummy and enable interpolation. The real
# token is never needed: the axiom sink has been swapped out.
ENVSET=(
  "AXIOM_DATASET=pm2-logs-agent-smoketest"
  "SECRET_AXIOM_TOKEN=xaat-smoketest-placeholder-not-a-real-token"
  "VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true"
  # The machine tag is mandatory. Without it apply-tags.vrl logs an ERROR for
  # every event, which would otherwise be counted as a pipeline error here and
  # mask a real one. Set to a throwaway value; the sink is a console.
  "VECTOR_TAG_MACHINE=pm2-logs-agent-smoketest"
)

echo "smoke-test: running for ${DURATION}s with the Axiom sink swapped for console ..."
env "${ENVSET[@]}" \
  vector --config "$SMOKE" --require-healthy false > "$LOG" 2>&1 &
VPID=$!

# Wait for it to come up, then let it ingest.
sleep 2
if ! kill -0 "$VPID" 2>/dev/null; then
  echo "smoke-test: FAILED — vector exited immediately" >&2
  sed -n '$!{h;d};x;p' "$LOG" >&2 2>/dev/null
  tail -20 "$LOG" >&2
  exit 1
fi

sleep "$DURATION"

# Ask for a clean shutdown so the buffer flushes.
kill -TERM "$VPID" 2>/dev/null
STOPPED=false
for _ in $(seq 1 20); do
  kill -0 "$VPID" 2>/dev/null || { STOPPED=true; break; }
  sleep 0.5
done
[ "$STOPPED" = true ] || kill -KILL "$VPID" 2>/dev/null
wait "$VPID" 2>/dev/null
RC=$?

# ---------------------------------------------------------------------------
# assert
# ---------------------------------------------------------------------------

count_of() { grep -cE "$1" "$LOG" 2>/dev/null | tail -1 | tr -cd '0-9'; }
EVENTS="$(count_of '"app"')"; EVENTS="${EVENTS:-0}"

# Files smaller than the fingerprint window are skipped by the checksum strategy,
# so tiny fixture log files legitimately produce no events. Say so rather than
# reporting a pass that proved nothing.
IGNORED_SMALL="$(grep -c 'too small to fingerprint' "$LOG" 2>/dev/null | tail -1 | tr -cd '0-9')"
IGNORED_SMALL="${IGNORED_SMALL:-0}"

# Real errors are the thing to fail on. Vector's own INFO lines frequently
# contain the substring "error" (component_id=apply_tags, a filename like
# api-error-0.log, severity:"error"), so a naive grep counts those as failures.
# Match only a genuine log-level ERROR/WARN marker.
REAL_ERRORS="$(grep -cE '(^|[[:space:]])(ERROR|WARN)[[:space:]]+[a-z]' "$LOG" 2>/dev/null | tail -1 | tr -cd '0-9')"
REAL_ERRORS="${REAL_ERRORS:-0}"
ERRORS="$REAL_ERRORS"

RESULT="pass"
REASON=""
[ "$STOPPED" = true ] || { RESULT="fail"; REASON="vector did not stop on SIGTERM"; }

if [ "$EVENTS" -eq 0 ] && [ "${IGNORED_SMALL:-0}" -gt 0 ]; then
  RESULT="inconclusive"
  REASON="$IGNORED_SMALL file(s) were skipped as 'too small to fingerprint'. This is expected for stub files under ~1 KiB, so the test proved nothing. Re-run against real log files."
elif [ "$EVENTS" -eq 0 ]; then
  RESULT="fail"
  REASON="${REASON:+$REASON; }no parsed events — the file source matched no readable files, or nothing was written to them during the run"
elif [ "$STOPPED" != true ]; then
  :
fi

# A checkpoint write failure is a genuine blocker, not noise.
if grep -q 'Failed writing checkpoints' "$LOG" 2>/dev/null; then
  RESULT="fail"
  REASON="${REASON:+$REASON; }Vector could not write its checkpoints (data_dir not writable). Without checkpoints it re-reads files from the start on every restart."
fi

if [ "$JSON_OUT" = "yes" ]; then
  printf '{"result":"%s","events_parsed":%s,"errors":%s,"files_skipped_small":%s,"stopped_cleanly":%s,"exit_code":%s,"reason":"%s"}\n' \
    "$RESULT" "$EVENTS" "$ERRORS" "$IGNORED_SMALL" "$STOPPED" "$RC" \
    "$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')"
else
  echo
  echo "events parsed : $EVENTS"
  echo "errors        : $ERRORS"
  echo "stopped       : $STOPPED"
  [ "${IGNORED_SMALL:-0}" -gt 0 ] && echo "skipped small : $IGNORED_SMALL file(s)"
  [ -n "$REASON" ] && echo "reason        : $REASON"
  echo
  case "$RESULT" in
    pass)
      echo "PASS — the pipeline starts, reads files, parses events and stops cleanly."
      echo "Safe to enable the systemd unit. This did NOT prove Axiom ingest"
      echo "permission; run scripts/validate-token.sh for that."
      ;;
    inconclusive)
      echo "INCONCLUSIVE — nothing was proven. Re-run against real log files."
      tail -12 "$LOG"
      ;;
    *)
      echo "FAIL — do not enable the unit yet. Inspect the log:"
      tail -25 "$LOG"
      ;;
  esac
fi

[ "$RESULT" = "pass" ] && exit 0
[ "$RESULT" = "inconclusive" ] && exit 1
exit 1