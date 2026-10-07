# Host insights

`assets/host-insights.sh` emits one compact JSON line every 30 minutes. Vector's
`exec` source runs it on a schedule and ships the result to a **separate** Axiom
dataset.

## Server-wide, not per-user

Everything reported is **host-wide**. `/proc/loadavg`, `/proc/meminfo` and
`/proc/self/mounts` are world-readable, so a non-root Vector service gets true host
figures with no privilege escalation.

If it were scoped to the PM2 user it would be actively misleading — that is the
figure that reads as "the app is using 90% of memory" when the host has 128 GB and
the app is using 200 MB.

`/proc/meminfo` totals are always the **host's**, even inside a container.

## Why a separate dataset

Axiom's guidance is to separate by signal type. Mixing 30-minute server snapshots
with high-volume application logs means every log query scans irrelevant rows, and
the field counts diverge wildly. The insights dataset should be created with
Kind = **Metrics**.

## Field reference

```json
{
  "kind": "host_insights",
  "scope": "host",
  "interval_s": 1800,
  "host":      { "cpus": 24, "load1": 18.2, "ram_total_bytes": 137438953472 },
  "cgroup":    null,
  "cpu":       { "busy_pct": 63.2, "user_pct": 41.0, "system_pct": 22.2,
                 "iowait_pct": 3.1, "cores_total": 24, "cores_effective": null },
  "load":      { "load1": 18.2, "load5": 17.9, "load15": 16.4,
                 "capacity_cpus": 24.0, "pct_of_capacity": 75.8 },
  "ram":       { "total_bytes": 137438953472, "host_total_bytes": 137438953472,
                 "available_bytes": 59365453824, "used_bytes": 78073499520,
                 "used_pct": 56.8 },
  "disks":     [ { "mount": "/", "fs_type": "ext4", "total_bytes": 1820389289984,
                    "used_bytes": 1603258941440, "avail_bytes": 123664617472,
                    "used_pct": 93, "source": "/dev/nvme0n1p3" } ],
  "disk_coverage": { "ok": 3, "failed": 0, "failed_mounts": null }
}
```

| Field | Meaning |
|---|---|
| `scope` | `"host"` on bare metal, `"container"` when containerised |
| `cpu.busy_pct` | true CPU utilisation from a `/proc/stat` delta |
| `cpu.iowait_pct` | I/O wait, which load average conflates with CPU pressure |
| `load.capacity_cpus` | **effective** CPU limit: cgroup quota if capped, else host CPUs |
| `ram.total_bytes` | **effective** capacity: cgroup limit if capped, else host total |
| `ram.host_total_bytes` | always the physical host figure, for context |
| `disks` | one entry per real filesystem, never summed |
| `disk_coverage.failed` | mounts that could not be stat'd (see below) |

## Capacity means the effective limit

Inside a container, `nproc` and `/proc/meminfo` report the **host's** values. Using
those as capacity is wrong in the exact direction that hides a problem: a container
capped at 2 CPUs and 2 GB on a 64-core/128 GB host would report *"load 0.5 of 64 —
0.8%."*

So capacity is always the limit that actually applies:

| Metric | Bare metal | Container |
|---|---|---|
| CPU capacity | host CPU count | `cpu.max` quota ÷ period |
| RAM capacity | `MemTotal` | cgroup `memory.max` |

When containerised, both views are reported: `host` for physical context, `cgroup`
for the limits, and the derived `load`/`ram` blocks use the effective values.

### cgroup detection

cgroup v2 (unified): `cpu.max`, `memory.max`, `memory.current`.
cgroup v1 fallback: `cpu.cfs_quota_us` ÷ `cpu.cfs_period_us`,
`memory.limit_in_bytes`.

⚠️ On cgroup v1, an **unlimited** memory limit reports the sentinel
`9223372036854771712` (LONG_MAX rounded to page size). That is detected and
treated as "no limit". Shipping it as capacity would report 8 exabytes.

## Partial disk reads are surfaced, not hidden

`df`/`statvfs` on a mount whose parent directory lacks `o+x` fails for a non-root
user. Silently omitting those rows makes a partial snapshot indistinguishable from a
complete one.

```json
"disk_coverage": { "ok": 2, "failed": 1, "failed_mounts": ["/mnt/tenant-b"] }
```

Any per-disk query is **incomplete** for that machine. Alert on `failed > 0`.

Escape hatch if it matters: a NOPASSWD sudoers entry scoped to exactly
`host-insights.sh`. The default stays unprivileged.

## Filesystem filtering

Excluded by default: `tmpfs devtmpfs proc sysfs cgroup cgroup2 ramfs squashfs devfs`
and loop devices. Configure with `PM2_INSIGHTS_DISK_FS_EXCLUDE`.

Add `overlay` when containerised and the host's overlay layers are not wanted.

`PM2_INSIGHTS_MAX_DISKS` (default 32) caps the array so a pathological `df` cannot
produce an unbounded event.

## Why not Vector's `host_metrics` source

It exists and is the obvious choice, but it emits **continuous metric events**, not
periodic snapshots. Getting one row every 30 minutes out of it means an `aggregate`
transform reshaping version-dependent metric names
(`cpu.logical_cpu_utilization`, `memory.utilization`, `filesystem.utilization`),
which is brittle across upgrades.

A 200 ms `/proc/stat` delta in the script gives a real `busy_pct` with no
`sysstat` dependency — important because these run on arbitrary hosts including
busybox and minimal containers.

## Two load-bearing config options

```toml
include_stderr = false          # Vector's exec source DEFAULTS THIS TO TRUE
decoding.codec = "json"         # defaults to "bytes"
```

Any stray warning from the script would become a **phantom `host_insights` event**.
The script keeps stderr empty by design; `include_stderr = false` makes that
structural. `decoding.codec = "json"` is what makes the fields queryable instead of
one opaque `message` string.

The script also emits exactly **one line**. The exec source splits on newlines, so
pretty-printed JSON would produce N bogus events.

## Buffer choice

The insights sink uses a **memory** buffer with `when_full = "drop_newest"`, and
that is intentional. If Axiom is unreachable, a 30-minute snapshot backlog is not
worth blocking a disk buffer for — the script re-emits the *current* state on the
next tick anyway, so a dropped snapshot self-heals.

The log pipeline is the opposite: a `disk` buffer, because losing application logs
is not self-healing.

## Querying

Per-disk rows need `mv-expand`, which expands dynamic arrays into rows:

```apl
pm2-service-logs (kind == "host_insights") | where _time > ago(6h) | mv-expand disks
  | project _time, machine, disks.mount, disks.used_pct
  | where disks.used_pct > 80
```

### Cadence

```apl
pm2-service-logs (kind == "host_insights") | where _time > ago(3h)
  | summarize ticks = count(), first = min(_time), last = max(_time)
```

Expect ≈6 ticks in 3h. Allow first-tick-plus-one-interval for a cold start — the
docs do not state whether `scheduled` fires immediately at startup or waits a full
interval, and the skill does not claim either.

### Dead heartbeat

```apl
pm2-service-logs (kind == "host_insights") | summarize last = arg_max(_time, _time) | where last < ago(45m)
```

Must return **empty** when healthy. Recommended as an Axiom monitor: 45m gives
margin over the 30m interval.

### Partial reads

```apl
pm2-service-logs (kind == "host_insights") | where _time > ago(6h) and disk_coverage.failed > 0
  | project _time, machine, disk_coverage
```

## Running it by hand

```bash
assets/host-insights.sh | jq .
assets/host-insights.sh | jq -c '.disks[] | {mount, used_pct}'
PM2_INSIGHTS_DISK_FS_EXCLUDE="tmpfs devtmpfs overlay" assets/host-insights.sh | jq .
```

Works without `jq` (awk fallback keeps the output single-line) and without root.