# proxmox-ct-autoupdate

Refresh the rootfs of selected Proxmox LXC containers from an OCI image whenever
the image digest in a registry changes.

Containers **opt in explicitly** through a fenced code block in their container
config. Everything else is skipped silently — no snapshot, no stop, no wipe.

> The update is destructive by design: the container rootfs is wiped and replaced
> by the image content. A ZFS snapshot is taken first and rolled back automatically
> on failure.
>
> **Everything under the container rootfs is ephemeral** — including credentials Proxmox
> itself created for you (`pct create --password`, `--root-password`, SSH keys you pushed
> in through the UI). Mount a second volume for anything that must survive
> (`mp0: local-zfs:subvol-<CTID>-disk-1,mp=/root`).

## Config example using Proxmox CT Notes:
![screenshot](docs/screenshot.png)

Syntax inspired by Podman Quadlets

## Requirements

Proxmox VE 9 (Debian 13) on ZFS, plus:

```sh
apt install skopeo umoci
# already present on any Proxmox install: pct, pvesm, zfs, bash, awk, flock, curl*
```

| tool | used for |
|---|---|
| `skopeo` | inspect the remote digest, copy the image to a local OCI layout |
| `umoci` | `umoci raw unpack` into the container rootfs |
| `zfs` (zfsutils-linux) | snapshot / rollback / dataset resolution |
| `pct`, `pvesm` (pve-manager) | container state, storage path cross-check |
| `curl` | only if you use the example ntfy notification hook |

Only **ZFS backed rootfs** (`zfspool`, and the legacy `zfs` storage type) is
supported. Anything else is skipped.

## Quick start

```sh
# 1. install
install -m 0755 pve-ct-autoupdate.sh /usr/local/bin/pve-ct-autoupdate.sh

# 2. see what would be picked up and how the rootfs is resolved
/usr/local/bin/pve-ct-autoupdate.sh --list

# 3. dry run (no changes at all, prints the commands)
/usr/local/bin/pve-ct-autoupdate.sh --dry-run

# 4. real run
/usr/local/bin/pve-ct-autoupdate.sh
```

## Opt-in container config

### Recommended: the Proxmox UI *Notes* field

Container → **Notes** tab. Type the block normally, **without any `#`** — Proxmox
stores the notes as comment lines and prefixes them itself:

````md
```
AutoUpdate=registry
Image=registry.example.com/org/app:latest
```
````

This shows up in `/etc/pve/lxc/<CTID>.conf` as:

```
#```
#AutoUpdate=registry
#Image=registry.example.com/org/app:latest
#```
```

The notes keeps working as before: any other text, notes or markdown you put there
is simply ignored, only the fenced block is parsed. No SSH needed — opt in for a
container entirely from the web UI.

### Or: edit the config file directly

Add the same block (with the `#` prefixes) at the top of `/etc/pve/lxc/<CTID>.conf`,
or use `pvesh set -f /nodes/<node>/<qemu|lxc>/<ctid>` — see `examples/ct-conf.example`.

Parsing is strict:

- only lines starting with `#` are considered (that is what Proxmox writes for the
  notes), the fenced block must be complete (exactly one opening and one closing
  ``` fence, ```` ```md ```` also accepted)
- `AutoUpdate` must be exactly `registry` — anything else disables the container
- `Image` is required, the **tag is mandatory** (`app` is rejected, `app:latest` is fine)
- `%3A` style URL encoding of `:` is decoded, an optional `docker://` prefix is accepted
- keys outside the fence are ignored, unknown keys inside the fence are ignored
- optional key: `SnapshotKeep=N` (per container override)

A container whose block is missing or malformed is never touched.

## What happens per container

1. `skopeo inspect` → remote digest + image metadata (version, build date, source). Identical to the stored digest → done, no notification.
2. `skopeo copy` into the local OCI staging dir. **A pull failure never touches the rootfs.**
3. `pct stop` if the container is running (already-stopped containers stay stopped).
4. `zfs snapshot <dataset>@autoupdate-<timestamp>`
5. `find <rootfs> -xdev -mindepth 1 -delete` (extra `mpN:` mounts are not crossed)
6. `umoci raw unpack` (uid/gid map `0:100000:65536` for `unprivileged: 1`)
7. empty the rootfs directories that `mpN:` mounts are bound over (see
   *`mpN:` mounts and backups* below; disable with `--no-clean-mountpoints`)
8. `pct start` if it was running, then a status sanity check
9. store the new digest and metadata, prune snapshots, clean the staging dir

**Rollback:** any failure at or after the wipe triggers `zfs rollback -f` on the
snapshot, restarts the container if it had been running, sends an error notification,
does **not** commit the digest, and stops processing further containers. Failures
before the snapshot (pull, stop, snapshot creation) leave the rootfs untouched and
processing continues with the next container.

## How the rootfs path is resolved

The path is never assumed. Proxmox has moved ZFS subvol layouts between versions
(`<pool>/subvol-<ctid>-disk-N` vs the legacy `<pool>/data/subvol-...`), so:

1. `rootfs:` is parsed from the container config → `<storage>:<volid>`
2. the volume must be `subvol-<CTID>-disk-N`
3. `/etc/pve/storage.cfg` must define that storage as `zfspool` (or legacy `zfs`)
4. ZFS itself is asked which dataset holds the volume (`zfs list -o name,mountpoint`)
5. the dataset must be a **filesystem** (not a zvol), mounted, and the directory that
   will be wiped must be *exactly* that dataset's mountpoint
   (`zfs list -o name -d 0 <path>` must return the same dataset)
6. `pvesm path <storage>:<volid>` is used as a cross-check; a disagreement aborts

Containers whose dataset does not exist on this node (cluster configs are global)
are skipped quietly.

## `mpN:` mounts and Proxmox backups

Proxmox refuses to bind a secondary volume over a **non-empty** directory in the
rootfs, and `vzdump` relies on that invariant. A base image ships its own
`/root/.bashrc`, `/root/.profile`, `/root/.cache/…`, so unpacking it re-creates
files inside a directory that `mp0: …,mp=/root` covers — and the next backup then
fails on the shadowed files.

So right after unpacking, while the container is still stopped (the `mpN:` volumes
are *not* mounted at that moment), every `mp=` target parsed from the container
config is emptied again — the directory itself is kept, only what the image put
inside it is deleted, and a target the image does not ship is created empty and
chowned to the container's root:

```
[info ] ct 100: emptying '/root' — files there are shadowed by the mount anyway
[info ] ct 100: creating empty mountpoint target '/data' (absent from the image)
```

Why this cannot hurt the secondary volumes: the script never resolves an `mpN:`
source volume, it only ever names `<rootfs dataset mountpoint>/<target>`, and it
refuses (warn, no rollback) a target that is a mount point, lives on a different
device than the rootfs, or whose path crosses a symlink inside the rootfs. Only
files the image just shipped are removed — everything under a mountpoint target is
hidden by the bind mount for the container's whole lifetime anyway.

The cleanup runs **only on containers that are actually rewritten**. A container
that is up to date keeps whatever it has; to repair one, re-apply the update with
`--ctid <id> --force` (that is a normal, snapshot-guarded rewrite).

## Options

```
--dry-run          print what would run, change nothing (read-only queries still run)
--list             show opted-in containers + hostname, resolved dataset/rootfs
                     and last applied digest/version, no changes
--ctid <id>        limit the run to this CTID (repeatable)
--force            apply the update even when the digest did not change
--no-clean-mountpoints
                   leave the files an mpN: mount shadows inside the rootfs alone
                   (on by default, see "mpN: mounts and Proxmox backups")
--verbose          debug logging
--log-timestamps   prefix every log line with a date/time (off by default)
--state-dir DIR    default /var/lib/pve-ct-autoupdate
--oci-dir DIR      default <state-dir>/oci
--snapshot-keep N  default 0 (remove the temporary snapshot after success)
--version, --help
```

Environment overrides:

| variable | default |
|---|---|
| `PVE_AUTOUPDATE_LXC_DIR` | `/etc/pve/lxc` |
| `PVE_AUTOUPDATE_STORAGE_CFG` | `/etc/pve/storage.cfg` |
| `PVE_AUTOUPDATE_STATE_DIR` | `/var/lib/pve-ct-autoupdate` |
| `PVE_AUTOUPDATE_DIGEST_DIR` | `<state-dir>/digest` |
| `PVE_AUTOUPDATE_OCI_DIR` | `<state-dir>/oci` |
| `PVE_AUTOUPDATE_LOCK_DIR` | `/var/lock` |
| `PVE_AUTOUPDATE_SNAPSHOT_KEEP` | `0` |
| `PVE_AUTOUPDATE_SNAPSHOT_PREFIX` | `autoupdate` (ZFS snapshot names are limited to 32 chars) |
| `PVE_AUTOUPDATE_IDMAP` | `0:100000:65536` |
| `PVE_AUTOUPDATE_CLEAN_MOUNTPOINTS` | `1` — empty `mpN:` mountpoint targets after unpack |
| `PVE_AUTOUPDATE_NOTIFY_CMD` | auto-detected hook (see below) |
| `PVE_AUTOUPDATE_VERBOSE`, `PVE_AUTOUPDATE_LOG_TIMESTAMPS`, `PVE_AUTOUPDATE_DRY_RUN` | `0` |

The state dir holds the last applied digest per CTID
(`<state-dir>/digest/<ctid>.digest`) plus a small `key=value` sidecar with the
image metadata of that update (`<ctid>.meta`: image, digest, version, created,
source, revision, updated_at) — that is what makes "what changed" notifications
possible. The OCI staging dir lives on real disk (not tmpfs) because images can
be several GB. A per-CTID `flock` prevents overlapping runs.

## Notifications

Optional. If a hook exists it is called as:

```
<hook> <severity> <title> <message>     # severity: info | warning | error
```

Lookup order: `$PVE_AUTOUPDATE_NOTIFY_CMD`, `notify.sh` next to the script,
`/usr/local/bin/pve-ct-autoupdate-notify.sh`.

You only get notified when a container was actually updated, when a run failed,
or when an opted-in container could not be inspected. A cron run with nothing to
do sends nothing.

### What a notification looks like

The title carries the container **hostname** (from `hostname:` in the LXC config,
falling back to the CTID) and the version change; the body is a block of aligned
`key  value` lines:

```
title: ctauto-demo (LXC 200): 1.2.3 → 2.0.0

Container  ctauto-demo (LXC 200)
Image      registry.example.com/org/app:latest
Digest     sha256:aaaa1111bbbb… → sha256:cccc3333dddd…
Version    1.2.3 → 2.0.0
Built      2026-02-01T12:00:00Z
Source     https://github.com/example/app
```

The version lines come from the OCI labels `org.opencontainers.image.version`,
`.created` and `.source` (build date falls back to the image config); the *old*
values are the ones stored in `<ctid>.meta` by the previous run. An
image without those labels is simply reported without those lines — never an
error. Failure notifications carry the same `Container` / `Image` block plus the
reason.

`examples/notify.sh` is an ntfy (or any HTTP) example:

```sh
install -m 0755 examples/notify.sh /usr/local/bin/pve-ct-autoupdate-notify.sh
```

## Cron

```sh
install -m 0644 examples/crontab /etc/cron.d/pve-ct-autoupdate
```

See `examples/crontab`.

## Tests

Self-contained, no Proxmox/ZFS/registry needed — `tests/mockbin/` provides fake
`pct`, `zfs`, `skopeo`, `umoci` and `pvesm` driven by flat fixture files:

```sh
./tests/run-tests.sh
```

Covers: digest unchanged, opt-in parsing (missing/unterminated/invalid block,
missing tag, unknown keys), non-ZFS storage, modern *and* legacy ZFS layouts,
mountpoint mismatch, `mpN:` mountpoint cleanup (shadowed files removed, target
directory kept and created, unsafe/symlinked/foreign-device targets refused,
`--no-clean-mountpoints`, `--list` reporting), foreign cluster nodes, stopped
containers, pull failure (no rollback, keeps going), unpack failure (rollback +
abort), snapshot pruning with `SnapshotKeep`, privileged vs unprivileged id
mapping, `--dry-run` and `--list`, notification content (hostname, version/digest
diffs, label-less images, skopeo metadata fallback). The fake `umoci` plants an
image payload (`/root/.profile`, `/root/.cache/`, `/etc/hosts`) so the cleanup has
something realistic to remove.

## Limitations

- ZFS backed rootfs only.
- The rootfs is fully **ephemeral by design**: any file inside it (shell profile,
  `~/.ssh/authorized_keys`, local config, …) is deleted on the next update — **including
  the root password and SSH keys Proxmox wrote when the container was created**, since
  those live in `/etc/shadow` and `/root/.ssh` on the rootfs. Only the `mpN:` extra
  mounts survive. Bake what matters into the image, or mount a dedicated subvolume:

  ```
  mp0: local-zfs:subvol-100-disk-1,mp=/data,backup=1,size=64G
  ```

  Prefer images that re-create their own defaults when the mounted directory is empty,
  so the container is usable again right after an update.
- Snapshot-based rollback only covers the rootfs dataset: extra `mpN:` mounts are
  deliberately never touched, so data there is **not** rolled back. The mountpoint
  cleanup walks the *rootfs* side of a mount only; it refuses any target that is a
  mount point, lives on another device, or crosses a rootfs symlink.
- Registry authentication uses whatever `skopeo auth.json` provides; there is no
  built-in credential handling and no TLS-verify bypass switch.
- Image refs must carry a tag; `@sha256:` pinned refs are not accepted (the digest
  comparison is what drives the update).
- `latest` is allowed, but a mutable tag means an update is applied on every push.
