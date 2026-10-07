# pm2-logs-agent

[![skills.sh](https://skills.sh/b/ashutoshpw/pm2-logs-agent)](https://skills.sh/ashutoshpw/pm2-logs-agent)

An agent skill that audits PM2 log forwarding, verifies it survives a reboot, and
proposes fixes for your approval. Ships PM2 logs to Axiom through Vector without
touching application code.

```bash
npx skills add ashutoshpw/pm2-logs-agent
```

## What it does

**Audits first, changes nothing.** Run it against any server to get a read-only report:

- every PM2 app's **real** log paths, including custom `out_file`/`error_file`
  that a `~/.pm2/logs/*.log` glob silently misses
- whether `pm2 save` was done, and whether re-running it would **lose apps**
- whether `pm2-<user>.service` exists, is enabled, and points at a live Node path
- existing collectors (Vector, fluent-bit, syslog) and whether one already reads
  PM2 logs, which would mean double ingest
- rotation setup, disk capacity, Vector version drift against a pinned version

**Catches the two silent failures.** PM2 saved + collector disabled means apps return
and all logs vanish. Collector enabled + PM2 not saved means a healthy pipeline
receiving zero data. Both look fine in a dashboard.

**Proposes a tiered plan and asks before doing anything.**

| Tier | Examples |
|---|---|
| SAFE | write the config, create the env file, add a tag |
| CHANGE | enable the service, edit an existing config |
| RISKY | `pm2 save`, `pm2 startup`, restarting apps — **never executed by the skill** |

## Identity tags

A `machine` tag is **mandatory** — without it no event is attributable to a host.
Two more are optional and omitted cleanly when unavailable:

```bash
VECTOR_TAG_MACHINE=web-01          # mandatory
VECTOR_TAG_PUBLIC_IP=203.0.113.42  # optional, probed
VECTOR_TAG_TAILSCALE_IP=100.101.102.103  # optional, Tailscale only
```

`AXIOM_REGION` is optional and **unset by default**; Vector uses Axiom's default
base domain unless your organization is on a non-default edge deployment.

## Server insights every 30 minutes

CPU busy% from a real `/proc/stat` delta, load against effective capacity,
server-wide RAM, and per-disk usage for every real filesystem — in a separate
Metrics-kind dataset.

Inside a container it reports both the host view and the cgroup limits, so a 2 GB
container never reports "3% of 64 GB". Partial disk reads are surfaced explicitly
rather than silently dropped.

## Layout

```
SKILL.md                     the skill
assets/
  vector.toml                log pipeline (validated against the pin)
  vector-insights.toml       30-minute insights pipeline
  host-insights.sh           snapshot emitter
  parse-app.vrl              filename -> app/stream/severity
  apply-tags.vrl             VECTOR_TAG_* -> event fields
  vector-version.env         pinned Vector version + checksums
  tag-policy.env             tag rules
  pm2-axiom.env.example      credentials and tags template
  vector-pm2-axiom.service   hardened systemd unit
  queries.axiom              verification queries
scripts/
  audit-pm2-logs.sh          read-only audit
  validate-tags.sh           tag linter
  probe-network.sh           public IPv4 + Tailscale IPv4
  render-vector-config.sh    renders a host-specific config
  install-vector-pinned.sh   pinned install with a sha256 gate
  verify-post-change.sh      re-check invariants after a change
references/                  deep dives, loaded on demand
tests/run-tests.sh           test suite
```

## Pinning

Vector **0.59.0** is pinned in `assets/vector-version.env`, and CI validates every
template against it plus the 0.58.0 known-good floor. `install-vector-pinned.sh`
refuses to install an asset whose sha256 does not match the release's own
`SHA256SUMS`.

## Requirements

- `bash`, `jq`, `curl`
- Vector is installed by the skill (or already present — the audit reports drift)
- Optional: `tailscale` for the Tailscale IP tag, `systemctl` for boot-state checks

## Why Vector rather than `pm2-syslog`

PM2 has no official Axiom module. [`pm2-syslog`](https://github.com/pm2-hive/pm2-syslog)
forwards to local syslog and adds a hop. Axiom documents Vector natively, and Vector's
Axiom output reads the existing `~/.pm2/logs` files, so no application code changes.

Caveat worth knowing: Vector's `axiom` sink is labelled **beta** and delivers
at-least-once, so duplicates are possible on retry.

## Licence

MIT