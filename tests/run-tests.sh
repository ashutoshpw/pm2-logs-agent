#!/usr/bin/env bash
# shellcheck disable=SC2015
#
# SC2015 is disabled for this file: `[ cond ] && ok ... || bad ...` is used
# throughout as a compact if/else. It is safe because ok() and bad() both always
# return 0, so `bad` cannot run after a successful `ok`.
#
# pm2-logs-agent — end-to-end tests
#
# Runs against the real pinned Vector binary in Docker when available, and
# degrades to structural checks when it is not. No network required beyond
# pulling the Vector image.
#
# Usage: tests/run-tests.sh [--skip-vector]
#
# Exit: 0 all tests passed, 1 one or more failures.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The skill payload lives under skills/<name>/ so the repo root can keep its own
# README, licence and CI without shipping them into every agent's install.
SKILL_DIR="$REPO_DIR/skills/pm2-logs-agent"
ASSETS="$SKILL_DIR/assets"
SCRIPTS="$SKILL_DIR/scripts"
SKILL_MD="$SKILL_DIR/SKILL.md"
FIXTURES="$REPO_DIR/tests/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SKIP_VECTOR="no"
[ "${1:-}" = "--skip-vector" ] && SKIP_VECTOR="yes"

# shellcheck source=/dev/null
. "$ASSETS/vector-version.env"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# vector runner
# ---------------------------------------------------------------------------
VECTOR_IMG=""
if command -v docker >/dev/null 2>&1; then
  VECTOR_IMG="$VECTOR_CI_IMAGE"
  # Pull both images BEFORE any test runs.
  #
  # Without this the first `docker run` triggers the pull, and the pull's
  # progress output lands on the same stdout as the VRL result. The first test
  # in the suite then reads pull noise instead of JSON and fails, while every
  # later test passes — a confusing, order-dependent failure seen in CI.
  for img in "$VECTOR_CI_IMAGE" "timberio/vector:${VECTOR_KNOWN_GOOD_FLOOR}-debian"; do
    [ -n "$img" ] && docker pull -q "$img" >/dev/null 2>&1
  done
fi
if [ "$SKIP_VECTOR" = "yes" ] || [ -z "$VECTOR_IMG" ]; then
  VECTOR_IMG=""
  printf '\033[33mnote: docker unavailable, skipping VRL/config validation tests\033[0m\n'
fi

# vrl <input.json> <program.vrl>  -> JSON on stdout
#
# Two things to get right here:
#
#  1. Both docker arguments must come before "$@". docker run treats the first
#     non-flag token as the image name, so a positional arriving first makes it
#     try to pull a local image named after the fixture.
#
#  2. `--print-object` emits timestamps in VRL's own literal syntax,
#     t'2026-...Z', which jq cannot parse ("Invalid literal at column 27").
#     Strip the t'...' wrapper so the output is plain JSON. This is only a test
#     harness concern: the real pipeline sends the event to Axiom, not to jq.
vrl_run() {
  [ -n "$VECTOR_IMG" ] || return 2
  docker run --rm --entrypoint /usr/bin/vector \
    -v "$REPO_DIR:/r:ro" "$VECTOR_IMG" \
    vrl -i "/r/tests/fixtures/inputs/$1" -p "/r/skills/pm2-logs-agent/assets/$2" --print-object 2>&1 \
    | grep -v 'INFO vector' \
    | sed -E "s/t'([^']*)'/\"\1\"/g"
}

# validate <toml> [image-tag]
validate_run() {
  [ -n "$VECTOR_IMG" ] || return 2
  local img="$VECTOR_IMG"
  [ -n "${2:-}" ] && img="timberio/vector:$2-debian"
  docker run --rm --entrypoint /usr/bin/vector -v "$WORK:/x" "$img" \
    validate --no-environment -d "/x/$1" 2>&1 | grep -v 'INFO vector'
}

# ===========================================================================
group "parse-app.vrl — filename parsing"
# ===========================================================================
if [ -n "$VECTOR_IMG" ]; then
  declare -A EXPECT_APP=(
    [event-out.json]="api"
    [event-error.json]="api"
    [event-merge.json]="worker"
    [event-dashed-app.json]="my-out-app"
    [event-custom-path.json]="api"
    [event-daemon.json]="pm2-daemon"
  )
  for f in "${!EXPECT_APP[@]}"; do
    out="$(vrl_run "$f" parse-app.vrl)"
    want="${EXPECT_APP[$f]}"
    if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      # Distinguish "VRL produced no JSON" from "VRL produced the wrong app".
      # Confusing these is what made a docker pull race look like a VRL bug.
      bad "$f -> app" "no JSON from vector vrl: $(printf '%s' "$out" | head -2)"
      continue
    fi
    got="$(printf '%s' "$out" | jq -r '.app' 2>/dev/null)"
    if [ "$got" = "$want" ]; then ok "$f -> app=$want"; else bad "$f -> app" "expected '$want', got '$got'"; fi
  done

  # severity derives from the -error- segment
  out="$(vrl_run event-error.json parse-app.vrl)"
  [ "$(printf '%s' "$out" | jq -r '.severity')" = "error" ] \
    && ok "error stream -> severity=error" || bad "error stream severity"
  out="$(vrl_run event-out.json parse-app.vrl)"
  [ "$(printf '%s' "$out" | jq -r '.severity')" = "info" ] \
    && ok "out stream -> severity=info" || bad "out stream severity"

  # _time must be a field path, present on the event
  out="$(vrl_run event-out.json parse-app.vrl)"
  if printf '%s' "$out" | jq -e 'has("_time")' >/dev/null 2>&1; then
    ok "_time present on event (field path, not a local var)"
  else
    bad "_time missing" "a bare '_time = ...' would compile but never reach the event"
  fi
  if printf '%s' "$out" | jq -e 'has("timestamp")' >/dev/null 2>&1; then
    bad "timestamp not deleted" "expected it renamed to _time"
  else
    ok "timestamp removed after rename"
  fi
else
  printf '  SKIP (no docker)\n'
fi

# ===========================================================================
group "apply-tags.vrl — tagging"
# ===========================================================================
if [ -n "$VECTOR_IMG" ]; then
  # Same sed as vrl_run: strip VRL's t'...' timestamp literal so jq can parse it.
  tag_run() {
    # "$@" holds extra -e VECTOR_TAG_* flags and must sit with the other -e
    # options BEFORE the image name; after the image docker passes them to VRL,
    # which then sees no environment and emits untagged events.
    docker run --rm --entrypoint /usr/bin/vector \
      -e VECTOR_TAG_MACHINE=web-01 "$@" \
      -v "$REPO_DIR:/r:ro" "$VECTOR_IMG" \
      vrl -i /r/tests/fixtures/inputs/event-out.json -p /r/skills/pm2-logs-agent/assets/apply-tags.vrl --print-object 2>&1 \
      | grep -v 'INFO vector' \
      | sed -E "s/t'([^']*)'/\"\1\"/g"
  }

  out="$(tag_run -e VECTOR_TAG_PUBLIC_IP=203.0.113.42 -e VECTOR_TAG_TAILSCALE_IP=100.101.102.103 -e VECTOR_TAG_ROLE=api)"
  for pair in "machine:web-01" "public_ip:203.0.113.42" "tailscale_ip:100.101.102.103" "role:api"; do
    k="${pair%%:*}"; v="${pair#*:}"
    got="$(printf '%s' "$out" | jq -r ".$k" 2>/dev/null)"
    [ "$got" = "$v" ] && ok "$k=$v" || bad "$k" "expected '$v', got '$got'"
  done

  # optional tags absent -> fields absent, NOT empty strings
  out="$(tag_run)"
  absent="$(printf '%s' "$out" | jq -r 'has("public_ip")' 2>/dev/null)"
  [ "$absent" = "false" ] && ok "absent optional tag produces no field" || bad "optional tag present when unset"

  # reserved-name collision must be refused, not applied
  out="$(tag_run -e VECTOR_TAG_SERVICE=evil)"
  sv="$(printf '%s' "$out" | jq -r '.service' 2>/dev/null)"
  if [ "$sv" = "null" ] || [ -z "$sv" ]; then
    ok "reserved tag VECTOR_TAG_SERVICE refused"
  else
    bad "reserved tag applied" "service='$sv'"
  fi
else
  printf '  SKIP (no docker)\n'
fi

# ===========================================================================
group "host-insights.sh — snapshot shape"
# ===========================================================================
out="$("$ASSETS/host-insights.sh" 2>"$WORK/insights.err")"
if [ -s "$WORK/insights.err" ]; then
  bad "stderr must be empty" "exec source has include_stderr=true by default; $(wc -c < "$WORK/insights.err") bytes leaked"
else
  ok "stderr empty"
fi
lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
[ "$lines" = "1" ] && ok "single line of output" || bad "output not single-line" "$lines lines"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "valid JSON"; else bad "invalid JSON"; fi

for key in kind scope cpu load ram disks disk_coverage; do
  if printf '%s' "$out" | jq -e "has(\"$key\")" >/dev/null 2>&1; then ok "has $key"; else bad "missing $key"; fi
done

# load + ram must carry both current AND capacity
printf '%s' "$out" | jq -e '.load.load1 != null and .load.capacity_cpus != null' >/dev/null 2>&1 \
  && ok "load has current + capacity" || bad "load missing current/capacity"
printf '%s' "$out" | jq -e '.ram.used_bytes != null and .ram.total_bytes != null' >/dev/null 2>&1 \
  && ok "ram has used + capacity" || bad "ram missing used/capacity"

# at least one real filesystem
dc="$(printf '%s' "$out" | jq '.disks | length')"
[ "$dc" -ge 1 ] 2>/dev/null && ok "disks reported ($dc)" || bad "no disks reported"
printf '%s' "$out" | jq -e 'all(.disks[]; has("mount") and has("used_pct") and has("total_bytes"))' >/dev/null 2>&1 \
  && ok "each disk has mount/used_pct/total_bytes" || bad "disk shape incomplete"

# used_pct must be sane, not negative
printf '%s' "$out" | jq -e 'all(.disks[]; .used_pct >= 0 and .used_pct <= 100)' >/dev/null 2>&1 \
  && ok "disk used_pct within 0..100" || bad "disk used_pct out of range"
printf '%s' "$out" | jq -e '(.ram.used_pct // 0) >= 0 and (.ram.used_pct // 0) <= 100' >/dev/null 2>&1 \
  && ok "ram used_pct within 0..100" || bad "ram used_pct out of range"

# no jq fallback still emits one line
if ( PATH="/nonexistent-bin-dir:$PATH" bash "$ASSETS/host-insights.sh" ) >"$WORK/nojq.json" 2>/dev/null; then
  nl="$(wc -l < "$WORK/nojq.json" | tr -d ' ')"
  [ "$nl" = "1" ] && ok "jq-less fallback stays single-line" || bad "jq-less fallback multiline" "$nl lines"
else
  ok "jq-less fallback skipped (awk unavailable)"
fi

# ===========================================================================
if [ -n "$VECTOR_IMG" ]; then
  "$SCRIPTS/render-vector-config.sh" --pm2-home /home/deploy/.pm2 --out "$WORK/tk-log.toml" >/dev/null 2>&1
  "$SCRIPTS/render-vector-config.sh" --insights --out "$WORK/tk-ins.toml" >/dev/null 2>&1

  # A missing variable MUST abort config load. Without this, Vector ships the
  # literal placeholder as the token and 401s every batch, silently.
  r="$(docker run --rm --entrypoint /usr/bin/vector -v "$WORK:/x" \
        -e AXIOM_DATASET=pm2-service-logs \
        "$VECTOR_IMG" --dangerously-allow-env-var-interpolation \
        validate --no-environment -d "/x/tk-log.toml" 2>&1)"
  if printf '%s' "$r" | grep -q 'Missing environment variable'; then
    ok "missing token aborts config load (fails fast, no silent 401 loop)"
  else
    bad "missing token did not fail loudly" "$(printf '%s' "$r" | head -3)"
  fi

  r="$(docker run --rm --entrypoint /usr/bin/vector -v "$WORK:/x" \
        -e AXIOM_DATASET=pm2-service-logs -e SECRET_AXIOM_TOKEN=xaat-placeholder \
        "$VECTOR_IMG" --dangerously-allow-env-var-interpolation \
        validate --no-environment -d "/x/tk-log.toml" 2>&1)"
  if printf '%s' "$r" | grep -q 'Validated'; then
    ok "token present -> config validates"
  else
    bad "valid token rejected" "$(printf '%s' "$r" | head -3)"
  fi

  # Once interpolation is on, EVERY dollar-brace sequence is substituted,
  # including inside comments. A literal ${VAR} in a comment aborts the whole
  # config; a doubled $${...} escapes.
  real="$(grep -ohE '^\s*[a-z_]+ = "\$\{[A-Za-z_][A-Za-z0-9_]*\}"' "$ASSETS/vector.toml" "$ASSETS/vector-insights.toml" 2>/dev/null | wc -l)"
  comment_hits="$(grep -ohE '^\s*#.*\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$ASSETS/vector.toml" "$ASSETS/vector-insights.toml" 2>/dev/null | grep -vc '\$\$' || true)"
  [ "${comment_hits:-0}" -eq 0 ] \
    && ok "no unescaped \${...} in config comments ($real real interpolations)" \
    || bad "$comment_hits unescaped \${...} in comments will abort config load"
fi

group "multiline patterns actually match"
# ---------------------------------------------------------------------------
# A TOML literal string does not interpret backslashes, so '\\s' reaches VRL as a
# literal backslash-s and matches nothing. `vector validate` passes either way,
# because both are syntactically valid regexes — only a behavioural test catches
# it.
#
# Separately: with mode = "continue_through", a line matching neither pattern is
# swallowed as a continuation. So start_pattern MUST match ordinary log lines,
# or multiline silently drops all normal logging.

if [ -n "$VECTOR_IMG" ]; then
  ml_start="$(grep -oE "^start_pattern = '.*'" "$ASSETS/vector.toml" | head -1 | sed "s/^start_pattern = '//;s/'$//")"
  ml_cond="$(grep -oE "^condition_pattern = '.*'" "$ASSETS/vector.toml" | head -1 | sed "s/^condition_pattern = '//;s/'$//")"
  printf '{"line":"x"}' > "$WORK/mlprobe.json"
  # Raw-string literals (r"...") so no shell or VRL escaping mangles the regexes.
  python3 - "$WORK/mlprobe.vrl" "$ml_start" "$ml_cond" <<'PYEOF'
import sys, pathlib
path, start, cond = sys.argv[1:4]
q = chr(39)  # VRL regex literals are single-quoted: r'...'
body = [
    'frame  = "    at foo (/app/x.js:1:1)"',
    'errl   = "Error: boom"',
    'plain  = "req 0 handled in 0ms"',
    # match() returns a boolean, which is what this assertion needs. parse_regex
    # returns only the NAMED capture groups, so it yields {} either way and
    # cannot distinguish a match from a non-match.
    # match() is infallible for a string subject, so no error tuple.
    "a = match(plain, r" + q + start + q + ")",
    "b = match(frame, r" + q + cond + q + ")",
    "c = match(errl,  r" + q + cond + q + ")",
    '. = merge(., {"start_plain": a, "cond_frame": b, "cond_err": c})',
]
pathlib.Path(path).write_text("\n".join(body) + "\n")
PYEOF
  mlout="$(docker run --rm --entrypoint /usr/bin/vector -v "$WORK:/w:ro" "$VECTOR_IMG"             vrl -i /w/mlprobe.json -p /w/mlprobe.vrl -o 2>&1 | grep -v 'INFO vector')"
  if printf '%s' "$mlout" | jq -e . >/dev/null 2>&1; then
    [ "$(printf '%s' "$mlout" | jq -r '.start_plain')" = "true" ]       && ok "start_pattern matches an ordinary log line"       || bad "start_pattern misses normal lines; continue_through would drop all normal logs"
    [ "$(printf '%s' "$mlout" | jq -r '.cond_frame')" = "true" ]       && ok "condition_pattern matches an indented stack frame"       || bad "condition_pattern misses '    at foo (...)'; check for double-escaped backslashes"
    [ "$(printf '%s' "$mlout" | jq -r '.cond_err')" = "true" ]       && ok "condition_pattern matches an Error line (traces join)"       || bad "condition_pattern does not continue past an Error line"
  else
    bad "multiline probe failed to compile" "$(printf '%s' "$mlout" | head -5)"
  fi
fi

group "rotation exclude covers rotated filenames"
# pm2-logrotate appends dateFormat, so api-out-0.log-2026-10-07_12-00-00 is a
# rotated file that MATCHES the *.log include glob. Without a matching exclude,
# every rotated archive is re-uploaded on every run.
"$SCRIPTS/render-vector-config.sh" --pm2-home /home/deploy/.pm2 --out "$WORK/rot.toml" >/dev/null 2>&1
rot_result="$(python3 - "$WORK/rot.toml" <<'PYEOF'
import re, sys, pathlib, fnmatch
text = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'^include = \[\n(.*?)\n\]', text, re.S | re.M)
incs = re.findall(r'"([^"]+)"', m.group(1)) if m else []
m = re.search(r'^exclude = \[\n(.*?)\n\]', text, re.S | re.M)
excs = re.findall(r'"([^"]+)"', m.group(1)) if m else []
base = "/home/deploy/.pm2/logs"
bad = []
live = f"{base}/api-out-0.log"
if not any(fnmatch.fnmatch(live, p) for p in incs) or any(fnmatch.fnmatch(live, p) for p in excs):
    bad.append("live log file is not ingested")
for name, label in [
    (f"{base}/api-out-0.log-2026-10-07_12-00-00", "rotated (pm2-logrotate dateFormat)"),
    (f"{base}/api-out-0.log-2026-10-07_12-00-00.gz", "rotated + compressed"),
    (f"{base}/api-out-0.log.1", "rotated (.N suffix)"),
]:
    matched = any(fnmatch.fnmatch(name, p) for p in incs)
    if matched and not any(fnmatch.fnmatch(name, p) for p in excs):
        bad.append(f"{label} would be re-uploaded on every run")
print("|".join(bad) if bad else "clean")
PYEOF
)"
if [ "$rot_result" = "clean" ]; then
  ok "live files ingested, rotated archives excluded"
else
  bad "rotation exclude incomplete" "$rot_result"
fi

group "validate-token.sh"
"$SCRIPTS/validate-token.sh" --token xaat-abcdefghijklmnopqrstuvwxyz012345 --dry-run >/dev/null 2>&1 \
  && ok "dry run with a well-formed token" || bad "dry run failed"
"$SCRIPTS/validate-token.sh" --token NOTATOKEN --dry-run >/dev/null 2>&1 \
  && bad "accepted a malformed token in dry run" || ok "rejects a malformed token"
# The token must never appear in output.
out="$("$SCRIPTS/validate-token.sh" --token xaat-SECRETVALUESECRETVALUE1234 --dry-run 2>&1)"
if printf '%s' "$out" | grep -q 'SECRETVALUE'; then
  bad "token value leaked into output"
else
  ok "token value never printed"
fi
# Region decides the URL path; the two shapes are not interchangeable.
#
# Isolate from ambient AXIOM_* so the assertions do not depend on the machine
# running the suite. Validate-token.sh only reads those names from an --env-file,
# never from the ambient environment, so this is belt-and-braces — but an
# ambient export previously made this group fail intermittently.
vt() { env -u AXIOM_REGION -u AXIOM_DATASET -u AXIOM_INSIGHTS_DATASET \
        "$SCRIPTS/validate-token.sh" "$@"; }

out="$(vt --token xaat-abcdefghijklmnopqrstuvwxyz012345 --dry-run 2>&1)"
if printf '%s' "$out" | grep -q 'api\.axiom\.co/v1/datasets/'; then
  ok "default domain uses /v1/datasets/<ds>/ingest"
else
  bad "wrong default ingest path" "$(printf '%s' "$out" | grep 'ingest url')"
fi

out="$(vt --token xaat-abcdefghijklmnopqrstuvwxyz012345 --region us-east-1.aws.edge.axiom.co --dry-run 2>&1)"
if printf '%s' "$out" | grep -q 'us-east-1\.aws\.edge\.axiom\.co/v1/ingest/'; then
  ok "edge region uses /v1/ingest/<ds>"
else
  bad "wrong edge ingest path" "$(printf '%s' "$out" | grep 'ingest url')"
fi

group "smoke-test.sh"
# It must rewrite data_dir, or the file source cannot checkpoint and the test
# fails for a reason unrelated to what it is testing.
grep -q 'data_dir = "{data_dir}"' "$SCRIPTS/smoke-test.sh" \
  && ok "smoke-test rewrites data_dir to a writable scratch dir" || bad "smoke-test leaves data_dir as /var/lib/vector"
# The axiom sink sub-tables must be dropped too, or the rewritten config has a
# duplicate-key error.
grep -q 'subpat = re.compile' "$SCRIPTS/smoke-test.sh" \
  && ok "smoke-test drops sink sub-tables when swapping the sink" || bad "smoke-test leaves [sinks.x.buffer] behind"
bash -n "$SCRIPTS/smoke-test.sh" 2>/dev/null && ok "smoke-test syntax" || bad "smoke-test syntax"

group "install.sh / uninstall.sh"
for s in install uninstall; do
  bash -n "$SCRIPTS/$s.sh" 2>/dev/null && ok "$s.sh syntax" || bad "$s.sh syntax"
done
# The installer must NOT enable the unit: enabling a unit that crash-loops on a
# missing token is the exact failure the smoke test exists to prevent. Only look
# for a REAL invocation — the string also appears inside informational text and
# inside --plan output.
if grep -vE '^\s*(#|info |printf |cat <<|  )' "$SCRIPTS/install.sh" \
     | grep -qE '^\s*systemctl enable'; then
  bad "install.sh enables the unit; it must leave that to the operator"
else
  ok "install.sh does not enable the unit"
fi
grep -q 'setfacl -d -m' "$SCRIPTS/install.sh" \
  && ok "installer sets a DEFAULT ACL so rotated files stay readable" \
  || bad "installer omits the default ACL; files created by rotation become unreadable"
grep -q 'traverse\|--x' "$SCRIPTS/install.sh" \
  && ok "installer grants traverse (--x) on parent directories" \
  || bad "installer omits traverse ACL; the log files cannot be reached at all"
grep -q 'installed-logrotate' "$SCRIPTS/install.sh" "$SCRIPTS/uninstall.sh" \
  && ok "logrotate ownership is tracked so uninstall only removes what we installed" \
  || bad "no marker for pm2-logrotate ownership"
"$SCRIPTS/uninstall.sh" --plan --pm2-home /tmp >/dev/null 2>&1 \
  && ok "uninstall --plan runs" || bad "uninstall --plan failed"
"$SCRIPTS/install.sh" --pm2-home /tmp --env-file "$ASSETS/pm2-axiom.env.example" --plan >/dev/null 2>&1 \
  && ok "install --plan runs" || bad "install --plan failed"

group "single default dataset"
# Both pipelines write to pm2-service-logs by default; insights are separated
# by the kind field, not by a second dataset.
grep -qE '^AXIOM_DATASET=pm2-service-logs$' "$ASSETS/pm2-axiom.env.example" \
  && ok "env example defaults to pm2-service-logs" || bad "env example default dataset changed"
# shellcheck disable=SC2016  # a literal ${...} is exactly what we assert on
grep -q 'dataset = "\${AXIOM_DATASET}"' "$ASSETS/vector-insights.toml" \
  && ok "insights defaults to the env file's dataset" || bad "insights dataset not shared by default"
grep -q '\.kind = "pm2_log"' "$ASSETS/parse-app.vrl" \
  && ok "log events carry kind=pm2_log" || bad "no kind field on log events"
# The script builds JSON by hand inside a double-quoted shell string, so the
# literal in the source is \"kind\":\"host_insights\". Assert on the runtime
# output instead, which is what actually matters.
grep -q 'host_insights' "$ASSETS/host-insights.sh" \
  && ok "insight events carry kind=host_insights" || bad "no kind field on insight events"
"$ASSETS/host-insights.sh" 2>/dev/null | jq -e '.kind == "host_insights"' >/dev/null 2>&1 \
  && ok "runtime: insights event emits kind=host_insights" || bad "insights event kind wrong at runtime"
"$SCRIPTS/render-vector-config.sh" --insights --insights-dataset pm2-other --out "$WORK/split.toml" >/dev/null 2>&1
grep -qE '^dataset = "pm2-other"' "$WORK/split.toml" \
  && ok "--insights-dataset splits the datasets on request" || bad "--insights-dataset ignored"
# Retention must not be managed by the skill.
if grep -qriE 'retention' "$ASSETS/pm2-axiom.env.example" | grep -qv 'deliberately NOT managed'; then :; fi

group "merged config (log + insights in one process)"
# Component ids share a namespace across merged configs, and data_dir is a
# global option, so a repeat or a collision is a duplicate-key error.
"$SCRIPTS/render-vector-config.sh" --pm2-home /home/deploy/.pm2 --out "$WORK/ml.toml" >/dev/null 2>&1
"$SCRIPTS/render-vector-config.sh" --insights --out "$WORK/mi.toml" >/dev/null 2>&1
if [ "$(grep -c '^data_dir' "$WORK/mi.toml")" = "0" ]; then
  ok "insights config declares no data_dir (global, already set by the log config)"
else
  bad "insights config repeats data_dir; merging yields a duplicate-key error"
fi
log_ids="$(grep -oE '^\[(sources|transforms|sinks)\.[A-Za-z0-9_]+\]' "$WORK/ml.toml" | sort)"
ins_ids="$(grep -oE '^\[(sources|transforms|sinks)\.[A-Za-z0-9_]+\]' "$WORK/mi.toml" | sort)"
overlap="$(comm -12 <(printf '%s\n' "$log_ids") <(printf '%s\n' "$ins_ids") | grep -v . || true)"
if [ -z "$overlap" ]; then
  ok "no component-id collisions between the two configs"
else
  bad "component ids collide" "$overlap"
fi
cat "$WORK/ml.toml" "$WORK/mi.toml" > "$WORK/merged.toml"
if [ -n "$VECTOR_IMG" ]; then
  r="$(docker run --rm --entrypoint /usr/bin/vector -v "$WORK:/x" \
        -e AXIOM_DATASET=pm2-service-logs -e SECRET_AXIOM_TOKEN=xaat-placeholder \
        "$VECTOR_IMG" --dangerously-allow-env-var-interpolation \
        validate --no-environment -d /x/merged.toml 2>&1)"
  printf '%s' "$r" | grep -q 'Validated' \
    && ok "merged config validates (as the unit runs it)" || bad "merged config invalid" "$(printf '%s' "$r" | head -4)"
fi

group "audit collector attribution"
# The audit must report per-unit detail, and must not mistake an unrelated
# vector.service for the skill's own collector.
grep -q 'collector_units' "$SCRIPTS/audit-pm2-logs.sh" \
  && ok "audit enumerates collector units" || bad "audit still only probes the binary"
grep -q 'managed_unit' "$SCRIPTS/audit-pm2-logs.sh" \
  && ok "audit tracks the unit that runs our config" || bad "audit has no managed-unit concept"
grep -q 'managed-by: pm2-logs-agent' "$SCRIPTS/audit-pm2-logs.sh" \
  && ok "audit recognises its own config (managed-by marker)" || bad "audit will false-positive on its own config"
grep -qE "'/examples'|-path '\*/examples'" "$SCRIPTS/audit-pm2-logs.sh" \
  && ok "audit prunes /etc/vector/examples from the config count" || bad "audit counts example configs"
grep -q 'unstable_restarts' "$SCRIPTS/audit-pm2-logs.sh" \
  && ok "audit extracts restart counts" || bad "audit cannot see restart loops"
grep -q 'logs.unreadable_by_collector' "$SCRIPTS/audit-pm2-logs.sh" \
  && ok "audit verifies the collector can read the logs" || bad "audit does not test log readability"
grep -q 'orphan_files' "$SCRIPTS/audit-pm2-logs.sh" \
  && ok "audit reports orphan log files" || bad "audit cannot map files to apps"

group "render-vector-config.sh"
# ===========================================================================
"$SCRIPTS/render-vector-config.sh" --pm2-home /home/deploy/.pm2 --out "$WORK/logs.toml" >/dev/null 2>&1
[ -f "$WORK/logs.toml" ] && ok "renders log config" || bad "log render failed"

"$SCRIPTS/render-vector-config.sh" --insights --out "$WORK/insights.toml" >/dev/null 2>&1
[ -f "$WORK/insights.toml" ] && ok "renders insights config" || bad "insights render failed"

# VRL must be INLINED, not referenced (VRL has no include directive)
grep -q 'include "apply-tags.vrl"' "$WORK/logs.toml" && bad "VRL not inlined" || ok "VRL inlined (no include directive)"
grep -q 'parse_regex(string(.file)' "$WORK/logs.toml" && ok "parse-app.vrl body present" || bad "parse-app.vrl missing"

# region is OPTIONAL and off by default
grep -qE '^region = ' "$WORK/logs.toml" && bad "region emitted by default" || ok "no region key by default"
grep -qE '^region = ' "$WORK/insights.toml" && bad "insights region emitted by default" || ok "insights: no region by default"
"$SCRIPTS/render-vector-config.sh" --region eu-central-1.aws.edge.axiom.co --out "$WORK/r.toml" >/dev/null 2>&1
grep -qE '^region = "eu-central-1.aws.edge.axiom.co"' "$WORK/r.toml" && ok "--region emits region" || bad "--region ignored"

# read_from modes
"$SCRIPTS/render-vector-config.sh" --first-run --out "$WORK/first.toml" >/dev/null 2>&1
grep -q 'read_from = "beginning"' "$WORK/first.toml" && ok "--first-run sets beginning" || bad "--first-run ignored"
"$SCRIPTS/render-vector-config.sh" --cutover --out "$WORK/cut.toml" >/dev/null 2>&1
grep -q 'read_from = "end"' "$WORK/cut.toml" && ok "--cutover sets end" || bad "--cutover ignored"

# input validation
"$SCRIPTS/render-vector-config.sh" --region "https://api.axiom.co" --out /dev/null >/dev/null 2>&1 \
  && bad "accepted region with scheme" || ok "rejects region with scheme"
"$SCRIPTS/render-vector-config.sh" --dataset "bad name!" --out /dev/null >/dev/null 2>&1 \
  && bad "accepted invalid dataset name" || ok "rejects invalid dataset name"

# ===========================================================================
group "vector validate (config + VRL compilation)"
# ===========================================================================
if [ -n "$VECTOR_IMG" ]; then
  for v in "$VECTOR_VERSION" "$VECTOR_KNOWN_GOOD_FLOOR"; do
    r="$(validate_run logs.toml "$v")"
    if printf '%s' "$r" | grep -q 'Validated'; then ok "log config validates on $v"; else bad "log config on $v" "$(printf '%s' "$r" | head -3)"; fi
    r="$(validate_run insights.toml "$v")"
    if printf '%s' "$r" | grep -q 'Validated'; then ok "insights config validates on $v"; else bad "insights config on $v" "$(printf '%s' "$r" | head -3)"; fi
  done
else
  printf '  SKIP (no docker)\n'
fi

# ===========================================================================
group "audit-pm2-logs.sh — read-only, drift detection"
# ===========================================================================
PM2_HOME_FIX="$FIXTURES/pm2-home"
# The audit resolves PM2_HOME itself, but the `pm2` stub derives its log paths
# from $PM2_HOME. Export it so the stub and the audit agree on the same tree;
# without this the stub reports paths under ~/.pm2 while the audit checks the
# fixture dir, and every app looks like it is logging out-of-tree.
export PM2_HOME="$PM2_HOME_FIX"
PATH="$FIXTURES/bin:$PATH" "$SCRIPTS/audit-pm2-logs.sh" --pm2-home "$PM2_HOME_FIX" --quiet > "$WORK/audit.json" 2>/dev/null
if jq -e . "$WORK/audit.json" >/dev/null 2>&1; then ok "audit emits valid JSON"; else bad "audit JSON invalid"; fi

if jq -e '.read_only == true' "$WORK/audit.json" >/dev/null 2>&1; then ok "audit declares read_only"; else bad "read_only flag"; fi

# THE critical finding: dump is a superset of live
hz="$(jq -r '.restart.save_hazard' "$WORK/audit.json")"
[ "$hz" = "would_drop_apps" ] && ok "detects 'pm2 save would drop apps'" || bad "save_hazard" "got '$hz'"
at_risk="$(jq -r '.restart.apps_at_risk_if_saved | join(",")' "$WORK/audit.json")"
[ "$at_risk" = "cron,legacy-api" ] && ok "names the at-risk apps" || bad "apps_at_risk" "got '$at_risk'"
jq -e '[.findings[] | select(.severity=="critical")] | length > 0' "$WORK/audit.json" >/dev/null 2>&1 \
  && ok "critical finding emitted" || bad "no critical finding for drift"

# Out-of-tree detection is per PATH, not per app: the fixture has one app
# (worker) whose out log is in-tree but whose error log is not. A combined flag
# would report both as out-of-tree.
jq -e '.logs.apps_outside_default_dir | index("worker") != null' "$WORK/audit.json" >/dev/null 2>&1 \
  && ok "detects app logging outside the default dir" || bad "outside-dir detection"

jq -e '.logs.per_app[] | select(.name=="api") | (.out_outside_default and .error_outside_default) | not' \
  "$WORK/audit.json" >/dev/null 2>&1 \
  && ok "fully in-tree app NOT flagged" || bad "false positive on in-tree app"

jq -e '.logs.per_app[] | select(.name=="worker") | (.out_outside_default | not) and (.error_outside_default)' \
  "$WORK/audit.json" >/dev/null 2>&1 \
  && ok "partially out-of-tree app flagged per path (worker)" || bad "per-path outside detection"

# evidence must be populated, never empty strings
if jq -e '[.findings[].evidence[]? | select(length == 0)] | length == 0' "$WORK/audit.json" >/dev/null 2>&1; then
  ok "all finding evidence populated"
else
  bad "empty evidence entries present"
fi

# disk capacity must not raise a false "disk full" from a parsing bug
free_pct="$(jq -r '.capacity.disk_free_pct' "$WORK/audit.json")"
if [ "$free_pct" != "null" ]; then
  if jq -e '.capacity.disk_mount == "/"' "$WORK/audit.json" >/dev/null 2>&1; then
    ok "disk mount resolved ($free_pct% free)"
  else
    bad "disk mount unresolved"
  fi
fi

# no_dump case: remove the dump and confirm the other critical finding
rm -f "$PM2_HOME_FIX/dump.pm2.bak"
cp "$PM2_HOME_FIX/dump.pm2" "$WORK/dump.bak" 2>/dev/null
rm -f "$PM2_HOME_FIX/dump.pm2"
PATH="$FIXTURES/bin:$PATH" "$SCRIPTS/audit-pm2-logs.sh" --pm2-home "$PM2_HOME_FIX" --quiet > "$WORK/audit2.json" 2>/dev/null
[ "$(jq -r '.restart.save_hazard' "$WORK/audit2.json")" = "no_dump" ] \
  && ok "detects missing dump.pm2" || bad "missing-dump detection"
# Restore for later groups. Guard on -f, not -n: shellcheck flags -n against a
# literal path as always-true, and the file genuinely may not exist.
[ -f "$WORK/dump.bak" ] && cp "$WORK/dump.bak" "$PM2_HOME_FIX/dump.pm2"

# The audit must not write anything into PM2_HOME. Compare a recursive
# checksum before and after, which works whether or not the fixtures happen to
# be committed to git (a `git status` check reports every fixture as untracked
# in a fresh clone and produces a false failure).
before="$(find "$PM2_HOME_FIX" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum)"
PATH="$FIXTURES/bin:$PATH" "$SCRIPTS/audit-pm2-logs.sh" --pm2-home "$PM2_HOME_FIX" --quiet >/dev/null 2>&1
after="$(find "$PM2_HOME_FIX" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum)"
[ "$before" = "$after" ] \
  && ok "audit is read-only (PM2_HOME checksum unchanged)" \
  || bad "audit modified PM2_HOME" "before=$before after=$after"

# And the vector config directory must be untouched too.
if [ -d /etc/vector ]; then
  vbefore="$(find /etc/vector -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum)"
  PATH="$FIXTURES/bin:$PATH" "$SCRIPTS/audit-pm2-logs.sh" --pm2-home "$PM2_HOME_FIX" --quiet >/dev/null 2>&1
  vafter="$(find /etc/vector -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum)"
  [ "$vbefore" = "$vafter" ] && ok "audit left /etc/vector unmodified" || bad "audit modified /etc/vector"
fi

# ===========================================================================
group "validate-tags.sh"
# ===========================================================================
printf 'VECTOR_TAG_MACHINE=web-01\n' > "$WORK/ok.env"; chmod 600 "$WORK/ok.env"
"$SCRIPTS/validate-tags.sh" --env-file "$WORK/ok.env" --quiet >/dev/null 2>&1 \
  && ok "accepts machine-only config" || bad "rejected valid config"

cat > "$WORK/bad.env" <<'EOF'
VECTOR_TAG_PUBLIC_IP=999.1.1.1
VECTOR_TAG_SEVERITY=critical
VECTOR_TAG_NOTINVRL=x
EOF
chmod 600 "$WORK/bad.env"
"$SCRIPTS/validate-tags.sh" --env-file "$WORK/bad.env" --quiet >/dev/null 2>&1 \
  && bad "accepted invalid config" || ok "rejects invalid config"

r="$("$SCRIPTS/validate-tags.sh" --env-file "$WORK/bad.env" --json 2>/dev/null)"
jq -e '[.errors[].problem] | any(contains("999"))' <<<"$r" >/dev/null 2>&1 \
  && ok "flags out-of-range octet" || bad "octet validation"
jq -e '[.errors[].problem] | any(contains("reserved"))' <<<"$r" >/dev/null 2>&1 \
  && ok "flags reserved-name collision" || bad "reserved-name check"
jq -e '[.errors[].problem] | any(contains("silently dropped"))' <<<"$r" >/dev/null 2>&1 \
  && ok "flags tag absent from VRL TAGS array" || bad "VRL-consistency check"

# mandatory machine
printf 'VECTOR_TAG_ROLE=api\n' > "$WORK/nomachine.env"; chmod 600 "$WORK/nomachine.env"
r="$("$SCRIPTS/validate-tags.sh" --env-file "$WORK/nomachine.env" --json 2>/dev/null)"
jq -e '[.errors[].problem] | any(contains("MANDATORY"))' <<<"$r" >/dev/null 2>&1 \
  && ok "machine tag is mandatory" || bad "mandatory machine check"

# permissions
chmod 644 "$WORK/ok.env"
r="$("$SCRIPTS/validate-tags.sh" --env-file "$WORK/ok.env" --json 2>/dev/null)"
jq -e '[.errors[].problem] | any(contains("mode is 644"))' <<<"$r" >/dev/null 2>&1 \
  && ok "flags world-readable env file" || bad "permission check"

# ===========================================================================
group "probe-network.sh"
# ===========================================================================
r="$("$SCRIPTS/probe-network.sh" --json --timeout 2 2>/dev/null)"
jq -e 'has("public_ip") and has("tailscale_installed")' <<<"$r" >/dev/null 2>&1 \
  && ok "emits JSON with expected keys" || bad "probe-network JSON shape"
if jq -e '.public_ip == "" or (.public_ip | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))' <<<"$r" >/dev/null 2>&1; then
  ok "public_ip empty or valid IPv4"
else
  bad "public_ip malformed" "$(jq -r '.public_ip' <<<"$r")"
fi
if jq -e '.tailscale_ip == "" or (.tailscale_ip | startswith("100."))' <<<"$r" >/dev/null 2>&1; then
  ok "tailscale_ip empty or in 100.64.0.0/10"
else
  bad "tailscale_ip outside 100.64.0.0/10" "$(jq -r '.tailscale_ip' <<<"$r")"
fi
"$SCRIPTS/probe-network.sh" >/dev/null 2>&1 && ok "exits 0 even when probes fail" || bad "probe-network exit code"

# ===========================================================================
group "repo hygiene"
# ===========================================================================
# No real-looking Axiom tokens anywhere.
#
# Known fakes are allow-listed by exact literal. The previous check only excluded
# anything containing "placeholder", which let several xaat-<junk> fixtures
# through — and it would equally let a real token past if someone happened to
# name a variable TOKEN_PLACEHOLDER.
KNOWN_FAKE_TOKENS="xaat-placeholder xaat-smoketest-placeholder-not-a-real-token xaat-abcdefghijklmnopqrstuvwxyz012345 xaat-SECRETVALUESECRETVALUE1234 xaat-ci-placeholder-not-a-real-token"
token_hits="$(grep -rInE 'xaat-[A-Za-z0-9]{10,}' "$REPO_DIR" --exclude-dir=.git 2>/dev/null || true)"
suspicious=""
if [ -n "$token_hits" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    tok="$(printf '%s' "$line" | grep -oE 'xaat-[A-Za-z0-9]{10,}' | head -1)"
    [ -z "$tok" ] && continue
    case " $KNOWN_FAKE_TOKENS " in
      *" $tok "*) continue ;;
    esac
    suspicious="$suspicious$line"$'\n'
  done <<< "$token_hits"
fi
if [ -n "$suspicious" ]; then
  bad "possible real Axiom token committed" "$(printf '%s' "$suspicious" | head -3)"
else
  ok "no Axiom token literals beyond the known test fakes"
fi

# Scripts must be executable.
for s in "$SCRIPTS"/*.sh "$ASSETS/host-insights.sh"; do
  [ -x "$s" ] && ok "executable: $(basename "$s")" || bad "not executable: $(basename "$s")"
done

# Shell syntax.
for s in "$SCRIPTS"/*.sh "$ASSETS/host-insights.sh"; do
  bash -n "$s" 2>/dev/null && ok "syntax: $(basename "$s")" || bad "syntax error: $(basename "$s")"
done

# SKILL.md constraints.
skill_lines=$(wc -l < "$SKILL_MD" | tr -d ' ')
[ "$skill_lines" -le 500 ] && ok "SKILL.md ${skill_lines} lines (<= 500)" || bad "SKILL.md too long" "$skill_lines lines"
desc_len=$(awk '/^description:/{f=1;next} f&&/^  /{gsub(/^ +/,"");printf "%s",$0} f&&!/^  /{exit}' "$SKILL_MD" | wc -c | tr -d ' ')
[ "$desc_len" -le 1024 ] && ok "description ${desc_len} chars (<= 1024)" || bad "description too long" "$desc_len chars"

# ===========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0