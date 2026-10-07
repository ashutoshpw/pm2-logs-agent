#!/usr/bin/env bash
# pm2-logs-agent — validate the Axiom tag configuration
#
# Checks the env file (default /etc/vector/pm2-axiom.env, or a path you pass)
# against the rules in assets/tag-policy.env. READ-ONLY: reports problems,
# changes nothing.
#
# Usage:
#   validate-tags.sh [--env-file PATH] [--json] [--quiet]
#
# Exit: 0 all checks passed, 1 one or more errors, 2 usage/missing input.
# Warnings alone do not fail the run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_FILE="$REPO_DIR/assets/tag-policy.env"
VRL_FILE="$REPO_DIR/assets/apply-tags.vrl"

ENV_FILE="/etc/vector/pm2-axiom.env"
QUIET="no"
JSON_OUT="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --json)     JSON_OUT="yes"; shift ;;
    --quiet)    QUIET="yes"; shift ;;
    -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'validate-tags: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -f "$POLICY_FILE" ] || { printf 'validate-tags: missing policy file: %s\n' "$POLICY_FILE" >&2; exit 2; }
# shellcheck source=/dev/null
. "$POLICY_FILE"

# Accumulate the inner objects here; the surrounding [ ] is added at output
# time. Storing the brackets early made the array "obj,obj" rather than
# "[obj,obj]", so jq 'length' failed and the count came back empty.
ERRORS_INNER=""
WARNINGS_INNER=""
add_error()   { local e; e=$(printf '{"tag":%s,"problem":%s}' "$(jstr "$1")" "$(jstr "$2")"); if [ -z "$ERRORS_INNER" ]; then ERRORS_INNER="$e"; else ERRORS_INNER="$ERRORS_INNER,$e"; fi; }
add_warning() { local w; w=$(printf '{"tag":%s,"problem":%s}' "$(jstr "$1")" "$(jstr "$2")"); if [ -z "$WARNINGS_INNER" ]; then WARNINGS_INNER="$w"; else WARNINGS_INNER="$WARNINGS_INNER,$w"; fi; }

jstr() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$s"
}

[ -f "$ENV_FILE" ] || {
  if [ "$JSON_OUT" = "yes" ]; then
    printf '{"env_file":%s,"exists":false,"valid":false,"errors":[{"tag":"","problem":"env file not found"}],"warnings":[]}\n' "$(jstr "$ENV_FILE")"
  else
    printf 'validate-tags: env file not found: %s\n' "$ENV_FILE" >&2
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# file permissions — a world-readable Axiom token is a real leak
# ---------------------------------------------------------------------------

PERM_MODE="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "unknown")"
PERM_OWNER="$(stat -c '%U' "$ENV_FILE" 2>/dev/null || echo "unknown")"
case "$PERM_MODE" in
  600|400) : ;;
  *) add_error "AXIOM_TOKEN" "env file mode is $PERM_MODE, expected 600 or 400. The file holds an Axiom ingestion token; anyone who can read it can write to your dataset." ;;
esac

# ---------------------------------------------------------------------------
# parse KEY=VALUE, ignoring comments and blanks
# ---------------------------------------------------------------------------

TAG_COUNT=0
MACHINE_VALUE=""

while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
    *=*) : ;;
    *) continue ;;
  esac

  key="$(printf '%s' "${line%%=*}" | tr -d '[:space:]')"
  val="${line#*=}"
  case "$key" in VECTOR_TAG_*) ;; *) continue ;; esac

  TAG_COUNT=$((TAG_COUNT + 1))
  suffix="${key#VECTOR_TAG_}"
  field="$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')"

  if [ -z "$val" ]; then
    add_warning "$field" "VECTOR_TAG_$suffix is set but empty, so the field is omitted from every event. Remove the line or give it a value."
    continue
  fi

  # Reserved names. MACHINE/PUBLIC_IP/TAILSCALE_IP are deliberately BOTH
  # reserved-against-user-overwrite and in the allowlist, so they get a
  # consistency note rather than an error.
  is_reserved=false
  for r in $TAG_RESERVED_NAMES; do
    [ "$field" = "$r" ] && { is_reserved=true; break; }
  done
  if [ "$is_reserved" = true ]; then
    case "$suffix" in
      MACHINE|PUBLIC_IP|TAILSCALE_IP) : ;;
      *) add_error "$field" "VECTOR_TAG_$suffix maps to reserved field '$field' and will be REFUSED by apply-tags.vrl. Rename the tag."; continue ;;
    esac
  fi

  # Must appear in the TAGS allowlist in apply-tags.vrl, else silently dropped.
  if ! grep -q "\[$suffix\"" "$VRL_FILE" 2>/dev/null && ! grep -q "\[\"$suffix\"" "$VRL_FILE" 2>/dev/null; then
    add_error "$field" "VECTOR_TAG_$suffix is not listed in the TAGS array in assets/apply-tags.vrl, so VRL never reads it and the tag is silently dropped. Add it to that file."
  fi

  # High-cardinality guard
  for suf in $TAG_REJECT_KEY_SUFFIXES; do
    case "$field" in
      *"$suf") add_warning "$field" "Tag key ends in '$suf', which usually carries an unbounded value (ids, timestamps). Axiom is columnar: an unbounded column is expensive and ungroupable. Use a bounded value or drop it." ;;
    esac
  done

  if [ "${#field}" -gt "$TAG_MAX_KEY_LEN" ]; then
    add_error "$field" "tag key is ${#field} chars, over the ${TAG_MAX_KEY_LEN} limit"
  fi
  if [ "${#val}" -gt "$TAG_MAX_VALUE_LEN" ]; then
    add_error "$field" "tag value is ${#val} chars, over the ${TAG_MAX_VALUE_LEN} limit"
  fi

  # IP tags get strict IPv4 validation
  case "$field" in
    public_ip|tailscale_ip)
      if ! printf '%s' "$val" | grep -qE '^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'; then
        add_error "$field" "'$val' is not a dotted-quad IPv4 address"
      else
        bad=""
        o1=$(printf '%s' "$val" | cut -d. -f1); o2=$(printf '%s' "$val" | cut -d. -f2)
        o3=$(printf '%s' "$val" | cut -d. -f3); o4=$(printf '%s' "$val" | cut -d. -f4)
        for o in "$o1" "$o2" "$o3" "$o4"; do
          [ "$o" -gt 255 ] 2>/dev/null && bad="an octet exceeds 255"
        done
        [ "$val" = "0.0.0.0" ] && bad="0.0.0.0 is not a routable address"
        [ -n "$bad" ] && add_error "$field" "'$val' is not usable: $bad"
        if [ "$field" = "tailscale_ip" ] && [ -z "$bad" ]; then
          case "$val" in
            100.*) : ;;
            *) add_warning "$field" "Tailscale IPv4 addresses live in 100.64.0.0/10; '$val' does not start with 100., so it is probably not a Tailscale address." ;;
          esac
        fi
      fi
      ;;
  esac

  [ "$field" = "machine" ] && MACHINE_VALUE="$val"
done < "$ENV_FILE"

# ---------------------------------------------------------------------------
# cross-checks needing the whole picture
# ---------------------------------------------------------------------------

if [ -z "$MACHINE_VALUE" ]; then
  add_error "machine" "VECTOR_TAG_MACHINE is missing or empty. It is MANDATORY: without it no event can be attributed to a host. Suggested value: $(hostname 2>/dev/null || echo your-hostname)"
else
  case "$MACHINE_VALUE" in
    *[!A-Za-z0-9._-]*) add_warning "machine" "value '$MACHINE_VALUE' contains characters outside A-Za-z0-9._-, so queries will need quoting." ;;
  esac
fi

if [ "$TAG_COUNT" -gt "$TAG_MAX_COUNT" ]; then
  add_warning "(budget)" "$TAG_COUNT tags configured, over the ${TAG_MAX_COUNT} guideline. Axiom documents field-count explosion on one dataset as an anti-pattern."
fi

for req in $TAG_REQUIRED_NAMES; do
  if ! grep -q "\"$req\"" "$VRL_FILE" 2>/dev/null; then
    add_error "$req" "listed in TAG_REQUIRED_NAMES but absent from the TAGS array in apply-tags.vrl, so VRL will never set it."
  fi
done

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------

# Wrap the accumulated objects into real JSON arrays.
ERRORS_JSON="[$ERRORS_INNER]"
WARNINGS_JSON="[$WARNINGS_INNER]"

ERR_COUNT=0; WARN_COUNT=0
[ -n "$ERRORS_INNER" ]   && ERR_COUNT=$(printf '%s' "$ERRORS_JSON"   | jq 'length' 2>/dev/null || echo 0)
[ -n "$WARNINGS_INNER" ] && WARN_COUNT=$(printf '%s' "$WARNINGS_JSON" | jq 'length' 2>/dev/null || echo 0)
ERR_COUNT="${ERR_COUNT:-0}"; WARN_COUNT="${WARN_COUNT:-0}"
VALID=true; [ "$ERR_COUNT" -gt 0 ] && VALID=false

if [ "$JSON_OUT" = "yes" ]; then
  # Emit the bracketed arrays directly. Splicing them through printf's %s and
  # then wrapping in another [...] produced nested [[]] when the list was
  # empty, which made `.errors | length` report 1 instead of 0.
  printf '{"env_file":%s,"exists":true,"mode":%s,"owner":%s,"tag_count":%s,"valid":%s,"errors":%s,"warnings":%s}\n' \
    "$(jstr "$ENV_FILE")" "$(jstr "$PERM_MODE")" "$(jstr "$PERM_OWNER")" "$TAG_COUNT" "$VALID" \
    "$ERRORS_JSON" "$WARNINGS_JSON"
else
  if [ "$QUIET" != "yes" ]; then
    printf 'env file : %s (mode %s, owner %s)\n' "$ENV_FILE" "$PERM_MODE" "$PERM_OWNER"
    printf 'tags     : %s configured\n\n' "$TAG_COUNT"
  fi
  if [ -n "$ERRORS_INNER" ]; then
    printf 'ERRORS (%s):\n' "$ERR_COUNT"
    printf '%s' "$ERRORS_JSON" | jq -r '.[] | "  - \(.tag): \(.problem)"' 2>/dev/null
    printf '\n'
  fi
  if [ -n "$WARNINGS_INNER" ]; then
    printf 'WARNINGS (%s):\n' "$WARN_COUNT"
    printf '%s' "$WARNINGS_JSON" | jq -r '.[] | "  - \(.tag): \(.problem)"' 2>/dev/null
    printf '\n'
  fi
  if [ "$VALID" = true ]; then
    printf 'OK: tag configuration is valid.\n'
  else
    printf 'FAILED: %s error(s). Fix before enabling the pipeline.\n' "$ERR_COUNT"
  fi
fi

[ "$VALID" = true ] && exit 0
exit 1