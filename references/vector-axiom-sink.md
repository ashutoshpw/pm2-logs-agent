# Vector's Axiom sink

Reference for the `axiom` sink as it behaves at the pinned version
(**0.59.0**). Verified against the real binary, not inferred from docs.

## Status

| Property | Value |
|---|---|
| status | **beta** |
| delivery | **at-least-once** |
| acknowledgements | yes |
| state | stateless |
| accepts | logs, metrics, traces |

Beta and at-least-once together mean **duplicates are possible on retry**. Design
queries to tolerate them, and do not build exact-count dashboards without
deduplication.

## Required options

```toml
[sinks.axiom]
type = "axiom"
inputs = ["apply_tags"]
dataset = "pm2-logs"
token = "..."
```

| Option | Required | Notes |
|---|---|---|
| `dataset` | yes | Axiom allows 1–128 chars, ASCII alphanumeric and `-` only |
| `token` | yes | ingestion permission for that dataset |
| `region` | no | see below |
| `org_id` | no | **only for personal tokens**; omit for service accounts |
| `url` | no | alternative to `region`; do not set both |

## region is optional

When `region` is absent, Vector uses Axiom's default base domain (`api.axiom.co`).
Verified: a sink with neither `region` nor `url` passes `vector validate`.

```
region = "us-east-1.aws.edge.axiom.co"     # US East 1, AWS
region = "eu-central-1.aws.edge.axiom.co"  # EU Central 1, AWS
```

Domain only — no scheme, no path, no trailing slash. `render-vector-config.sh`
validates that and writes the key only when `--region` is passed explicitly.

## Batch and buffer

```toml
batch.timeout_secs = 2
batch.max_events = 1000

[sinks.axiom.buffer]
type = "disk"
max_size = 536870912   # must be >= 268435488 (~256 MiB) for disk
when_full = "block"
```

### The 256 MiB floor

`buffer.max_size` is **required** for a disk buffer, and Vector rejects anything
below ~256 MiB (`268435488` bytes) outright. This is an easy config to fail on
because a "reasonable" 64 MiB looks fine until the config refuses to load.

### block vs drop_newest

| `when_full` | Behaviour |
|---|---|
| `block` | back-pressure upstream; nothing lost, data piles up at the edge |
| `drop_newest` | discards; faster, but loses data |

Use `block` for logs — losing application logs is not self-healing. The insights
sink deliberately uses `drop_newest`, because a missed 30-minute snapshot
self-heals on the next tick.

## Compression

`zstd` by default since Vector 0.42.0. Set explicitly to pin behaviour:

```toml
compression = "zstd"   # gzip | zlib | snappy | zstd | none
```

## Retries

Vector retries on `408`, `429`, and `5xx` except `501`. Other responses are not
retried.

```toml
request.retry_attempts = 10        # default: unlimited
request.retry_initial_backoff_secs = 1
request.retry_max_duration_secs = 30
request.timeout_secs = 60          # do not lower below Axiom's internal timeout
request.concurrency = "adaptive"   # ARC; the default and recommended
```

Adaptive Request Concurrency manages throughput from Axiom's response codes. Leave
it on.

Lowering `timeout_secs` below the downstream service timeout causes orphaned
requests, retry pile-ups, and duplicate data. Leave it.

## Health checks

Enabled by default; Vector logs an error but still starts. To fail fast:

```bash
vector --config /etc/vector/pm2-axiom.toml --require-healthy
```

The systemd unit uses this with `Restart=always` so a broken pipeline surfaces as a
retry loop rather than a silently degraded process.

## Timestamps

| Vector version | Axiom timestamp field |
|---|---|
| ≥ 0.42.0 | `_time` |
| ≤ 0.41.1 | `@timestamp` |

`parse-app.vrl` sets `._time` from Vector's `timestamp` field.

⚠️ This must be a **field path**. A bare `_time = ...` compiles without error and
assigns a local VRL variable that never reaches the event — Axiom then defaults
every timestamp to ingest time. Verified on 0.59.0 and covered by the test suite.

## Useful telemetry

| Metric | Use |
|---|---|
| `component_errors_total` | sink errors, by `error_type` |
| `component_discarded_events_total` | `intentional=false` means real drops |
| `buffer_size_bytes` / `buffer_size_events` | back-pressure indicator |
| `buffer_discarded_events_total` | only non-zero with `drop_newest` |
| `component_sent_events_total` | confirm data is actually leaving |

Inspect live:

```bash
vector top
vector tap --inputs-of axiom --duration_ms 5000
```

`vector tap` samples events **without sending them anywhere**, which makes it the
safe way to prove a pipeline is flowing before pointing it at a paid endpoint.

## Health check commands

```bash
vector list --format json                      # configured components
vector validate --no-environment /etc/vector/pm2-axiom.toml
vector graph --config /etc/vector/pm2-axiom.toml | dot -Tsvg > graph.svg
```

`validate --no-environment` skips component and health checks, so it works offline
and in CI without Axiom credentials. Without that flag it needs to reach Axiom.

## Axiom-side prerequisites

- a dataset with **Kind = Events** for logs, **Kind = Metrics** for insights
- a token scoped to ingest for those datasets only
- an edge deployment matching `region`, if set
- check whether the dataset schema is **locked** — a locked schema silently drops
  fields it does not declare, including new tags