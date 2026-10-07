# Risk tiers and the consent protocol

## Why tiers exist

This skill touches production process managers on live servers. A mistake is an
outage, not a bug report. So the default is **audit-only**, and every write requires
explicit consent naming the action.

## The tiers

| Tier | Meaning | Examples |
|---|---|---|
| **READ** | No state change whatsoever | the entire audit; `pm2 jlist`; `systemctl cat`; reading `/proc`; `probe-network.sh` |
| **SAFE** | Additive, reversible, touches no running workload | write a new `vector.toml`; create `/var/lib/vector`; write the env file `0600`; set a tag value; add an extra tag |
| **CHANGE** | Alters runtime behaviour, needs a service start or restart | `systemctl enable --now vector`; editing an *existing* Vector config; adding a second `file` source; Vector upgrade |
| **RISKY** | Can cause an outage or lose data | `pm2 save`; `pm2 startup`; `pm2 unstartup`; `pm2 restart`/`reload`; changing `out_file`/`error_file`; `pm2 flush`; deleting rotated logs; any `truncate` |

## Consent rules

1. **Approval is per tier.** Approving tier N never implies N+1.
2. **RISKY is never executed by the skill.** Generate the command, explain the
   consequence, let the human run it.
3. **RISKY is confirmed individually**, by number, even under a blanket approval.
   A confirmation for one `pm2 save` is not consent for a different one.
4. **Default to nothing.** When the user is ambiguous, silent, or has gone off-topic,
   apply no actions and report.
5. **An audit-only request does zero writes.** "Check my setup" ends at the report.
6. **Disclose what was read.** READ tier still needs a plain statement of what was
   inspected.

## Proposing

Every action gets a row:

```markdown
| # | Action | Command | Tier | Why | Blast radius | Rollback |
|---|--------|---------|------|-----|---------------|----------|
| 1 | Enable collector | systemctl enable vector | CHANGE | disabled at boot; logs vanish on reboot | collector starts at next boot | systemctl disable vector |
| 2 | Re-snapshot PM2 | pm2 save | RISKY | dump holds 7, 3 live → would drop: worker, cron, api-v2 | 4 apps lost on next reboot | restore dump.pm2.bak |
```

"Blast radius" must be concrete. "Could affect things" is not acceptable.

## Applying

- SAFE and CHANGE: execute after approval, one at a time, verifying as you go.
- RISKY: hand over the command, do not run it.
- After each action, re-check the invariant it was supposed to fix.
- At the end, report before/after and re-run the audit.

## Credential handling

The Axiom token is a write credential for your dataset. Anyone holding it can
ingest, and possibly read, your logs.

- **Never** write a real token into the repo, a report, or chat output.
- The env file must be mode `0600` or `0400`. `validate-tags.sh` fails otherwise.
- The token is read at **runtime** by VRL via `get_env_var`, never interpolated
  into the config file.

### Why not `${AXIOM_TOKEN}` in the config

The obvious config is:

```toml
token = "${AXIOM_TOKEN}"   # does NOT work as shipped
```

Vector **disables environment-variable interpolation in config files** unless
`--dangerously-allow-env-var-interpolation` is passed. And `VECTOR_STRICT_ENV_VARS`
defaults to `true`, meaning a missing variable is a **hard load failure** — the
config refuses to start rather than degrading.

That flag is a security control: it exists because a log producer that controls a
templated field could otherwise write to arbitrary destinations.

The approach here avoids it entirely. `apply-tags.vrl` reads the env vars with
`get_env_var()`, which is a normal VRL function and needs no flag:

```vrl
value, terr = get_env_var("VECTOR_TAG_MACHINE")
```

So the env file supplies credentials at runtime, with no dangerous flags and no
secrets in the config.

## `AXIOM_REGION` is optional

Unset by default. Vector's `axiom` sink then uses Axiom's default base domain,
which is correct for most organizations.

Set it only when Axiom → Settings → General shows a **non-default edge
deployment**:

```
us-east-1.aws.edge.axiom.co
eu-central-1.aws.edge.axiom.co
```

Setting it wrongly routes data to the wrong edge deployment — strictly worse than
leaving it unset. When validation sees a value, it rejects one with a scheme or a
path.

## What is genuinely irreversible

Some things cannot be rolled back, and must be stated as such rather than given a
token rollback command:

- `pm2 flush` — deletes log content
- deleting rotated logs
- `pm2 save` when the dump is a superset — overwrites the previous snapshot
- Axiom **trimming** a dataset (deletes blocks) and **deleting fields** (values
  remain in storage but become unqueryable)
- vector `buffer.when_full = "drop_newest"` — discards by design

For these, say "cannot be undone" instead of offering a rollback.

## Asking the user

Lead with the headline findings, especially the restart-survival matrix and any
`pm2 save` drift. Then ask which numbered actions to execute.

Offer: "all SAFE", "all SAFE + CHANGE", "audit only", and free text. Confirm RISKY
items one at a time.

If the reply is unclear, ask again rather than guessing. The cost of an unnecessary
question is a sentence; the cost of a wrong `pm2 save` is an outage.