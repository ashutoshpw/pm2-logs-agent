# Tagging and the Axiom schema

## One mechanism

Every `VECTOR_TAG_*` environment variable in the allowlist becomes a lowercase
field on every event, in both the log pipeline and the insights pipeline.

```
VECTOR_TAG_MACHINE=web-01                ->  .machine
VECTOR_TAG_PUBLIC_IP=203.0.113.42        ->  .public_ip
VECTOR_TAG_TAILSCALE_IP=100.101.102.103  ->  .tailscale_ip
VECTOR_TAG_ROLE=api                      ->  .role
```

**Optionality is free.** A tag whose env var is absent produces no field at all —
not an empty string. Because Axiom's schema is defined on read, a field present on
some machines and absent on others is fine. Queries need `where public_ip != null`.

`machine` is **mandatory**. Without it no event is attributable to a host and the
dataset is not queryable by machine.

## The allowlist is explicit, and that is forced

VRL **cannot enumerate environment variables**. There is no `environment_variables`
function — on 0.59.0 it is a compile error:

```
error[E701]: call to undefined variable
  └─ 29 │ for_each(environment_variables) -> |key, value| {
```

Only `get_env_var("NAME")` exists, so each supported tag must be named literally in
the `TAGS` array in `assets/apply-tags.vrl`.

**Adding a tag means editing two files**, or it silently does nothing:

1. the `TAGS` array in `assets/apply-tags.vrl`
2. `assets/tag-policy.env`

`validate-tags.sh` and the test suite both assert they agree.

## Two VRL traps that produce silent no-ops

### `set!` inside a closure does not reach the event

```vrl
for_each(TAGS) -> |_idx, entry| {
  set!(value: ., path: [entry[1]], data: value)   # mutates a COPY
}
# result: events with no tags, and no error
```

Tags must accumulate into a local object and be merged **once, outside the loop**:

```vrl
tags = {}
for_each(TAGS) -> |_idx, entry| {
  updated, serr = set(value: tags, path: [entry[1]], data: value)
  if serr == null { tags = updated }
}
. = merge(., tags)
```

### Dynamic field paths are not `.${field}`

That is a syntax error. Use `set`/`set!` with an explicit path array.

## Reserved names

Two groups, both fatal to violate:

**Axiom system fields.** Axiom refuses to delete these, and a lock-schema dataset
reserves them.

```
_time  _sysTime
```

**Fields this pipeline derives.** Overwriting these would silently mislabel every
event in the dataset:

```
message  app  stream  severity  host  file  pm2_pid
pid  command  source_type  timestamp  data_stream  service
```

`apply-tags.vrl` refuses a reserved tag and logs a warning rather than applying it.
Attempting `VECTOR_TAG_SEVERITY` produces:

```
WARN pm2-logs-agent: refusing to set reserved field 'severity' from VECTOR_TAG_SEVERITY
```

## Three Axiom schema facts that bite

### 1. A locked schema silently DROPS unknown fields

If the target dataset has its schema locked, any field not in the locked schema is
discarded **without an error**. New tags appear to work and simply arrive empty.

This is why `validate-tags.sh` and the negative query both matter:

```apl
pm2-logs | where _time > ago(1h) and machine == "web-01" | limit 1
```

Empty means the tags did not land. Confirm in the dataset's Fields panel.

The audit flags a locked schema up front.

### 2. Deleted fields self-heal

Delete a field but keep ingesting it and Axiom re-adds it to the schema. So a
typo'd tag key (`machien=`) is **permanent** until the source is fixed — deleting
the field accomplishes nothing while the producer still sends it.

### 3. Field-count explosion is a documented anti-pattern

Axiom's guidance: avoid the "kitchen sink" dataset. As event types accumulate the
field count grows, queries get slower, and same-named fields with different types
force coercion. Keep the tag set small and fixed.

`TAG_MAX_COUNT` in `tag-policy.env` warns past 16.

## Cardinality

Axiom is columnar. A bounded value set is cheap and groupable; an unbounded one is
expensive and useless.

| Good | Bad |
|---|---|
| `role=api` | `role=<free text>` |
| `env=prod` | `deploy_id=<uuid per deploy>` |
| `machine=web-01` | `request_id=<per request>` |
| `region=us-east-1` | `container_id=<per restart>` |

`validate-tags.sh` warns on keys ending in `_id`, `_uuid`, `_guid`, `_at`,
`_timestamp`, `_epoch`, `_pid`, `_rand`.

## Dataset-per-environment vs an `env` tag

Axiom's own guidance prefers a **separate dataset per environment** over a single
`environment` attribute:

> You may be tempted to use a single `environment` attribute instead, but this
> risks causing confusion when results show up side-by-side... they'll often rely on
> applying an `environment` filter to all queries, which becomes a chore and is
> error-prone for newcomers.

So when `VECTOR_TAG_ENV` is proposed, **flag this and offer the alternative** — then
let the user decide. Do not block it. Both approaches are defensible; the tag is
simpler for small setups, separate datasets scale better and align with Axiom's
access-control model.

`AXIOM_REGION` is a separate matter: it is **optional and unset by default**,
because Vector falls back to Axiom's default base domain. Set it only for a
non-default edge deployment.

## IP tags specifically

Both optional, both probed by `probe-network.sh`.

- **`public_ip`** — an IPv4 address may count as personal data under GDPR-style
  regimes. Surface the trade-off; make it the user's explicit choice.
- **`tailscale_ip`** — present only when Tailscale is installed *and* connected.
  Sanity-checked to be in `100.64.0.0/10`, so an unrelated interface address is
  discarded rather than mislabelled.

Validation rejects anything that is not a dotted quad, any octet above 255, and
`0.0.0.0`.

### Drift

A public IP changes when an ISP reassigns it or a cloud EIP rotates. The env file
then holds a stale value while Axiom rows carry a new one. `verify-post-change.sh`
re-probes and reports `network.public_ip_drift`.

## Validating

```bash
scripts/validate-tags.sh --env-file /etc/vector/pm2-axiom.env
scripts/validate-tags.sh --env-file /etc/vector/pm2-axiom.env --json
```

Enforces: env file mode `0600`/`0400`, machine present, reserved-name collisions,
strict IPv4, length limits, cardinality suffixes, the VRL allowlist agreement, and
the tag budget. Warnings do not fail the run; errors do.

## Verifying in Axiom

```apl
pm2-logs | where _time > ago(1h) | summarize count() by machine
pm2-logs | where _time > ago(1h) and public_ip != null    | limit 1
pm2-logs | where _time > ago(1h) and tailscale_ip != null | limit 1
pm2-logs | where _time > ago(1h)
  | summarize has_ip = countif(public_ip != null) by machine
  | where has_ip == 0
```

The first proves the tag lands. The last finds machines missing an optional tag,
which is useful after rolling one out.