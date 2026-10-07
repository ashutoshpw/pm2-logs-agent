#!/usr/bin/env bash
# managed-by: pm2-logs-agent
#
# pm2-logs-agent — render a host-specific Vector config from the audit output
#
# That first line matters: scripts/audit-pm2-logs.sh looks for it to recognise
# its own config and stop reporting the skill's own file as a third-party
# collector reading the same PM2 logs. Without it every post-install audit
# raises a false critical duplicate-ingest finding.
#
# WHY THIS SCRIPT EXISTS
#
# Vector's remap transform has no include directive. VRL is a single compiled
# program with no file-loading facility, so `include "parse-app.vrl"` is a
# syntax error — verified on 0.59.0 as error[E203] "unexpected syntax token".
# The VRL files therefore have to be INLINED into the generated config.
#
# They stay separate files anyway, because a standalone .vrl can be unit-tested
# with `vector vrl` offline. This script is what bridges the two.
#
# Usage:
#   render-vector-config.sh --out /etc/vector/pm2-axiom.toml [options]
#
# Options:
#   --out PATH        destination file (default: stdout)
#   --pm2-home PATH   PM2_HOME for the include globs (default: $PM2_HOME or ~/.pm2)
#   --log-glob GLOB   repeatable; overrides the derived globs
#   --first-run       read_from="beginning" + ignore_older_secs (historical backfill)
#   --cutover         read_from="end" (tail only). This is the default.
#   --dataset NAME    Axiom dataset (default: pm2-logs)
#   --region DOMAIN   Axiom edge domain. OPTIONAL and off by default: when
#                     omitted no `region` line is written and Vector uses
#                     Axiom's default base domain (api.axiom.co), which is
#                     correct for most organizations. Pass it only for a
#                     non-default edge deployment.
#   --template PATH   base config (default: assets/vector.toml)
#   --insights       render the host-insights pipeline instead of the log
#                     pipeline (uses assets/vector-insights.toml)
#   --validate        run `vector validate` on the result when vector is present
#
# The Axiom token is NEVER written by this script. It is supplied at runtime
# through the env file. See references/risk-tiers.md.
#
# Exit: 0 ok, 1 usage/validation error, 2 missing input.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$REPO_DIR/assets"

OUT=""
PM2_HOME_DIR="${PM2_HOME:-$HOME/.pm2}"
FIRST_RUN="no"
DATASET="pm2-service-logs"
# Insights default to the SAME dataset. Every event carries a `kind` field, so a
# query filters rather than cross-referencing datasets. Pass
# --insights-dataset to split them.
INSIGHTS_DATASET=""
# Empty means "do not write a region line at all". Vector then uses Axiom's
# default base domain (api.axiom.co), which is right for most accounts.
REGION=""
TEMPLATE="$ASSETS_DIR/vector.toml"
INSIGHTS="no"
DO_VALIDATE="no"
LOG_GLOBS=()

die() { printf 'render-vector-config: %s\n' "$2" >&2; exit "${1:-1}"; }

# Resolve --insights into the template choice BEFORE validation, so the
# template existence check below tests the file actually used.
while [ $# -gt 0 ]; do
  case "$1" in
    --out)      OUT="${2:-}";      [ -n "$OUT" ] || die 1 "--out needs a path"; shift 2 ;;
    --pm2-home) PM2_HOME_DIR="${2:-}"; [ -n "$PM2_HOME_DIR" ] || die 1 "--pm2-home needs a path"; shift 2 ;;
    --log-glob) [ -n "${2:-}" ] || die 1 "--log-glob needs a pattern"; LOG_GLOBS+=("$2"); shift 2 ;;
    --insights-dataset) [ -n "${2:-}" ] || die 1 "--insights-dataset needs a value"; INSIGHTS_DATASET="$2"; shift 2 ;;
    --first-run) FIRST_RUN="yes"; shift ;;
    --cutover)  FIRST_RUN="no"; shift ;;
    --dataset)  DATASET="${2:-}";  [ -n "$DATASET" ] || die 1 "--dataset needs a value"; shift 2 ;;
    --region)   REGION="${2:-}";   [ -n "$REGION" ] || die 1 "--region needs a value"; shift 2 ;;
    --no-region) REGION=""; shift ;;
    --template) TEMPLATE="${2:-}"; [ -n "$TEMPLATE" ] || die 1 "--template needs a path"; shift 2 ;;
    --insights) INSIGHTS="yes"; shift ;;
    --validate) DO_VALIDATE="yes"; shift ;;
    -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die 1 "unknown option: $1" ;;
  esac
done

# --insights selects the host-insights pipeline unless --template overrode it.
if [ "$INSIGHTS" = "yes" ] && [ "$TEMPLATE" = "$ASSETS_DIR/vector.toml" ]; then
  TEMPLATE="$ASSETS_DIR/vector-insights.toml"
fi

[ -f "$TEMPLATE" ] || die 2 "template not found: $TEMPLATE"
[ -f "$ASSETS_DIR/parse-app.vrl" ] || die 2 "missing assets/parse-app.vrl"
[ -f "$ASSETS_DIR/apply-tags.vrl" ] || die 2 "missing assets/apply-tags.vrl"

# Axiom dataset names: 1-128 chars, ASCII alphanumeric plus hyphen only.
for d in "$DATASET" "$INSIGHTS_DATASET"; do
  [ -n "$d" ] || continue
  case "$d" in
    *[!A-Za-z0-9-]*) die 1 "invalid dataset '$d' (Axiom allows only A-Za-z0-9 and hyphen)" ;;
  esac
  [ "${#d}" -le 128 ] || die 1 "dataset '$d' exceeds 128 characters"
done

# Axiom edge domain: bare domain, no scheme, no path, no trailing slash.
case "$REGION" in
  http://*|https://*) die 1 "region must be a bare domain, got '$REGION'" ;;
  */)                 die 1 "region must not have a trailing slash, got '$REGION'" ;;
  */*)                die 1 "region must not contain a path, got '$REGION'" ;;
esac

if [ "${#LOG_GLOBS[@]}" -eq 0 ]; then
  LOG_GLOBS=("$PM2_HOME_DIR/logs/*.log")
  # The PM2 daemon log lives OUTSIDE logs/ and the usual glob misses it.
  [ -f "$PM2_HOME_DIR/pm2.log" ] && LOG_GLOBS+=("$PM2_HOME_DIR/pm2.log")
fi

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

PM2_ASSETS_DIR="$ASSETS_DIR" \
RENDER_TEMPLATE="$TEMPLATE" \
RENDER_GLOBS="$(printf '%s\n' "${LOG_GLOBS[@]}")" \
RENDER_REGION="$REGION" \
RENDER_DATASET="$DATASET" \
RENDER_FIRST_RUN="$FIRST_RUN" \
RENDER_INSIGHTS="$INSIGHTS" \
RENDER_INSIGHTS_DATASET="$INSIGHTS_DATASET" \
RENDER_DEST="$TMP_OUT" \
python3 - <<'PY'
import os, pathlib, re, sys

assets    = pathlib.Path(os.environ["PM2_ASSETS_DIR"])
template  = pathlib.Path(os.environ["RENDER_TEMPLATE"])
dest      = pathlib.Path(os.environ["RENDER_DEST"])
globs     = os.environ["RENDER_GLOBS"].splitlines()
region    = os.environ["RENDER_REGION"]
dataset   = os.environ["RENDER_DATASET"]
first_run = os.environ["RENDER_FIRST_RUN"] == "yes"
insights = os.environ["RENDER_INSIGHTS"] == "yes"
insights_dataset = os.environ.get("RENDER_INSIGHTS_DATASET", "")

DEFAULT_DATASET = "pm2-service-logs"

# The insights pipeline has no read_from / ignore_older_secs / include /
# exclude keys — those belong to the file source only. Substituting them there
# would fail with "matched 0 times".

def die(msg):
    print(f"render-vector-config: {msg}", file=sys.stderr)
    raise SystemExit(1)

def vrl_block(path, label):
    """Inline a .vrl file into a TOML ''' block safely."""
    body = path.read_text()
    if "'''" in body:
        die(f"{path.name} contains a triple-single-quote, which cannot be inlined")
    body = re.sub(r"\A\n", "", body)     # program must start at column 0
    body = re.sub(r"\n+\Z", "", body)    # never end on a quote next to '''
    return f"# >>> INLINE-BEGIN {label}\n{body}\n# <<< INLINE-END"

def sub1(pattern, repl, text, label, flags=0):
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n != 1:
        die(f"could not substitute {label} (pattern matched {n} times)")
    return new

if not globs:
    die("no include globs supplied")

out = template.read_text()

# Stamp the rendered config as ours so the audit does not flag the skill's own
# file as a third-party collector reading the same PM2 logs.
if "managed-by: pm2-logs-agent" not in out:
    out = re.sub(r'^(# pm2-logs-agent)',
                 r'# managed-by: pm2-logs-agent\n\1', out, count=1, flags=re.M)

for name, label in (("parse-app.vrl", "parse-app.vrl"),
                    ("apply-tags.vrl", "apply-tags.vrl")):
    marker = rf"# >>> INLINE-BEGIN {re.escape(label)}\n.*?# <<< INLINE-END"
    # re.search, not `marker in out`: marker is a regex with .*? in it, so a
    # plain substring test can never match and every pipeline looked broken.
    if not re.search(marker, out, re.S):
        # parse-app.vrl exists only in the log pipeline; the insights pipeline
        # legitimately has just the one marker.
        if label == "apply-tags.vrl":
            die(f"expected an inline marker for {label} in {template.name}")
        continue
    out = sub1(marker, lambda _m, b=vrl_block(assets / name, label): b, out, label, re.S)

if not insights:
    out = sub1(r'^read_from = .*$',
               'read_from = "beginning"' if first_run else 'read_from = "end"',
               out, "read_from", re.M)

    out = sub1(r'^ignore_older_secs = .*$',
               'ignore_older_secs = 86400' if first_run
               else '# ignore_older_secs unset: tail-only mode, no historical backfill',
               out, "ignore_older_secs", re.M)

# region is optional in every template. When --region is passed, a live
# `region` line is emitted; otherwise nothing is written and Vector uses Axiom's
# default base domain. The insights template keeps its region note in prose
# rather than as a `#region =` placeholder, so both forms are handled.
if region:
    if re.search(r'^#region = ', out, re.M):
        out = sub1(r'^#region = .*$', f'region = "{region}"', out, "region", re.M)
    elif re.search(r'^region = ', out, re.M):
        out = sub1(r'^region = .*$', f'region = "{region}"', out, "region", re.M)
    else:
        out = sub1(r'^(dataset = .*)$',
                   lambda m: f'region = "{region}"\n{m.group(1)}', out, "region insert", re.M)
if insights:
    # The insights template ships `dataset = "${AXIOM_DATASET}"`, so the env
    # file drives it and no substitution is needed. Only write a literal when
    # the caller explicitly asked for a separate insights dataset.
    if insights_dataset:
        out = sub1(r'^dataset = .*$',
                   f'dataset = "{insights_dataset}"', out, "insights dataset", re.M)
else:
    out = sub1(r'^dataset = .*$', f'dataset = "{dataset}"', out, "dataset", re.M)

if not insights:
    glob_lines = "".join(f'  "{g}",\n' for g in globs).rstrip(",\n")
    out = sub1(r'include = \[\n.*?\n\]',
               "include = [\n" + glob_lines + "\n]", out, "include globs", re.S)

    # The exclude block is tied to the example PM2_HOME; regenerate it so it
    # tracks whatever globs we were given.
    #
    # TWO patterns are required, not one. pm2-logrotate appends its dateFormat
    # (default YYYY-MM-DD_HH-mm-ss), so a rotated file is
    # api-out-0.log-2026-10-07_12-00-00 — which MATCHES the `*.log` include
    # glob. Only excluding `*.gz` lets every rotated file be re-uploaded, once
    # per run, forever.
    logdir = next((g.rsplit("/", 1)[0] for g in globs if g.endswith("*.log")), "/nonexistent")
    out = sub1(r'^exclude = \[\n.*?\n\]',
               'exclude = [\n'
               f'  "{logdir}/*.log-*.gz",\n'
               f'  "{logdir}/*.log.*.gz",\n'
               ']',
               out, "exclude globs", re.S | re.M)

dest.write_text(out)
PY

if [ -n "$OUT" ]; then
  install -m 0640 "$TMP_OUT" "$OUT"
  printf 'render-vector-config: wrote %s\n' "$OUT" >&2
else
  cat "$TMP_OUT"
fi

# --insights implies the insights template unless one was named explicitly.
if [ "$DO_VALIDATE" = "yes" ]; then
  if command -v vector >/dev/null 2>&1; then
    if vector validate --no-environment --deny-warnings "$TMP_OUT" >/dev/null 2>&1; then
      printf 'render-vector-config: vector validate OK\n' >&2
    else
      vector validate --no-environment --deny-warnings "$TMP_OUT" || true
      die 1 "generated config failed \`vector validate\`"
    fi
  else
    printf 'render-vector-config: vector not installed, skipping validation\n' >&2
  fi
fi