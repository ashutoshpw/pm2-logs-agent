#!/usr/bin/env bash
# pm2-logs-agent — validate an Axiom token by writing one probe record
#
# Proves ingest permission end-to-end, before the pipeline is enabled. A token
# can pass every local check and still be scoped to the wrong dataset, or lack
# ingest entirely, and that is only visible by actually sending something.
#
# THIS SCRIPT WRITES ONE RECORD to the target dataset on every non-dry run.
# The record is marked self_test = true and kind = "pm2-log-agent-selftest" so it
# can be found and deleted:
#
#   pm2-service-logs
#   | where kind == "pm2-log-agent-selftest" and _time > ago(1h)
#
# Usage:
#   validate-token.sh --token-file PATH [options]
#   validate-token.sh --token VALUE        # discouraged; leaks via ps
#
# Options:
#   --token-file PATH   read the token from a file (preferred; 0600, no argv leak)
#   --token VALUE       token as an argument (discouraged: visible in `ps`)
#   --env-file PATH     read SECRET_AXIOM_TOKEN and AXIOM_DATASET from an env file
#   --dataset NAME      default pm2-service-logs
#   --region DOMAIN     Axiom edge domain; unset means the default base domain
#   --dry-run           validate shape and report the URL; send nothing
#   --timeout SECONDS   default 20
#   --json              machine-readable result
#
# The token is NEVER printed, echoed, or included in any output. Only its
# length and shape are reported.
#
# Exit: 0 token valid, 1 token rejected or unreachable, 2 usage error.

set -uo pipefail

TOKEN_FILE=""
TOKEN_ARG=""
ENV_FILE=""
DATASET="pm2-service-logs"
REGION=""
DRY_RUN="no"
TIMEOUT=20
JSON_OUT="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --token-file) TOKEN_FILE="${2:-}"; shift 2 ;;
    --token)      TOKEN_ARG="${2:-}";  shift 2 ;;
    --env-file)   ENV_FILE="${2:-}";   shift 2 ;;
    --dataset)    DATASET="${2:-}";    [ -n "$DATASET" ] || { echo "validate-token: --dataset needs a value" >&2; exit 2; }; shift 2 ;;
    --region)     REGION="${2:-}";     shift 2 ;;
    --dry-run)    DRY_RUN="yes"; shift ;;
    --timeout)    TIMEOUT="${2:-}"; shift 2 ;;
    --json)       JSON_OUT="yes"; shift ;;
    -h|--help)    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "validate-token: unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "validate-token: curl is required" >&2; exit 2; }

jstr() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$s"
}

# ---------------------------------------------------------------------------
# resolve inputs
# ---------------------------------------------------------------------------

if [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || { echo "validate-token: env file not found: $ENV_FILE" >&2; exit 2; }
  [ -n "$TOKEN_ARG" ] || TOKEN_ARG="$(grep -E '^[[:space:]]*SECRET_AXIOM_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  if [ "${DATASET}" = "pm2-service-logs" ]; then
    d="$(grep -E '^[[:space:]]*AXIOM_DATASET=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
    [ -n "$d" ] && DATASET="$d"
  fi
  [ -z "$REGION" ] && REGION="$(grep -E '^[[:space:]]*AXIOM_REGION=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
fi

if [ -n "$TOKEN_FILE" ]; then
  [ -f "$TOKEN_FILE" ] || { echo "validate-token: token file not found: $TOKEN_FILE" >&2; exit 2; }
  m="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo '?')"
  case "$m" in
    600|400) : ;;
    *) echo "validate-token: WARNING token file mode is $m, expected 600 or 400" >&2 ;;
  esac
  TOKEN_ARG="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi

[ -n "$TOKEN_ARG" ] || { echo "validate-token: no token supplied (use --token-file or --env-file)" >&2; exit 2; }

# Axiom dataset names: ASCII alphanumeric and hyphen only.
case "$DATASET" in
  *[!A-Za-z0-9-]*) echo "validate-token: invalid dataset '$DATASET'" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# shape checks
# ---------------------------------------------------------------------------

SHAPE_OK=true
SHAPE_MSG=""
TOKEN_LEN="${#TOKEN_ARG}"

# Axiom tokens are prefixed xaat-. Catch a pasted placeholder or a truncated
# value before spending a network round trip on it.
if ! printf '%s' "$TOKEN_ARG" | grep -qE '^xaat-[A-Za-z0-9_-]+$'; then
  SHAPE_OK=false
  SHAPE_MSG="token does not look like an Axiom token (expected the xaat- prefix)"
elif [ "$TOKEN_LEN" -lt 20 ]; then
  SHAPE_OK=false
  SHAPE_MSG="token is only $TOKEN_LEN characters, which is too short to be valid"
fi

# ---------------------------------------------------------------------------
# URL
# ---------------------------------------------------------------------------
#
# The two URL shapes are NOT interchangeable. Verified against the live API:
#
#   default base domain      POST https://api.axiom.co/v1/datasets/<ds>/ingest
#   edge deployment          POST https://<region>/v1/ingest/<ds>
#
# Sending the edge-domain request to /v1/datasets/... returns 404, and the
# default-domain request to /v1/ingest/... also 404s. So AXIOM_REGION decides
# which path is correct, and a wrong pairing looks exactly like a broken token.

if [ -n "$REGION" ]; then
  case "$REGION" in
    http://*|https://*) URL="https://${REGION#*://}" ;;
    */) URL="https://${REGION%/}" ;;
    *)  URL="https://$REGION" ;;
  esac
  INGEST_URL="$URL/v1/ingest/$DATASET"
  REGION_USED="$REGION"
else
  INGEST_URL="https://api.axiom.co/v1/datasets/$DATASET/ingest"
  REGION_USED=""
fi

PROBE_ID="selftest-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
MACHINE_TAG="$(hostname 2>/dev/null || echo unknown)"

# _time must be an RFC3339 timestamp for Axiom to accept the record.
NOW="$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')"
PAYLOAD=$(printf '[{"_time":"%s","kind":"pm2-log-agent-selftest","self_test":true,"probe_id":"%s","machine":"%s","message":"pm2-logs-agent token validation probe"}]' "$NOW" "$PROBE_ID" "$MACHINE_TAG")

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

if [ "$JSON_OUT" = "yes" ]; then
  printf '{"dry_run":%s,"dataset":%s,"region":%s,"url":%s,"token_shape_ok":%s,"token_length":%s,"shape_problem":%s}\n' \
    "$([ "$DRY_RUN" = yes ] && echo true || echo false)" \
    "$(jstr "$DATASET")" "$(jstr "$REGION_USED")" "$(jstr "$INGEST_URL")" \
    "$SHAPE_OK" "$TOKEN_LEN" "$(jstr "$SHAPE_MSG")"
  [ "$DRY_RUN" = "yes" ] && exit 0
else
  echo "dataset    : $DATASET"
  echo "region     : ${REGION_USED:-<default base domain api.axiom.co>}"
  echo "ingest url : $INGEST_URL"
  echo "token      : $TOKEN_LEN chars, shape $([ "$SHAPE_OK" = true ] && echo ok || echo BAD)"
  [ -n "$SHAPE_MSG" ] && echo "             $SHAPE_MSG"
fi

if [ "$SHAPE_OK" != "true" ]; then
  if [ "$JSON_OUT" = "yes" ]; then
    printf '{"valid":false,"reason":%s}\n' "$(jstr "$SHAPE_MSG")"
  else
    echo
    echo "INVALID (not sent). Fix the token before running for real."
  fi
  exit 1
fi

if [ "$DRY_RUN" = "yes" ]; then
  if [ "$JSON_OUT" != "yes" ]; then
    echo
    echo "DRY RUN. Nothing sent. Re-run without --dry-run to write one probe record"
    echo "to $DATASET (kind = pm2-log-agent-selftest, deletable)."
  fi
  exit 0
fi

echo
echo "Sending one probe record to $DATASET ..."
RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT

HTTP_CODE="$(curl -sS -o "$RESP_FILE" -w '%{http_code}' -X POST "$INGEST_URL" \
  -H "Authorization: Bearer $TOKEN_ARG" \
  -H "Content-Type: application/json" \
  --max-time "$TIMEOUT" \
  --data "$PAYLOAD" 2>/dev/null || echo "000")"

BODY="$(head -c 500 "$RESP_FILE" 2>/dev/null)"

case "$HTTP_CODE" in
  200|201)
    if [ "$JSON_OUT" = "yes" ]; then
      printf '{"valid":true,"http":%s,"dataset":%s,"probe_id":%s,"response":%s}\n' \
        "$HTTP_CODE" "$(jstr "$DATASET")" "$(jstr "$PROBE_ID")" "$(jstr "$BODY")"
    else
      echo "OK  token is valid and has ingest permission for $DATASET"
      echo "    probe_id: $PROBE_ID"
      echo
      echo "The record is live. To find or remove it:"
      echo "  $DATASET | where kind == \"pm2-log-agent-selftest\" and _time > ago(1h)"
    fi
    exit 0
    ;;
  401)
    MSG="token rejected (401). It is malformed, expired, or revoked."
    ;;
  403)
    MSG="token lacks permission (403). It needs ingest access to $DATASET specifically."
    ;;
  404)
    MSG="dataset not found (404). Create $DATASET in Axiom first, or check --dataset. Also confirm AXIOM_REGION is set correctly: the default domain uses /v1/datasets/<ds>/ingest while an edge deployment uses /v1/ingest/<ds>, and the wrong pairing returns 404."
    ;;
  429)
    MSG="rate limited (429). Wait and retry."
    ;;
  000)
    MSG="could not reach Axiom (no response). Check egress, proxy settings, and whether the region host resolves."
    ;;
  *)
    MSG="unexpected HTTP $HTTP_CODE from Axiom."
    ;;
esac

if [ "$JSON_OUT" = "yes" ]; then
  printf '{"valid":false,"http":%s,"reason":%s,"response":%s}\n' \
    "$HTTP_CODE" "$(jstr "$MSG")" "$(jstr "$BODY")"
else
  echo "FAIL $MSG"
  [ -n "$BODY" ] && echo "     $BODY"
fi
exit 1