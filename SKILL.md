---
name: pm2-logs-agent
description: >-
  Audit and fix log forwarding for PM2-managed Node.js apps, and verify they survive a reboot.
  Inspects an existing Vector/fluent-bit/syslog setup, finds the log paths apps actually write to,
  checks whether pm2 save plus an enabled pm2-<user> systemd unit will bring everything back, and
  detects the two silent failure modes where apps return but no logs arrive. Use for "audit my pm2
  logs", "ship pm2 logs to axiom", "will my apps restart after a reboot", "pm2 save", "pm2 startup",
  "where are my pm2 logs", or "set up pm2 log forwarding". Attaches a mandatory machine tag plus
  optional public-IPv4 and Tailscale-IP tags, and reports server-wide CPU, RAM and per-disk usage
  every 30 minutes. Never changes production state without explicit per-action approval.
license: MIT
metadata:
  version: 1.0.0
  vector-pinned: "0.59.0"
---

# pm2-logs-agent

Centralise PM2 logs into Axiom without touching application code, and make sure the
setup survives a reboot. **Audit first. Propose. Never mutate without sign-off.**

## The governing rule

**Default mode is audit-only.** An audit must change nothing on disk, no service may be
restarted, and `pm2 save` must never be run as part of gathering information.

When someone says "audit my logging", "check my setup", "are my pm2 logs ok", or asks
anything diagnostic — run the audit, report, and stop. Do not install, enable, restart,
or save anything. Offer next steps; let the human choose.

`scripts/audit-pm2-logs.sh` is read-only by construction. Keep it that way.

## Workflow

```
1. AUDIT      read-only. What exists, what is broken, what is missing.
2. REPORT     findings by severity + the restart-survival matrix.
3. PROPOSE    numbered action list, each with a risk tier, blast radius, rollback.
4. CONFIRM    ask which actions to run. Default when ambiguous: run nothing.
5. APPLY      only approved actions. Execute SAFE and CHANGE; hand RISKY to the human.
6. VERIFY     re-run the audit and the Axiom queries. Report before/after.
```

Never skip 3 and 4. Steps 1→2 alone are a complete, useful interaction.

## Risk tiers

Approval is per tier. Approving tier N never implies N+1.

| Tier | Meaning | Examples | Gate |
|---|---|---|---|
| **READ** | No state change | the entire audit | disclose what was read |
| **SAFE** | Additive, reversible, no running workload touched | write a new `vector.toml`; create `/var/lib/vector`; write the env file `0600`; add a tag value | one grouped approval |
| **CHANGE** | Alters runtime behaviour, needs a service start/restart | `systemctl enable --now vector`; editing an *existing* Vector config; adding a second `file` source; Vector upgrade | per action, show the diff |
| **RISKY** | Can cause an outage or lose data | `pm2 save` when the dump is a superset; `pm2 startup`; `pm2 unstartup`; `pm2 restart`/`reload` any app; changing `out_file`/`error_file`; `pm2 flush`; deleting rotated logs | **always** explicit yes, restate the blast radius, suggest a window |

**RISKY actions are never executed by the skill.** Generate the command, explain the
consequence, let the human run it.

## Step 1 — Audit

```bash
scripts/audit-pm2-logs.sh                      # JSON to stdout
scripts/audit-pm2-logs.sh --user deploy --pm2-home /home/deploy/.pm2
```

Reports: PM2 runtime state, every app's real log paths, restart survivability, installed
collectors (and whether one already reads PM2 logs, which would double ingest), rotation
setup, network identity, disk capacity, and Vector version drift against the pin.

Requires `jq`. Safe to run repeatedly.

## Step 2 — Report

Lead with whatever is highest severity. Two things must always be surfaced:

### The restart-survival matrix

`pm2 save` state and collector boot state combine into four outcomes. Two of them fail
**silently** — everything looks healthy and no logs arrive:

| | Collector enabled at boot | Collector NOT enabled |
|---|---|---|
| **PM2 saved + unit enabled** | correct | ⚠️ **apps return, all logs vanish** |
| **PM2 NOT saved** | ⚠️ **pipeline healthy, zero data** | obvious outage |

Show this table whenever either ⚠️ cell applies. It is the single most valuable output
of the audit.

### The `pm2 save` drift table

`pm2 save` **overwrites** `dump.pm2` with the *current* process list. It does not merge.
The audit compares the live list against the dump:

| Live | Dump | Meaning | Severity |
|---|---|---|---|
| N apps | no dump | nothing will resurrect | critical |
| N apps | dump older than last app start | apps added since are unsaved | high |
| **3 apps** | **dump has 7** | **`pm2 save` now drops 4** | **critical** |
| 7 apps | dump has 3 | running apps unsaved | critical |

The third row is the trap. Never offer "run `pm2 save`" as a safe default — report the
names that would be lost and let the human decide whether those apps *should* run.

## Step 3 — Propose

Number every action. Include command, tier, rationale, blast radius, and rollback.

```markdown
| # | Action | Command | Tier | Why | Blast radius | Rollback |
|---|--------|---------|------|-----|---------------|----------|
| 1 | Enable collector | systemctl enable vector | CHANGE | disabled; logs vanish on reboot | vector starts | systemctl disable vector |
| 2 | Re-snapshot PM2 | pm2 save | RISKY | dump holds 7, 3 live → would drop: worker, cron, api-v2 | 4 apps lost on reboot | restore dump.pm2.bak |
```

## Step 4 — Confirm

Use the question tool. Present headline findings first, then ask which numbers to
execute. Offer "all SAFE", "all SAFE + CHANGE", "audit only", and free text.

Confirm each RISKY item individually by number, even under a blanket approval.
If the user is ambiguous or does not answer, **apply nothing**.

## Never do these without asking

- Run `pm2 save` reflexively. It can bake in a snapshot *worse* than the current one.
- `pm2 restart`/`reload` to "apply" a log-path change. PM2 log paths need a real restart,
  which is downtime.
- `pm2 flush`, or delete rotated logs, to reclaim space.
- Set `read_from = "beginning"` on a large log directory without `ignore_older_secs`.
  That is a multi-gigabyte backfill and a real bill.
- Add a second collector over globs another agent already reads. Duplicate ingest, double cost.
- Put a real Axiom token in a repo, a config not `0600`, a report, or chat output.
- Assume `~/.pm2/logs/*.log` is the only log location. It usually is not.
- Mutate anything during an audit-only request.

## Step 4 — Identity and tags

Ask before proposing actions, because the answer changes the config.

**`machine` is MANDATORY.** Suggested default `$(hostname)`; the user may override. Without
it no event is attributable to a host.

**Optional**, probed by `scripts/probe-network.sh`, omitted cleanly when unavailable:
- `public_ip` — probe fails or is unwanted → line absent → field absent from all events
- `tailscale_ip` — present only when Tailscale is installed *and* connected

Offer a curated set of extras: `env`, `region`, `role`, `team`, `cluster`, `service`,
`deploy_id`.

**`AXIOM_REGION` is optional and unset by default.** Vector then uses Axiom's default
base domain. Set it only when Axiom → Settings → General shows a non-default edge
deployment. Setting it wrongly routes data to the wrong edge.

```bash
scripts/validate-tags.sh --env-file /etc/vector/pm2-axiom.env
```

Enforces: machine present, no reserved-name collisions, strict IPv4, no unbounded tag
keys, and agreement between `assets/tag-policy.env` and the `TAGS` array in
`assets/apply-tags.vrl`.

**Flag, do not block:** Axiom's own guidance prefers a separate dataset per environment
over an `env` attribute, because an `env` filter silently gets forgotten in queries.
Surface it when `env` is proposed; let the user decide.

## Step 5 — Remediation

Only after approval.

```bash
scripts/install-vector-pinned.sh                    # exact pinned version + sha256 gate
scripts/render-vector-config.sh --pm2-home /home/deploy/.pm2 --out /etc/vector/pm2-axiom.toml
scripts/render-vector-config.sh --insights --out /etc/vector/host-insights.toml
```

Globs are derived from the audit's real `pm_out_log_path`/`pm_err_log_path`, never
hand-written. Credentials come from `/etc/vector/pm2-axiom.env` (mode `0600`), read at
runtime via VRL — so no `--dangerously-allow-env-var-interpolation` flag is needed.

Install the unit from `assets/vector-pm2-axiom.service` and grant the `vector` user read
access to the PM2 log directory. `ProtectHome=read-only` still permits reading; the unit
comment explains why `true` would silently break ingestion.

### 30-minute host insights

`assets/host-insights.sh` emits **one** compact JSON line per tick: CPU busy% from a
real `/proc/stat` delta, load averages against effective capacity, server-wide RAM, and
per-disk usage for every real filesystem.

All figures are **server-wide, not per-user**. Inside a container, `scope` becomes
`"container"` and both the host view and the cgroup limits are reported; capacity is
always the *effective* limit, so a 2 GB container never reports "3% of 64 GB".

Keep it in its own dataset (Kind = Metrics), not the logs dataset.

## Step 6 — Verify

Re-run the audit, then confirm in Axiom with `assets/queries.axiom`. The three that
matter most:

```apl
pm2-logs | where _time > ago(15m) | summarize count() as events, max(_time) as newest
pm2-logs | where _time > ago(1h) | summarize count() by machine
pm2-logs | where _time > ago(1h) and machine == "web-01" | limit 1
```

The third is the negative check. Empty means the tags did **not** land — a typo, a
locked schema dropping unknown fields, or Vector not restarted after the env file
changed. `mv-expand disks` gets per-disk rows from the insights dataset.

## Reference material

| File | Contents |
|---|---|
| `references/restart-survival.md` | `pm2 save`/`startup`/dump drift, dead Node paths, containers |
| `references/version-pinning.md` | pinned Vector version, arch matrix, drift policy |
| `references/tagging-and-axiom-schema.md` | tags, reserved names, locked schemas, cardinality |
| `references/host-insights.md` | field reference, container semantics, cadence checks |
| `references/risk-tiers.md` | tier definitions, consent protocol, credential handling |
| `references/vector-axiom-sink.md` | sink options, beta status, retries, buffers |
| `references/pm2-log-layout.md` | paths, naming, `merge_logs`, `log_type`, rotation |
| `references/existing-collectors.md` | Vector/fluent-bit/syslog detection, duplicate ingest |
| `references/troubleshooting.md` | symptom → cause → fix |

## Verified behaviour

These were tested against the pinned binary, not assumed:

- `parse-app.vrl` handles `-out-<pid>`, `-error-<pid>`, `merge_logs` (no pid), dashed app
  names, out-of-tree custom paths, and the `pm2.log` daemon log.
- `._time` must be a **field path**. A bare `_time = ...` parses fine and silently
  assigns a local VRL variable, leaving Axiom to default timestamps to ingest time.
- `set!` inside a `for_each` closure does **not** reach the event. Tags accumulate into a
  local object and are merged once outside the loop.
- VRL cannot enumerate environment variables; each supported tag is listed explicitly.
- The `exec` source defaults `include_stderr = true`; the insights template sets it false.
- A config with neither `region` nor `url` passes `vector validate`.