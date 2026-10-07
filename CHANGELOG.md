# Changelog

## 1.1.0

Bugs found by a field report, all verified against the pinned Vector binary.

### Fixed — configuration

- **Axiom token never reached the sink.** The sink carried a literal
  `REPLACE_AT_INSTALL_TIME` placeholder and no code read `AXIOM_TOKEN`, so the
  pipeline could not have authenticated. The sink's `token` and `dataset` are
  config values rather than VRL, so `{{ get_env_var!(...) }}` is a parse error;
  they now use `${VAR}` interpolation with the unit setting
  `VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true`. A missing variable now
  aborts config load instead of silently 401ing every batch.
- **`--require-healthy` was passed without a value**, which stops the service
  parsing its own command line.
- **Every `$` in a comment is substituted once interpolation is on.** A comment
  containing `${VAR}` aborted the whole config. Written as `$${VAR}`.
- **Multi-line patterns used `\\s` inside single-quoted TOML**, where backslashes
  are literal, so the regex matched nothing while `vector validate` still passed.
- **`start_pattern` matched only exceptions.** Under `continue_through` a line
  matching neither pattern is swallowed as a continuation, so this silently
  dropped ALL normal logging — measured 0 events from a normal log file.
- **The insights pipeline was never wired to a config.** It now loads as a second
  `--config` argument to the same process. Component ids were renamed to avoid a
  namespace collision, and the duplicate `data_dir` global was removed.
- **Rotated archives were re-uploaded on every run.** `pm2-logrotate` names
  rotated files `<file>.log-<date>`, which matches the `*.log` include glob. The
  exclude list now covers both rotated forms.

### Added

- `scripts/validate-token.sh` — proves ingest permission by writing one probe
  record, tagged `kind = "pm2-log-agent-selftest"` and `self_test = true` so it
  can be found and deleted. Never prints the token. Handles the two Axiom URL
  shapes, which differ between the default domain and an edge deployment.
- `scripts/smoke-test.sh` — runs the real pipeline with the Axiom sink swapped
  for console, and asserts events actually come out. `vector validate` does not
  do this.
- `scripts/install.sh` — installs env file, ACLs, configs, insights script and
  the unit. Leaves the unit **disabled** on purpose.
- `scripts/uninstall.sh` — removes all of it, restoring backups, and only
  uninstalls `pm2-logrotate` when this skill installed it.

### Changed

- Both streams default to one dataset, **`pm2-service-logs`**, separated by a
  `kind` field (`pm2_log` / `host_insights`). `--insights-dataset` splits them.
  Retention is a dataset-level setting and is not managed here.
- Rendered configs are stamped `# managed-by: pm2-logs-agent`, and the audit
  skips its own config instead of reporting a false duplicate-ingest conflict.
- Audit enumerates collector **units** and reports each one's `ExecStart`,
  binary, version and config paths. An unrelated `vector.service` no longer
  counts as "collector enabled at boot".
- Audit prunes `/etc/vector/examples` from the config count, extracts
  `unstable_restarts` to catch restart loops, tests whether the Vector user can
  actually **read** each log file, and reports log files belonging to no live app.
- RISKY actions: "never execute" replaced with re-check, back up, then hand over
  a single command.

### Fixed — tooling

- The Vector release tarball extracts to `vector-<arch>-<libc>/bin/`, not a
  version-prefixed path; the installer was looking for the wrong one.
- ACLs now include a **default** ACL, without which every file created by
  rotation becomes unreadable and ingestion stops silently after the first
  rotation.

## 1.0.0

### Changed
- Skill payload lives at `skills/pm2-logs-agent/`, so the repo README, licence,
  CI and test suite no longer ship into every agent install.

Initial release.
