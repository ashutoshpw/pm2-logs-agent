# PM2 log layout

Everything the filename tells you, and where the default assumptions break.

## Default location

```
$HOME/.pm2/logs/
```

Overridable per user via `PM2_HOME`, which is the usual cause of "the glob matches
nothing" when auditing as root against a deploy user's logs.

## Default filenames

```
<app name>-out-<pid>.log
<app name>-error-<pid>.log
```

One file per pid, so a cluster-mode app with 8 instances produces 16 files. Handlers
are `out` and `error` — **not** `stdout`/`stderr`.

| Variant | Example |
|---|---|
| default | `api-out-0.log`, `api-error-0.log` |
| `merge_logs: true` | `api-out.log`, `api-error.log` |
| daemon log | `$PM2_HOME/pm2.log` — **outside** `logs/` |

`merge_logs` drops the pid suffix (cluster mode only), which is why a pid-less
file is not an anomaly.

## The daemon log is outside `logs/`

`pm2.log` records process lifecycle — start, exit, restart — and lives at
`$PM2_HOME/pm2.log`, **not** in `$PM2_HOME/logs/`.

`~/.pm2/logs/*.log` misses it entirely. That log is where you find out an app is
crash-looping, so omitting it loses exactly the signal you want during an incident.

`render-vector-config.sh` adds it automatically when present.

## Custom paths — the biggest silent gap

PM2 apps may set `out_file` / `error_file` to any path:

```javascript
{ out_file: "/var/log/myapp/api.log", error_file: "/var/log/myapp/api-err.log" }
```

Those files are outside `~/.pm2/logs/`, so a config that globs only the default
directory **silently misses them**. No error, no warning — just absent data.

This is why the include globs are derived from `pm2 jlist`, never hand-written:

```bash
pm2 jlist | jq -r '.[] | .pm2_env.pm_out_log_path, .pm2_env.pm_err_log_path'
```

`render-vector-config.sh` accepts repeatable `--log-glob` for exactly this.

## Log format

| Setting | Effect |
|---|---|
| `log_type: "json"` | structured JSON lines instead of raw text |
| `--time` | prefixes a standard timestamp |
| `log_date_format` | custom prefix format |
| `merge_logs: true` | no pid suffix |

`log_type: "json"` is the single highest-value change for log quality. With JSON,
the payload's own fields land in Axiom as queryable columns instead of one
opaque `message`. Apps can also set `logger` per app.

## Logging disabled

```javascript
{ out_file: "/dev/null", error_file: "/dev/null" }
```

Produces no logs at all. A deliberate PM2 configuration, not a pipeline fault — but
it means an app that looks "silent" may be silent by design. The audit flags it
separately for exactly this reason.

## Log types

```bash
pm2 logs                      # all apps, streaming
pm2 logs api --lines 1000     # last 1000 lines for one app
pm2 logs --json               # structured output
pm2 logs --err --lines 0      # flush the view buffer
pm2 flush                     # EMPTY the log files — RISKY
```

`pm2 flush` deletes log content and cannot be undone.

## Rotation

### pm2-logrotate (module)

```bash
pm2 install pm2-logrotate
pm2 set pm2-logrotate:max_size 10M
pm2 set pm2-logrotate:retain 7
pm2 set pm2-logrotate:compress true
```

Compresses rotated files to `.log.N.gz`. Those do **not** match `*.log`, which is
correct — they are history, not live files.

### Native logrotate

```bash
sudo pm2 logrotate -u deploy
```

Writes `/etc/logrotate.d/pm2-deploy`:

```
/home/deploy/.pm2/pm2.log /home/deploy/.pm2/logs/*.log {
        rotate 12
        weekly
        missingok
        notifempty
        compress
        delaycompress
        copytruncate
        create 0640 deploy deploy
}
```

Note it covers `pm2.log` explicitly — another reason to include it in the pipeline.

## The copytruncate tail-loss window

`copytruncate` copies the file then truncates it in place. Vector tracks a byte
offset. Anything written **between Vector's last read and the truncate** can be
lost, because the file is truncated at the same offset Vector is tracking.

The window is small, but it is real and it clusters during log bursts — exactly
when you most need the logs.

Mitigations, in order of preference:

1. `delaycompress` on the logrotate side **plus** including the **first rotated
   file** in Vector's `include`. Vector then re-reads it and recovers the gap.
   This is what Vector's own docs recommend.
2. `fingerprint.strategy = "checksum"` (the default) — survives rotation
   strategies that reuse inodes.
3. Avoid `copytruncate` entirely if logrotate can use rename+create.

## Multi-line traces: two traps that both fail silently

**TOML single quotes are literal.** Backslashes are not escapes there, so every
regex metacharacter class needs ONE backslash. Writing `\s` delivers a literal
backslash-then-s to the regex engine, which matches nothing.

`vector validate` passes either way, because `\s` is a syntactically valid regex
that simply never matches. Only a behavioural test catches this.

**`start_pattern` must match ordinary log lines.** With
`mode = "continue_through"`, a line matching neither `start_pattern` nor
`condition_pattern` is swallowed as a continuation and buffered until the
timeout. So an exception-only start pattern — the intuitive choice — silently
drops ALL normal logging.

Measured on 0.59.0: a normal log file with an exception-only `start_pattern`
produced **0 events**. The working shape:

```toml
[sources.pm2_logs.multiline]
mode = "continue_through"
start_pattern = '^'                                  # every line can begin a record
condition_pattern = '^\s+at\s|^\s*\^+\s*$|^\s*(?:[A-Za-z_$][\w$]*(?:Error|Exception)\b|Error:)'
timeout_ms = 1000
```

`start_pattern = '^'` matches everything, so `condition_pattern` alone decides
what gets folded in. Verify with `vector vrl` against a real frame, not by
inspection.

## Multi-line traces

Without aggregation each `at ...` frame becomes its own Axiom row. `mode` is
required alongside both `condition_pattern` and `start_pattern` on 0.59.0. This
is the one genuinely app-specific part of the pipeline — Java and Python
tracebacks need different `condition_pattern` values.

The pattern set actually shipped is in `assets/vector.toml`; see the section
above for the two traps that make a plausible-looking pattern ingest nothing.

`timeout_ms` bounds how long Vector waits for a continuation line. Too low splits
traces; too high delays the first line of the next event.

## Rotation filenames and what gets re-uploaded

`pm2-logrotate` appends `dateFormat` (default `YYYY-MM-DD_HH-mm-ss`):

```
api-out-0.log                            live
api-out-0.log-2026-10-07_12-00-00        rotated
api-out-0.log-2026-10-07_12-00-00.gz    rotated + compressed
```

**The rotated name matches `*.log`.** An `include` of `*.log` with only
`exclude = ["*.log.*.gz"]` therefore re-uploads every rotated, uncompressed file
— once per run, forever, and again after any restart that loses its checkpoint.

The exclude list needs both forms:

```toml
exclude = [
  "/home/deploy/.pm2/logs/*.log-*.gz",
  "/home/deploy/.pm2/logs/*.log.*.gz",
]
```

## Glob syntax

Vector uses the Rust `glob` crate:

- `*` — any run of characters except `/`
- `**` — across directories
- `[a-z]` — character class

```toml
include = [
  "/home/deploy/.pm2/logs/*.log",
  "/home/deploy/.pm2/pm2.log",
]
exclude = [
  "/home/deploy/.pm2/logs/*.log.*.gz",
]
```

`exclude` is applied **after** globbing, so an `include` pattern reaching into
large unreadable directories costs real time before anything is filtered.

## Permissions

The `vector` process must be able to read the files **and execute the parent
directories**. Fix with a group:

```bash
usermod -aG deploy vector
```

or an ACL, which is narrower:

```bash
setfacl -R -m u:vector:rX /home/deploy/.pm2/logs
```

In systemd, `ProtectHome=read-only` still permits reading `/home`.
`ProtectHome=true` would block the log directory and Vector would ingest nothing
without reporting an error. The unit file explains this inline.