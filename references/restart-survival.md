# Restart survival

Will this box come back correctly after a reboot? Four independent failure modes,
then the matrix that makes them matter.

## The core mechanism

PM2 keeps its process list **in memory**. A reboot clears it. Two things restore it:

| Command | What it does |
|---|---|
| `pm2 startup` | generates a systemd unit (`pm2-<user>.service`) that runs `pm2 resurrect` at boot |
| `pm2 save` | snapshots the current process list into `$PM2_HOME/dump.pm2` |

Both are required. `pm2 startup` without `pm2 save` resurrects nothing. `pm2 save`
without `pm2 startup` writes a snapshot nothing reads.

`pm2 resurrect` is what actually starts the apps from the snapshot.

---

## Failure mode A — the unit is missing or disabled

```bash
systemctl cat pm2-$(id -un).service      # exists?
systemctl is-enabled pm2-$(id -un).service
```

Missing or `disabled` both mean nothing resurrects. These look identical from the
outside:

- `pm2 startup` was never run
- `pm2 unstartup` was run later, which removes the unit
- the unit exists under a different name (`--service-name` customises it)

**RISKY to fix.** `pm2 startup` prints a `sudo env PATH=... pm2 startup systemd -u USER --hp HOME`
command that the operator must run. Generate it, do not execute it.

## Failure mode B — the unit points at a dead Node path

The single most misleading failure in this whole area.

PM2 bakes a **versioned Node path** into the unit:

```
ExecStart=/usr/bin/env PATH=/home/deploy/.nvm/versions/node/v16.20.0/bin:... pm2 resurrect
```

After a Node upgrade that directory is gone. The unit still exists, is enabled, and
`systemctl cat` looks perfectly fine. **It fails silently at boot and no apps
return.**

```bash
systemctl cat pm2-$(id -un).service | grep -oE '/[^ ]*/(node|bin/pm2)' | head -1
```

Fix is **not** a hand edit of the path. PM2's own docs require:

```bash
pm2 unstartup
pm2 startup
pm2 save
```

**RISKY** — all three commands.

Also verify `--hp` matches the current `$HOME`; a unit generated for a different
home path will resurrect into the wrong `PM2_HOME`.

## Failure mode C — the snapshot does not match reality

**`pm2 save` overwrites `dump.pm2` with the CURRENT process list. It is not a merge.**

This is the trap. Compare the live list against the snapshot:

```bash
pm2 jlist | jq -r '.[].name' | sort > /tmp/live
jq -r '.[].name' "$PM2_HOME/dump.pm2" | sort > /tmp/dump
comm -23 /tmp/dump /tmp/live    # in dump, not running -> WOULD BE DROPPED
comm -13 /tmp/dump /tmp/live    # running, not in dump -> UNSAVED
```

| Live | Dump | Meaning | Severity |
|---|---|---|---|
| N apps | no dump | nothing will resurrect | critical |
| N apps | dump older than last app start | apps added since are unsaved | high |
| **3 apps** | **dump has 7** | **`pm2 save` would drop 4** | **critical** |
| 7 apps | dump has 3 | running apps unsaved | critical |
| matches | matches | clean | ok |

The third row is why "just run `pm2 save`" must never be offered as a default fix.
Running it can make the reboot snapshot **worse** than it is right now.

Decide deliberately whether the apps in the dump are meant to be running. If they
should be, start them first, then save. If they were decommissioned, saving is
correct — but that is a decision, not a reflex.

`verify-post-change.sh` reports this as `pm2.save_no_data_loss`.

## Failure mode D — the collector does not survive

PM2 coming back is only half of it. If the log collector is not enabled at boot,
every app returns and **no logs arrive anywhere**.

```bash
systemctl is-enabled vector
```

## The matrix

| | Collector enabled at boot | Collector NOT enabled |
|---|---|---|
| **PM2 saved + unit enabled** | correct | ⚠️ **apps return, all logs vanish** |
| **PM2 NOT saved** | ⚠️ **pipeline healthy, zero data** | obvious outage |

Both ⚠️ cells fail **silently**. Nothing errors. A dashboard shows a healthy
collector and empty queries, and the natural conclusion — "the apps are quiet" —
is wrong. The apps were never restarted at all.

Surface this table whenever either ⚠️ cell applies.

## Containers

Inside a container, `pm2 save` and `pm2 startup` are the wrong mechanism:

- there is no systemd to enable a unit in
- the container filesystem may not persist `$PM2_HOME`
- `pm2 resurrect` from an entrypoint is the correct pattern

```dockerfile
CMD ["pm2", "runtime", "ecosystem.config.js"]   # runs in foreground
```

The audit detects containerisation and downgrades the `pm2 save` findings to
informational, because reporting "critical, run pm2 save" on a container is
actively misleading.

## Checking without rebooting

`systemctl cat` and `is-enabled` verify the unit. To verify the snapshot is
loadable, `pm2 resurrect` is the real test — but it starts processes, so it is
**RISKY**. `verify-post-change.sh` checks the invariant by comparing lists instead,
which is read-only.

## Rotation interaction

`pm2-logrotate` and native logrotate use `copytruncate`, which copies then truncates
in place. Vector tracks a byte offset; anything written between Vector's last read
and the truncate can be lost. Vector's docs recommend `delaycompress` on the
logrotate side plus including the **first rotated file** in `include`, so Vector can
re-read it and recover the gap.

`assets/vector.toml` sets `fingerprint.strategy = "checksum"`, which survives
rotation strategies that reuse inodes. `device_and_inode` is faster and breaks on
inode reuse.