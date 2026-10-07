# Version pinning

The Vector version lives in exactly one place: **`assets/vector-version.env`**.
Nothing else hardcodes a version.

```bash
VECTOR_VERSION=0.59.0            # the pin
VECTOR_KNOWN_GOOD_FLOOR=0.58.0   # oldest version templates are tested against
VECTOR_CI_IMAGE=timberio/vector:0.59.0-debian
```

## Why pin at all

`vector validate` only proves something if it runs against the binary that will
actually run. Validating a 0.59.0-era config against whatever `apt` happens to
offer is not a test.

Three concrete reasons this bites:

1. **Option renames.** `fingerprint_lines` no longer exists; it is now
   `fingerprint.lines`. A config using the old key validates on old versions and
   fails on new ones.
2. **Multiline is version-sensitive.** `[sources.x.multiline]` requires both
   `start_pattern` and `mode` as of 0.59.0. Older configs accepted only
   `first_line_pattern`.
3. **Defaults change.** `zstd` became the compression default in 0.42.0, and
   Axiom's timestamp field moved from `@timestamp` to `_time` at the same
   boundary.

## Installing

```bash
scripts/install-vector-pinned.sh --dry-run     # show what would happen
scripts/install-vector-pinned.sh                # requires root
scripts/install-vector-pinned.sh --force        # replace a different version
```

The script detects architecture **and** libc, downloads the matching release
asset, verifies it against the release's own `SHA256SUMS`, then installs.

Without the checksum gate, "pinned" only means "whatever that URL served". With
it, the install is verifiable.

### Asset matrix

| Arch | deb | tarball |
|---|---|---|
| x86_64 | `vector_<V>-1_amd64.deb` | `vector-<V>-x86_64-unknown-linux-{gnu,musl}.tar.gz` |
| aarch64 | `vector_<V>-1_arm64.deb` | `vector-<V>-aarch64-unknown-linux-{gnu,musl}.tar.gz` |
| armv7l | `vector_<V>-1_armhf.deb` | `vector-<V>-armv7-unknown-linux-{gnu,musl}.tar.gz` |
| armv6l | `vector_<V>-1_armel.deb` | `vector-<V>-arm-unknown-linux-gnu{eabi,leabi}.tar.gz` |

Deb on glibc systems with `dpkg`; tarball on musl (Alpine) or anywhere `dpkg` is
absent. Picking the wrong libc variant fails at exec time with a GLIBC error, which
is why libc is detected rather than assumed.

### Refusing to clobber

Without `--force`, the script refuses to replace a *different* installed version.
Replacing a working collector is a **CHANGE**-tier action and must not happen
silently during what looks like an install.

## Drift policy

The audit compares the installed version to the pin, **asymmetrically on purpose**:

| Installed vs pin | Severity | Rationale |
|---|---|---|
| equal | — | verified |
| **older** | medium | config options may be unsupported or have changed meaning |
| **newer** | info | normally fine; awareness only |

The asymmetry matters. Telling an operator to downgrade a working collector because
the skill's pin is stale is the wrong instinct and would be actively harmful. Newer
is reported so it is visible, not so it is "fixed".

```bash
vector --version | awk '{print $2}' | tr -d v
```

## Testing both versions

CI validates every template against the pin **and** the known-good floor:

```yaml
matrix:
  version: ["0.59.0", "0.58.0"]
```

Two reasons:

1. The pin is recent. 0.59.0 was one day old when pinned, which is thin evidence.
2. Hosts in the field run older versions. Proving the templates work on 0.58.0
   means the skill degrades gracefully instead of hard-failing.

## Upgrading

Upgrade is **CHANGE** tier. It is never automatic. Validate the existing config
against the new binary before switching:

```bash
vector validate --no-environment /etc/vector/pm2-axiom.toml
```

Then read the release notes for sink and source changes between the two versions.
Confirm the Axiom sink is still labelled beta and check whether its options moved.

## The Axiom sink is beta

Independent of version pinning: Vector's `axiom` sink is labelled **beta** at
0.59.0. Delivery is **at-least-once**, so duplicates are possible on retry. Design
queries to tolerate duplicates, and do not build exact-count dashboards on top of
it without deduplication.

## Updating the pin

1. Check the release is stable (not `vdev-*`, not a prerelease — GitHub's
   "latest" endpoint returns the dev channel, so check the release list explicitly).
2. Update `VECTOR_VERSION`, the checksums, and `VECTOR_CI_IMAGE`.
3. Move the old pin to `VECTOR_KNOWN_GOOD_FLOOR`.
4. Update the `matrix.version` list in `.github/workflows/ci.yml`.
5. Update `vector-pinned` in the `SKILL.md` frontmatter metadata.
6. Bump `metadata.version` in `SKILL.md`.

```bash
curl -s "https://api.github.com/repos/vectordotdev/vector/releases?per_page=100" \
  | jq -r '[.[] | select(.prerelease == false and (.tag_name | startswith("vdev-") | not))] | sort_by(.published_at) | reverse | .[0] | .tag_name'
```