# Design plan — Proxmox LXC auto-updater

Status: planning draft (pre-implementation).

## 1. Goal

A cron-runnable shell script that scans all PVE container configs, finds the ones that
explicitly opt in via a fenced markdown block in the config comments, and refreshes their
rootfs from an OCI image only when the remote image digest changed.

Strict opt-in: any container without a *valid* block is skipped silently.

## 2. Upstream facts verified (PVE 9)

- Container configs: `/etc/pve/lxc/<ctid>.conf` (pmxcfs, cluster-wide; identical on every
  node). Universal location on any PVE install — safe default, overridable anyway.
- Storage definitions: `/etc/pve/storage.cfg`, stanza `zfspool <storeid>` with `pool <name>`
  and optional `mountpoint <path>`. Legacy type `zfs` also exists.
- ZFS subvol layout is **version dependent** (`PVE::Storage::ZFSPoolPlugin::path`):
  `path = <pool mountpoint>/subvol-<ctid>-disk-<n>`, default mountpoint `/<pool>`.
  Older installs put datasets under `<pool>/data/...` — which matches the PoC, but must
  never be assumed.
- Official resolver: `pvesm path <storage>:<volid>` → the mounted path PVE itself uses.
  `pvesm status`, `zfs list/get` are used as cross-checks.
- `subvol-*` datasets are ZFS *filesystems* (quota via `refquota`), `vm-*` are zvols.
  Only a filesystem dataset is wipe-and-unpackable → hard requirement.

## 3. Files (proposed)

```
pve-ct-autoupdate.sh      main script (entry point, cron target)
examples/notify.sh        ntfy hook example (generic URL/tag via env)
examples/ct-conf.example  example opt-in block for a container config
examples/cron.example     crontab + optional systemd timer unit
tests/                    self-contained test suite with fake pct/zfs/pvesm/skopeo/umoci
docs/PLAN.md              this file
README.md                 usage, deps, config reference
LICENSE, .gitignore       (poc/ ignored)
```

## 4. Config block grammar (strict)

In `<ctid>.conf`, only lines starting with `#` are considered; a leading `#` and one
optional space is stripped before matching.

```
#```
#AutoUpdate=registry
#Image=registry.example.com/org/app%3Alatest
#```
```

Rules:
- exactly one fenced block (```` ``` ```` or ```` ```md ````), opening and closing fence required
- inside the fence: `Key=value` only, case-insensitive keys, blanks allowed
- `AutoUpdate` must be exactly `registry`; anything else, missing, or duplicated → invalid
- `Image` required; `%3A`-style percent encoding is decoded (PVE/UI friendly form)
  - accepts optional `docker://` prefix, requires `host[:port]/repo:tag`
  - no tag → `latest` (to confirm) ; `latest` is *allowed*, digest pinning is what matters
- any unknown key → invalid (safest) / or ignored (to confirm)
- invalid ⇒ skip container, log at info, **no** notification (not an error, just not ours)

## 5. Rootfs resolution & validation chain

Every step must pass, otherwise the container is skipped (with a logged reason; a real
failure, e.g. a valid opt-in whose storage can't be resolved → notification at warning).

1. `rootfs:` line: strict `^rootfs:[ \t]*([^: \t]+):([^, \t]+)` → `<storeid>:<volid>`
   (extra colons / missing volume / `import-from=` weirdness → reject).
2. `<volid>` must match `^subvol-<ctid>-disk-[0-9]+$` — must belong to this CTID.
3. `storage.cfg`: storeid must exist and be type `zfspool` (legacy `zfs`? to confirm).
   Non-ZFS (lvm, dir, ceph, ...) → silent skip.
4. Resolve the dataset:
   - primary: `pvesm path <storeid>:<volid>`
   - fallback: `zfs list -H -o name,mountpoint -r <pool>` and match a dataset whose last
     component is exactly `<volid>` (handles `/data/` legacy nesting, nested datasets)
5. Validate the dataset itself with ZFS as source of truth:
   - dataset exists, `type=filesystem` (not zvol), `mounted=yes`
   - `zfs get mountpoint` → real directory exists and is *exactly* that mountpoint
     (`zfs list -H -o name -d 0 <path>` must return the same dataset — never a parent)
   - mountpoint is not `legacy`/`none`
   - pool of the resolved dataset == pool from `storage.cfg`
   - `content` allows `images`/`rootdir`, storage not `disabled`
6. Additional guards: run as root, `zfs`, `pct`, `skopeo`, `umoci` present, container's
   rootfs dataset not shared with another `mpN:` mount.

If the dataset cannot be found on this node (cluster case: config is cluster-wide, data is
per-node) → skip quietly with a debug log; only warn-notify if opt-in + local storage.

## 6. Update transaction (per container)

```
flock on /var/lock/pve-ct-autoupdate-<ctid>.lock
  skopeo inspect → remote digest
  digest == stored digest   → nothing to do (no notify)
  skopeo copy → oci:tmp/<ctid>            (validate the pull before touching anything)
  pct status                                (remember was_running)
  pct stop <ctid>                          (ok if already stopped; verify stopped after)
  zfs snapshot <ds>@<prefix>-<timestamp>
  find <mountpoint> -xdev -mindepth 1 -delete
  umoci raw unpack --image tmp:<ctid> <mountpoint> [--uid-map/--gid-map]
  pct start <ctid>                         (only if was_running) → verify status: running
  write digest file
  prune snapshots with our prefix (keep N)
  remove tmp oci layer dir
on ANY failure after the snapshot:
  zfs rollback -f <snapshot> → pct start (if was_running) → notify error, digest NOT saved
```

Notes:
- maps: derive `--uid-map/--gid-map` from the container's own `lxc.idmap` lines when
  present (some setups have a non-trivial gid map), fallback `0:100000:65536` for
  `unprivileged: 1`, nothing for privileged. Env override available.
- `-xdev` on the wipe keeps extra mounts (`mp0` …) untouched.
- snapshots only ever pruned when name matches our own prefix → never touches PVE-UI
  snapshots; `keep=0` (default) destroys the temp snapshot after a fully successful run.
- if `pct stop` errors because already stopped → treat as fine, then re-check status.

## 7. Paths & defaults

| purpose | default | env override |
|---|---|---|
| digest/state dir | `/var/lib/pve-ct-autoupdate` (FHS state dir, out of PVE's `/var/lib/vz` template+backup area) | `AUTOUPTATE_STATE_DIR` |
| OCI staging dir | `/var/lib/pve-ct-autoupdate/oci` (real disk, not tmpfs) | `AUTOUPTATE_TMP_DIR` |
| lock dir | `/var/lock` | `AUTOUPTATE_LOCK_DIR` |
| lxc conf dir | `/etc/pve/lxc` | `AUTOUPTATE_LXC_DIR` |
| notify hook | `$AUTOUPTATE_NOTIFY_CMD`, else `notify.sh` next to script, else `/usr/local/bin/...` | |

State file: `<state>/digest/<ctid>.digest` (plus `<ctid>.last` metadata: image, digest,
timestamp, snapshot name → useful for manual recovery, printed in logs/notifications).

## 8. Notifications

Contract: `notify.sh <severity> <title> <message>` where severity ∈ `info|warning|error`.
Only sent when: a container was updated (info), a failure/rollback happened (error), or a
valid opt-in container could not be processed (warning). Never when nothing to do.
`--dry-run` sends the same notifications prefixed with `[dry-run]`.
Aggregation policy: to confirm (one per container vs. one summary).

## 9. CLI

```
--dry-run --list --ctid <id> (repeatable) --force --verbose --quiet
--state-dir DIR --tmp-dir DIR --snapshot-keep N --help
```

## 10. Testing strategy (no real PVE here)

`tests/run-tests.sh` with a fake `$PATH` (`tests/mockbin/`): fake `pct`, `zfs`, `pvesm`,
`skopeo`, `umoci` backed by fixture files; fixtures for both `/data/` legacy and modern
layouts, invalid blocks, non-ZFS storage, stopped container, failure injection
(skopeo/umoci/pct failures) to prove rollback runs and digest is not committed.
Plus a `--dry-run` golden-output test and optional `shellcheck` if installed.

## 11. README / packaging notes

Dependencies (Debian 13 / PVE 9): `skopeo`, `umoci`, `zfsutils-linux`, `pve-storage`/
`pve-manager` (`pct`, `pvesm` — already installed), `curl` only for the ntfy example.
No other deps; POSIX-ish bash + GNU coreutils/findutils.
Repo must stay free of personal hosts/names → all examples use placeholders.

## 12. Decisions taken (from the planning review)

- Single self-contained script (`pve-ct-autoupdate.sh`), no lib/ split.
- Block keys: `AutoUpdate` (must be `registry`), `Image`, optional `SnapshotKeep`
  (default 0). Containers are always stopped before the rootfs update — no option
  for that. No TLS/insecure switch. Unknown keys ignored silently.
- `Image` without a tag is rejected.
- State dir `/var/lib/pve-ct-autoupdate`, staging `<state>/oci`.
- Rollback only for failures at or after the wipe; pull/stop/snapshot failures leave
  the rootfs untouched and continue with the next container. Any rollback aborts
  the whole run.
- Snapshots: `autoupdate-<timestamp>`, keep 0 by default, pruning matches only our
  own prefix.
- One notification per updated container.
- id/gid map driven by `unprivileged: 1` (`0:100000:65536`), not by parsing `lxc.idmap`
  (which is only present for special setups such as GPU passthrough).
- Legacy `zfs` storage type accepted; containers whose dataset is absent on this
  node (cluster) are skipped silently.
