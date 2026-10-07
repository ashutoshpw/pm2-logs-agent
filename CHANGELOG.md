# Changelog

## 1.0.0

Initial release.

### Audit
- `scripts/audit-pm2-logs.sh` — read-only audit of PM2 runtime state, real log
  paths, restart survivability, installed collectors, rotation, network identity
  and disk capacity. Emits structured JSON with severity-rated findings.
- Detects the two silent reboot failures: apps returning with no logs collected,
  and a healthy collector receiving zero data.
- Flags that `pm2 save` **overwrites** the snapshot with the current process list,
  naming the apps that would be dropped.
- Detects a `pm2-<user>` unit pointing at a Node path that no longer exists, which
  fails silently at boot.
- Downgrades `pm2 save` findings on containers, where the mechanism does not apply.
- Downgrades app-level noise (`errored` status) so logging findings stay distinct
  from application failures.

### Remediation
- `scripts/render-vector-config.sh` — renders a host-specific config with include
  globs derived from `pm2 jlist`, and inlines the VRL programs.
- `scripts/install-vector-pinned.sh` — installs an exact Vector version with an
  architecture/libc-aware asset selection and a sha256 gate.
- `scripts/verify-post-change.sh` — re-checks invariants, including public-IP drift.

### Identity
- `machine` tag is mandatory; `public_ip` and `tailscale_ip` are optional and
  omitted cleanly when unavailable.
- `scripts/probe-network.sh` — best-effort public IPv4 and Tailscale IPv4 probing.
- `scripts/validate-tags.sh` — reserved-name, IPv4, cardinality, permissions and
  policy/VRL consistency checks.
- `AXIOM_REGION` is optional and unset by default.

### Insights
- `assets/host-insights.sh` — server-wide CPU, load, RAM and per-disk snapshot every
  30 minutes, in a separate Metrics-kind dataset.
- Effective capacity from cgroup limits when containerised, so a 2 GB container does
  not report 3% of a 128 GB host.
- Explicit `disk_coverage` so partial reads are visible rather than silent.
- True CPU busy% from a `/proc/stat` delta, independent of `sysstat`.

### Pipeline
- PM2 logs to Axiom via Vector, with `app`, `stream`, `severity` and `pm2_pid`
  derived from the log filename, and multi-line stack-trace aggregation.
- Disk buffer with a 512 MiB floor and `block` back-pressure.
- Credentials read at runtime via `get_env_var`, so no
  `--dangerously-allow-env-var-interpolation` flag is required.
- Vector pinned to 0.59.0; templates validated against 0.58.0 as well.

### Safety
- Default mode is audit-only; no write occurs without explicit per-action approval.
- Four-tier risk model; RISKY actions are generated but never executed.
- Verified against the pinned binary: `._time` as a field path, tags merged
  outside `for_each`, `include_stderr = false`, and `region` genuinely optional.