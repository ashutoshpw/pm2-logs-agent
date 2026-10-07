# Existing collectors

Before adding a pipeline, find out what is already reading these files. Two
collectors over the same globs means every event is ingested twice and billed
twice, with no error anywhere.

## Detection

```bash
systemctl list-unit-files | grep -Ei 'vector|fluent|filebeat|logstash|promtail|rsyslog|syslog'
ls /etc/vector /etc/fluent-bit /etc/filebeat /etc/logstash 2>/dev/null
pm2 ls | grep -E 'pm2-syslog|pm2-logrotate'
```

## Duplicate ingest is critical severity

The audit greps existing Vector configs for `.pm2/logs`:

```bash
grep -rls '\.pm2/logs' /etc/vector
```

A hit means a pipeline already ingests these files. The correct options:

| Option | When |
|---|---|
| extend the existing config | it already ships to Axiom, or already has the region/token |
| exclude these paths from the new one | different backends or datasets |
| abandon the new pipeline | the existing one already does the job |

Never add a second `file` source over the same glob and hope for the best.

## The other collectors

### fluent-bit / fluentd
Common in Kubernetes. If it runs **on the host**, check its `in_tail` inputs for
PM2 paths. If it runs **in-cluster**, PM2 logs are not visible to it without a
hostPath mount, so there is no overlap.

### filebeat
Same idea; check `filebeat.inputs` paths.

### rsyslog + pm2-syslog

[`pm2-syslog`](https://github.com/pm2-hive/pm2-syslog) redirects PM2 and app logs
into `/var/log/syslog`, then something else forwards them.

```bash
pm2 install pm2-syslog     # requires rsyslog listening on UDP 514
```

It adds a hop and a UDP hop is lossy, which is why Vector reading the files
directly is the recommendation. But it exists and is a legitimate choice for
hosts whose syslog is already the collection backbone — in that case, extend the
existing path rather than adding a parallel one.

```bash
grep -E 'imudp|port="514"' /etc/rsyslog.conf
```

### promtail
Usually container logs only. Check the `clients` config for a host-path target.

### Vector already installed for other logs

The common and benign case: Vector is shipping nginx or app logs to a different
backend. That is still the right place to add PM2 logs rather than running a second
Vector — and it means reading the existing config to match conventions:

```bash
cat /etc/vector/vector.toml
vector list --format json
```

Reuse the existing dataset naming, region, buffer sizing and retry policy. A second
sink in the same process is cheap; a second process is not.

## What to report

For each collector found:

| Field | Why |
|---|---|
| name and version | whether it can be extended |
| unit enabled at boot | **silent-blackout risk** — a collector that is installed but not enabled means logs vanish on reboot |
| config paths | which files to read for conventions |
| reads PM2 logs | duplicate-ingest risk, critical |
| existing dataset/region | what to match |

The `unit enabled at boot` field is the one people miss. A collector installed but
not enabled looks complete in `systemctl list-unit-files` and produces nothing after
a reboot.

## Deciding

```
already reading PM2 logs to the right backend?
  yes -> extend it. No second pipeline.
  no, but a collector runs here?
    yes -> add a source/sink to that process.
    no -> new Vector pipeline (this skill's default path).

Already have OTel/fluent-bit and a central config system?
  yes -> add a file input there, keep PM2 out of Vector entirely.
```

That last branch is legitimate. If your organisation standardises on OpenTelemetry
or fluent-bit, adding Vector purely for PM2 is the wrong answer.