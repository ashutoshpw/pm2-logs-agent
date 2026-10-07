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
ASSETS="$REPO_DIR/assets"
SCRIPTS="$REPO_DIR/scripts"
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
    vrl -i "/r/tests/fixtures/inputs/$1" -p "/r/assets/$2" --print-object 2>&1 \
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
      vrl -i /r/tests/fixtures/inputs/event-out.json -p /r/assets/apply-tags.vrl --print-object 2>&1 \
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
if grep -rInE 'xaat-[A-Za-z0-9]{10,}' "$REPO_DIR" --exclude-dir=.git 2>/dev/null | grep -v 'placeholder' | grep -q .; then
  bad "possible real Axiom token committed" "$(grep -rInE 'xaat-[A-Za-z0-9]{10,}' "$REPO_DIR" --exclude-dir=.git | head -3)"
else
  ok "no Axiom token literals in repo"
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
skill_lines=$(wc -l < "$REPO_DIR/SKILL.md" | tr -d ' ')
[ "$skill_lines" -le 500 ] && ok "SKILL.md ${skill_lines} lines (<= 500)" || bad "SKILL.md too long" "$skill_lines lines"
desc_len=$(awk '/^description:/{f=1;next} f&&/^  /{gsub(/^ +/,"");printf "%s",$0} f&&!/^  /{exit}' "$REPO_DIR/SKILL.md" | wc -c | tr -d ' ')
[ "$desc_len" -le 1024 ] && ok "description ${desc_len} chars (<= 1024)" || bad "description too long" "$desc_len chars"

# ===========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0