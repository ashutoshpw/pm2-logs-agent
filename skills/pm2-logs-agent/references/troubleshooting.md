# Troubleshooting

Symptom → cause → fix. Start by proving where the data stops.

## Prove data is arriving first

```bash
vector tap --inputs-of axiom --duration_ms 5000   # samples without sending
systemctl status vector
journalctl -u vector -n 100 --no-pager
```

`vector tap` does not send anything, so it is safe against a paid endpoint.

## Axiom is empty

| Cause | Check | Fix |
|---|---|---|
| Vector not running | `systemctl status vector` | start it |
| Config fails to load | `journalctl -u vector \| grep -i error` | see the config errors below |
| Sink unhealthy | `vector top`, look for `component_errors_total` | check token and dataset |
| Wrong dataset | confirm `AXIOM_DATASET` | `dataset` in the sink |
| Wrong edge | `region` vs the org's edge deployment | unset it, or set it correctly |
| Schema locked | check the Fields panel | unlock, or declare the fields |
| No matching files | `ls /home/<user>/.pm2/logs/*.log` | fix the include globs |
| Cannot read files | run `sudo -u vector ls <logfile>` | grant group or ACL access |

### Config load errors

| Message | Cause |
|---|---|
| `missing field 'start_pattern'` | multiline needs `start_pattern` **and** `mode` on 0.59.0 |
| `unknown field 'fingerprint_lines'` | renamed to `fingerprint.lines` |
| `missing field 'mode'` on an exec source | `mode = "scheduled"` is required |
| `options -P and --output are mutually exclusive` | `df` flags; handled in `host-insights.sh` |
| buffer rejected | `buffer.max_size` must be ≥ 268435488 for disk |
| nothing configured | an env var is missing and `VECTOR_STRICT_ENV_VARS` is true |

Check with:

```bash
vector validate --no-environment /etc/vector/pm2-axiom.toml
```

### `unknown field` errors

Almost always a version mismatch. Compare against the pin:

```bash
vector --version
grep VECTOR_VERSION assets/vector-version.env
```

Older installed than pinned is a finding. See `version-pinning.md`.

## Some apps are missing

The most common problem, and it is silent.

| Cause | Check | Fix |
|---|---|---|
| custom `out_file`/`error_file` | `pm2 jlist \| jq -r '.[].pm2_env.pm_out_log_path'` | add the path to `include` |
| `merge_logs` changes the filename | `ls .pm2/logs/` | use the rendered globs, not hand-written ones |
| cluster mode, one file per pid | `ls .pm2/logs/` | `*.log` covers all pids |
| logging disabled | `out_file: /dev/null` | deliberate; not a pipeline fault |
| wrong `PM2_HOME` | `pm2 jlist` paths vs your glob | pass `--pm2-home` |
| auditing as the wrong user | `echo $PM2_HOME` | run the audit as the deploy user |

```bash
pm2 jlist | jq -r '.[] | "\(.name)\t\(.pm2_env.pm_out_log_path)"'
```

## Duplicate events

The sink is **at-least-once**. Normal on retry; a problem if constant.

| Cause | Check | Fix |
|---|---|---|
| genuine retries | `component_errors_total` > 0 | look at the underlying error |
| **two collectors on the same files** | `grep -rls '\.pm2/logs' /etc/vector` | remove the duplicate source |
| `data_dir` lost | `ls /var/lib/vector` | checkpoints gone → re-reads from `read_from` |
| `read_from = "beginning"` after restart | config | switch to `"end"` post-backfill |

Checkpoints live in `data_dir`. If that directory is not persistent (a container
without a volume), Vector re-reads from the start after every restart — which
combined with `beginning` looks exactly like runaway duplication.

## Historical flood on first run

`read_from = "beginning"` ingests every existing line.

| Symptom | Cause | Fix |
|---|---|---|
| huge first ingest | no `ignore_older_secs` | set it for the first run |
| expensive dataset | large backlog | switch `dataset`, truncate later |
| ingestion still queued days later | the backlog is real | wait, or start fresh with `read_from = "end"` |

Cap the backfill, then switch to `"end"`:

```bash
# first run
render-vector-config.sh --first-run --out /etc/vector/pm2-axiom.toml
# after the backfill completes
render-vector-config.sh --cutover --out /etc/vector/pm2-axiom.toml
systemctl reload vector
```

## Stack traces split across rows

| Cause | Fix |
|---|---|
| no multiline config | add `[sources.x.multiline]` |
| patterns do not match the framework | tune `start_pattern`/`condition_pattern` |
| `timeout_ms` too low | raise it; too high delays the next event |
| `mode` missing or wrong | `mode = "continue_through"` for Node traces |

## 401 / 403 from Axiom

| Code | Cause | Fix |
|---|---|---|
| 401 | wrong or expired token | regenerate it |
| 403 | token lacks ingest for that dataset | scope the token to the dataset |
| 403 | `org_id` missing | only needed for **personal** tokens |

Prefer a service-account token; then `org_id` is not needed.

## 429 rate limited

| Cause | Fix |
|---|---|
| genuine rate limit | `request.concurrency` is adaptive by default; leave it |
| one host outpacing its quota | increase `batch.timeout_secs` so batches are larger |
| duplicated ingest | see above — fix the duplicate first |

## Tags missing from events

```apl
pm2-service-logs | where _time > ago(1h) and machine == "web-01" | limit 1
```

Empty means the tag did not land.

| Cause | Check | Fix |
|---|---|---|
| Vector not restarted after the env file changed | `systemctl show vector -p ActiveEnterTimestamp` | restart or reload |
| dataset schema locked | Fields panel | unlock or declare the field |
| tag not in the VRL `TAGS` array | `apply-tags.vrl` | add it, then `validate-tags.sh` |
| typo'd key | Fields panel | fix the source — deleted fields self-heal |
| env file mode too open | `validate-tags.sh` | `chmod 600` |
| env var value empty | grep the file | remove the line or set a value |

## Insights not arriving

| Cause | Check | Fix |
|---|---|---|
| script not executable | `ls -l /opt/pm2-logs-agent/host-insights.sh` | `chmod +x` |
| wrong path in the config | `command` in the unit | absolute path |
| `include_stderr` left at the default | template | set `false` |
| `decoding.codec` left at `bytes` | template | set `"json"` |
| cadence wrong | `scheduled.exec_interval_secs` | 1800 |
| not restarting the process | `journalctl -u vector` | confirm the exec source started |

```bash
/opt/pm2-logs-agent/host-insights.sh | jq .    # must be ONE line of valid JSON
```

## Everything looks fine but there are no logs

The silent cases, in likelihood order:

1. **PM2 did not come back after a reboot** — collector healthy, zero data
2. **The collector is not enabled at boot** — apps return, logs vanish
3. **The apps log to `/dev/null`**
4. **PM2 apps are in `errored` state** and produce nothing
5. **`read_from` and `data_dir` are misconfigured** after a container restart

Check `restart-survival.md` and the audit's restart matrix. Query 1 in
`assets/queries.axiom` distinguishes "broken pipeline" from "quiet apps" — always
run it before concluding anything about application health.