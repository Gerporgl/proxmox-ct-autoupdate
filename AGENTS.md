# AGENTS.md

Context for AI agent sessions working on this repo. **Keep this file up to date**: when
you learn a Proxmox/ZFS/umoci behaviour the hard way, record it here and in a test.

## What this project is

`pve-ct-autoupdate.sh` — one self-contained bash script for Proxmox VE 9 on ZFS. It walks
`/etc/pve/lxc/*.conf`, and for containers that **opt in** through a fenced code block in
their config comments (written from the Proxmox UI *Summary* field), it refreshes the
container rootfs from an OCI image when the registry digest changed:

`skopeo inspect` → `skopeo copy` → `pct stop` → `zfs snapshot` → wipe rootfs →
`umoci raw unpack` → `pct start` → store digest → prune snapshot.

Everything else is skipped silently. No lib/ split on purpose: one file, cron friendly.

## Layout

| path | role |
|---|---|
| `pve-ct-autoupdate.sh` | the whole implementation (config → parse → resolve → update → notify) |
| `tests/run-tests.sh` | 117 assertions against fake `pct/zfs/skopeo/umoci/pvesm` in `tests/mockbin/` |
| `examples/` | `ct-conf.example`, `notify.sh` (ntfy hook), `crontab` |
| `README.md` | user-facing docs: opt-in grammar, options, env vars, limitations |
| `docs/PLAN.md` | original design + the approved decisions |
| `poc/` | the owner's personal proof of concept — **gitignored, never published** |

## Working here

```sh
./tests/run-tests.sh          # must stay green; add a case for every fix
bash -n pve-ct-autoupdate.sh
```

Tests are mock based (no PVE/ZFS/registry in the sandbox) and run as non-root via
`PVE_AUTOUPDATE_ALLOW_NON_ROOT=1`. Never hardcode hostnames, registries, ntfy URLs or real
CTIDs in tracked files — fixtures use `registry.example.com`, `ct 200/100`.

## Commit and push etiquette

- **After finishing a task, confirm with the user before committing and before pushing.**
  Do not treat "make it work" as permission to publish. Only act on an explicit request or
  an explicit standing authorization given for that session.
- Commit with the **repo's configured git identity** — plain `git commit`, never
  `git -c user.name=…`. Do not invent a fake identity for a public repo; GitHub renders an
  unknown email as an unlinked name.
- Run `./tests/run-tests.sh` (green) and `bash -n pve-ct-autoupdate.sh` before any commit.
- Never amend, rebase or force-push `main`, and never rewrite published history, without
  explicit approval; use `--force-with-lease` when rewriting is authorized.
- Commit messages: no personal hosts, registries, ntfy topics or real CTIDs.

## Gotchas already paid for (do not relearn them)

- **`/etc/pve/storage.cfg` stanza headers carry a colon**: `zfspool: local-zfs`, not
  `zfspool local-zfs`. A parser that ignores the colon fails with "storage not found".
- **A ZFS pool name can contain a slash**: `pool rpool/data`, giving datasets such as
  `rpool/data/subvol-<ctid>-disk-0`. PVE also moved layouts between versions
  (`<mountpoint>/subvol-...` vs `<pool>/data/subvol-...`). **Never build the path** — ask
  `zfs list` for the dataset whose last component is the volid, then validate that the
  directory to wipe is exactly that dataset's mountpoint (`zfs list -o name -d 0 <path>`).
- **`umoci raw unpack [options] --image <image>[:<tag>] <rootfs>`**: every option must come
  *before* the positional rootfs, otherwise umoci reports
  `invalid number of positional arguments: expected <rootfs>`.
- **`/etc/pve/lxc/<ctid>.conf` is cluster-wide**, the ZFS dataset is per-node: absent
  datasets must be skipped quietly, not notified.
- **`pct stop` errors when the container is already stopped**; `pct start` blocks. Verify
  with `pct status` afterwards instead of polling loops.
- ZFS **snapshot names are limited to 32 chars** — keep `autoupdate-<ts>` short.
- `set -euo pipefail` traps: `((i++))` returns 1 when the value was 0 and kills the script;
  use `i=$((i+1))`. A function returning non-zero as a plain statement also aborts — use
  `cmd || rc=$?`.
- mawk (Debian default awk) makes `split()` produce an empty first field for indented
  lines: strip the leading whitespace before splitting storage.cfg continuation lines.
- **`skopeo inspect --format` is a Go template**: missing labels render as `<no value>`,
  a nil `.Created` as `<nil>` (normalize both), and a `--format` string must embed *real*
  tab characters (`$'\t'`), not `\t`, because the text between `{{...}}` actions is literal.
  Older skopeo may reject the label lookups, so `remote_image_info` always falls back to a
  digest-only inspect — metadata must never be a reason to skip an update.
- The state dir keeps `<ctid>.digest` (single line, authoritative for the digest compare)
  and `<ctid>.meta` (`key=value`, image metadata of the last applied update). Keep the
  digest file one line; putting metadata in it would break the digest comparison.

## Behaviour rules the owner decided

- Rollback **only** for failures at or after the rootfs wipe. Pull / stop / snapshot
  failures leave the rootfs untouched, clean the OCI staging dir and continue with the
  next container. **Any rollback aborts the whole run** and never commits the digest.
- Snapshots are named `autoupdate-<timestamp>`; keep 0 by default; pruning only ever
  matches that own prefix, so PVE UI snapshots are never touched.
- Opt-in keys: `AutoUpdate=registry` (mandatory, exact), `Image` (tag mandatory, `%3A`
  decoded), optional `SnapshotKeep=N`. Unknown keys ignored. `AutoUpdate` anything else =
  disabled. No TLS-insecure option.
- uid/gid map from `unprivileged: 1` → `0:100000:65536` (not parsed from `lxc.idmap`).
- Notifications only for updated containers and failures, `notify.sh <severity> <title>
  <message>`, one per container. A run with nothing to do must stay silent. Title =
  `<hostname> (LXC <ctid>)[: old → new version]`, body = aligned `key  value` lines
  (`Container`, `Image`, `Digest`, `Version`, `Built`, `Source`); the container name always
  uses `hostname:` from the LXC conf, falling back to `LXC <ctid>`. No cross references to
  other projects in this repo's files.
- The rootfs is ephemeral (including Proxmox-created passwords/keys); `mpN:` mounts are
  never wiped and never rolled back — that is intended, document it rather than "fix" it.
