#!/usr/bin/env bash
#
# pve-ct-autoupdate — refresh Proxmox LXC container rootfs from an OCI image
#                     when the remote image digest changed.
#
# Containers opt in explicitly through a fenced code block in the container
# config comments (/etc/pve/lxc/<ctid>.conf):
#
#   #```
#   #AutoUpdate=registry
#   #Image=registry.example.com/org/app:latest
#   #```
#
# Anything without a valid block is skipped silently. ZFS-backed rootfs only.
# See README.md for the full configuration reference.
#
# Copyright (c) 2026 Gerporgl — MIT licensed, see LICENSE.
#

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration (all overridable through the environment)
# ----------------------------------------------------------------------------

PROG=${0##*/}
VERSION="1.0.0"

LXC_DIR=${PVE_AUTOUPDATE_LXC_DIR:-/etc/pve/lxc}
STORAGE_CFG=${PVE_AUTOUPDATE_STORAGE_CFG:-/etc/pve/storage.cfg}
STATE_DIR=${PVE_AUTOUPDATE_STATE_DIR:-/var/lib/pve-ct-autoupdate}
DIGEST_DIR=${PVE_AUTOUPDATE_DIGEST_DIR:-$STATE_DIR/digest}
OCI_DIR=${PVE_AUTOUPDATE_OCI_DIR:-$STATE_DIR/oci}
LOCK_DIR=${PVE_AUTOUPDATE_LOCK_DIR:-/var/lock}

SNAPSHOT_KEEP=${PVE_AUTOUPDATE_SNAPSHOT_KEEP:-0}
SNAPSHOT_PREFIX=${PVE_AUTOUPDATE_SNAPSHOT_PREFIX:-autoupdate}

# Default uid/gid mapping applied to unprivileged containers.
IDMAP=${PVE_AUTOUPDATE_IDMAP:-0:100000:65536}

DRY_RUN=${PVE_AUTOUPDATE_DRY_RUN:-0}
VERBOSE=${PVE_AUTOUPDATE_VERBOSE:-0}
FORCE=0
ABORT=0
declare -a ONLY_CTID=()

# ----------------------------------------------------------------------------
# Logging / notifications
# ----------------------------------------------------------------------------

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_debug() {
    [[ $VERBOSE == 1 ]] && printf '%s [debug] %s\n' "$(_ts)" "$*" >&2
    return 0
}
log_info() { printf '%s [info ] %s\n' "$(_ts)" "$*" >&2; }
log_warn() { printf '%s [warn ] %s\n' "$(_ts)" "$*" >&2; }
log_error() { printf '%s [error] %s\n' "$(_ts)" "$*" >&2; }

# Notification hook, optional. Contract: notify.sh <severity> <title> <message>
# severity is one of: info | warning | error
resolve_notify_cmd() {
    if [[ -n ${PVE_AUTOUPDATE_NOTIFY_CMD:-} ]]; then
        printf '%s' "${PVE_AUTOUPDATE_NOTIFY_CMD}"
        return 0
    fi
    local candidates=(
        "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/notify.sh"
        /usr/local/bin/pve-ct-autoupdate-notify.sh
        /usr/local/bin/notify.sh
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -x $c ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

NOTIFY_CMD=""
notify() {
    local severity=$1 title=$2 message=$3
    [[ -z $NOTIFY_CMD ]] && return 0
    if [[ $DRY_RUN == 1 ]]; then
        title="[dry-run] $title"
    fi
    if ! "$NOTIFY_CMD" "$severity" "$title" "$message"; then
        log_warn "notification hook failed (severity=$severity title=$title)"
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

die() { log_error "$*"; exit 1; }

run_cmd() {
    if [[ $DRY_RUN == 1 ]]; then
        printf '%s [dry-run] %s\n' "$(_ts)" "$*"
        return 0
    fi
    "$@"
}

url_decode() {
    local in=$1 out=''
    while [[ $in =~ ^([^%]*)%([0-9A-Fa-f]{2})(.*)$ ]]; do
        out+=${BASH_REMATCH[1]}
        out+=$(printf '%b' "\\x${BASH_REMATCH[2]}")
        in=${BASH_REMATCH[3]}
    done
    printf '%s' "$out$in"
}

is_number() { [[ $1 =~ ^[0-9]+$ ]]; }

usage() {
    cat <<EOF
$PROG $VERSION — Proxmox LXC rootfs auto-updater (ZFS backed containers)

Usage: $PROG [options]

  --dry-run          Do not change anything; print the commands that would run.
                     Read-only queries (skopeo inspect, pct status, zfs list)
                     are still executed. Notifications are still sent, prefixed
                     with [dry-run].
  --list             Show every container that opts in, plus how its rootfs was
                     resolved. No registry pull, no changes.
  --ctid <id>        Only consider this container id (repeatable).
  --force            Apply the update even if the digest did not change.
  --verbose          Extra debug logging.
  --state-dir DIR    Default: /var/lib/pve-ct-autoupdate
  --oci-dir DIR      Default: <state-dir>/oci
  --snapshot-keep N  Keep N past autoupdate snapshots per container (0 = remove
                     the temporary snapshot after a successful update).
  --version          Print version.
  -h, --help         This help.

Environment:
  PVE_AUTOUPDATE_LXC_DIR, PVE_AUTOUPDATE_STORAGE_CFG, PVE_AUTOUPDATE_STATE_DIR,
  PVE_AUTOUPDATE_DIGEST_DIR, PVE_AUTOUPDATE_OCI_DIR, PVE_AUTOUPDATE_LOCK_DIR,
  PVE_AUTOUPDATE_SNAPSHOT_KEEP, PVE_AUTOUPDATE_SNAPSHOT_PREFIX,
  PVE_AUTOUPDATE_IDMAP, PVE_AUTOUPDATE_NOTIFY_CMD, PVE_AUTOUPDATE_VERBOSE,
  PVE_AUTOUPDATE_DRY_RUN
EOF
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------

while (($#)); do
    case $1 in
        --dry-run) DRY_RUN=1 ;;
        --list) LIST_ONLY=1 ;;
        --ctid) [[ $# -ge 2 ]] || die "--ctid needs an argument"; ONLY_CTID+=("$2"); shift ;;
        --force) FORCE=1 ;;
        --verbose) VERBOSE=1 ;;
        --state-dir) [[ $# -ge 2 ]] || die "--state-dir needs an argument"; STATE_DIR=$2; DIGEST_DIR=$STATE_DIR/digest; OCI_DIR=$STATE_DIR/oci; shift ;;
        --oci-dir) [[ $# -ge 2 ]] || die "--oci-dir needs an argument"; OCI_DIR=$2; shift ;;
        --snapshot-keep) [[ $# -ge 2 ]] || die "--snapshot-keep needs an argument"; SNAPSHOT_KEEP=$2; shift ;;
        --version) echo "$PROG $VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

LIST_ONLY=${LIST_ONLY:-0}
is_number "$SNAPSHOT_KEEP" || die "--snapshot-keep must be a number"

# ----------------------------------------------------------------------------
# Dependency checks
# ----------------------------------------------------------------------------

check_deps() {
    local missing=0 tool
    for tool in pct zfs skopeo umoci find; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing=1
            if [[ $DRY_RUN == 1 ]]; then
                log_warn "dependency missing: $tool (dry-run continues)"
            else
                log_error "dependency missing: $tool"
            fi
        fi
    done
    if [[ $missing == 1 && $DRY_RUN != 1 ]]; then
        die "install the missing dependencies (see README.md)"
    fi
}

# ----------------------------------------------------------------------------
# Container config parsing
# ----------------------------------------------------------------------------
#
# Parses one /etc/pve/lxc/<ctid>.conf file:
#   * the opt-in fenced code block (optional)
#   * rootfs:, unprivileged: and the mpN: mounts
#
# Returns:
#   0  valid opt-in block
#   1  no opt-in block at all (silent skip)
#   2  block present but invalid (log, silent skip)

CFG_HAS_BLOCK=0
CFG_BLOCK_INVALID=0
CFG_IMAGE=""
CFG_KEEP=""
CFG_ROOTFS_STORE=""
CFG_ROOTFS_VOL=""
CFG_UNPRIVILEGED=0
declare -a CFG_MOUNTPOINTS=()

parse_container_conf() {
    local ctid=$1 conf=$2
    local line key value fence=0 fences=0 image_seen=0 autoupdate_seen=0 bad=0

    CFG_HAS_BLOCK=0 CFG_BLOCK_INVALID=0 CFG_IMAGE="" CFG_KEEP=""
    CFG_ROOTFS_STORE="" CFG_ROOTFS_VOL="" CFG_UNPRIVILEGED=0
    CFG_MOUNTPOINTS=()

    while IFS= read -r line || [[ -n $line ]]; do
        # ---- opt-in block: only comment lines are candidates ---------------
        if [[ $line == '#'* ]]; then
            line=${line#'#'}
            line=${line#"${line%%[![:space:]]*}"}     # ltrim
            line=${line%"${line##*[![:space:]]}"}     # rtrim
            [[ -z $line ]] && continue

            if [[ $line =~ ^\`\`\`(md)?[[:space:]]*$ ]]; then
                fence=$((fence + 1))
                fences=$((fences + 1))
                if ((fence == 1)); then
                    CFG_HAS_BLOCK=1
                    continue
                elif ((fence >= 2)); then
                    fence=0
                    continue
                fi
            fi

            if ((fence >= 1)); then
                if [[ $line =~ ^([A-Za-z][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                    key=${BASH_REMATCH[1],,}
                    value=${BASH_REMATCH[2]}
                    value=${value%"${value##*[![:space:]]}"}
                    case $key in
                        autoupdate)
                            autoupdate_seen=1
                            [[ ${value,,} != registry ]] && bad=1
                        ;;
                        image)
                            image_seen=1
                            CFG_IMAGE=$value
                        ;;
                        snapshotkeep)
                            if is_number "$value"; then CFG_KEEP=$value; else bad=2; fi
                        ;;
                        *) : ;;   # unknown keys are ignored silently
                    esac
                fi
                continue
            fi
        fi

        # ---- regular config keys we care about -----------------------------
        if [[ $line =~ ^[[:space:]]*rootfs:[[:space:]]*([^:[:space:]]+):([^,[:space:]]+)[[:space:]]*$ ]] ||
           [[ $line =~ ^[[:space:]]*rootfs:[[:space:]]*([^:[:space:]]+):([^,[:space:]]+),.* ]]; then
            CFG_ROOTFS_STORE=${BASH_REMATCH[1]}
            CFG_ROOTFS_VOL=${BASH_REMATCH[2]}
        elif [[ $line =~ ^[[:space:]]*unprivileged:[[:space:]]*1[[:space:]]*$ ]]; then
            CFG_UNPRIVILEGED=1
        elif [[ $line =~ ^[[:space:]]*mp[0-9]+:[[:space:]]*[^,]*,mp=([^,[:space:]]+) ]]; then
            CFG_MOUNTPOINTS+=("${BASH_REMATCH[1]}")
        fi
    done < "$conf"

    if [[ $CFG_HAS_BLOCK != 1 ]]; then
        return 1
    fi
    if ((fences < 2)) || ((fences > 2)) || [[ $autoupdate_seen != 1 ]] ||
       [[ $image_seen != 1 ]] || ((bad)); then
        CFG_BLOCK_INVALID=1
        log_debug "ct $ctid: opt-in block present but invalid (fences=$fences autoupdate=$autoupdate_seen image=$image_seen bad=$bad)"
        return 2
    fi

    validate_image "$CFG_IMAGE" || { CFG_BLOCK_INVALID=1; log_debug "ct $ctid: invalid Image value '$CFG_IMAGE'"; return 2; }
    return 0
}

validate_image() {
    local raw=$1 ref
    ref=$(url_decode "$raw")
    ref=${ref#docker://}
    [[ -z $ref || $ref =~ [[:space:]] ]] && return 1
    [[ $ref == *@* ]] && return 1                       # digest pinned refs not supported
    # registry host must look like a host (dot, port, or localhost)
    local host=${ref%%/*}
    [[ $ref != */* ]] && return 1
    [[ $host != *.* && $host != *:* && $host != localhost ]] && return 1
    # repo + mandatory tag
    [[ $ref =~ ^[^/]+(/[A-Za-z0-9._-]+)+:[A-Za-z0-9._-]+$ ]] || return 1
    VALIDATED_IMAGE=$ref
    return 0
}

# ----------------------------------------------------------------------------
# Storage / ZFS rootfs resolution
# ----------------------------------------------------------------------------

# Parses /etc/pve/storage.cfg for one storage id.
# Prints "type|pool|mountpoint|disabled|content" (empty fields allowed).
parse_storage_cfg() {
    local store=$1
    [[ -r $STORAGE_CFG ]] || return 1
    awk -v store="$store" '
        /^[^[:space:]#]/ {
            n = split($0, a, /[[:space:]]+/)
            sub(/:$/, "", a[1])          # PVE writes "zfspool: local-zfs"
            if (n >= 2 && a[2] == store && (a[1] == "zfspool" || a[1] == "zfs")) {
                type = a[1]; found = 1
            } else {
                if (found) exit
                found = 0
            }
            next
        }
        found && /^[[:space:]]+/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            split(line, b, /[[:space:]]+/)
            sub(/:$/, "", b[1])          # tolerate "pool: rpool/data"
            if      (b[1] == "pool")       pool = b[2]
            else if (b[1] == "mountpoint") mountpoint = b[2]
            else if (b[1] == "content")    content = b[2]
            else if (b[1] == "disabled")   disabled = "1"
        }
        END {
            if (!found) exit 1
            printf "%s|%s|%s|%s|%s\n", type, pool, mountpoint, disabled, content
        }
    ' "$STORAGE_CFG"
}

CT_STORE="" CT_STORAGE_TYPE="" CT_POOL="" CT_STORAGE_MOUNTPOINT=""
CT_DS="" CT_ROOTFS_PATH="" RESOLVE_REASON=""

resolve_rootfs() {
    local ctid=$1 vol=$2 store=$3

    CT_DS="" CT_ROOTFS_PATH="" CT_STORAGE_TYPE="" CT_POOL="" CT_STORAGE_MOUNTPOINT=""
    RESOLVE_REASON=""

    if [[ $vol != "subvol-${ctid}-disk-"* ]]; then
        RESOLVE_REASON="rootfs volume '$vol' is not a subvol of ct $ctid"
        log_debug "ct $ctid: $RESOLVE_REASON"
        return 1
    fi

    local parsed
    if ! parsed=$(parse_storage_cfg "$store"); then
        RESOLVE_REASON="storage '$store' not found in $STORAGE_CFG"
        log_debug "ct $ctid: $RESOLVE_REASON"
        return 1
    fi
    IFS='|' read -r CT_STORAGE_TYPE CT_POOL CT_STORAGE_MOUNTPOINT _disabled _content <<<"$parsed"

    if [[ $CT_STORAGE_TYPE != zfspool && $CT_STORAGE_TYPE != zfs ]]; then
        RESOLVE_REASON="storage '$store' is type '${CT_STORAGE_TYPE:-unknown}', only ZFS (zfspool) is supported"
        log_debug "ct $ctid: $RESOLVE_REASON"
        return 1
    fi
    [[ -n $CT_POOL ]] || { RESOLVE_REASON="storage '$store' has no 'pool' setting"; log_warn "ct $ctid: $RESOLVE_REASON"; return 1; }
    [[ $_disabled == 1 ]] && { RESOLVE_REASON="storage '$store' is disabled"; log_warn "ct $ctid: $RESOLVE_REASON"; return 1; }
    log_debug "ct $ctid: storage '$store' type=$CT_STORAGE_TYPE pool=$CT_POOL mountpoint=${CT_STORAGE_MOUNTPOINT:-auto}"

    # Ask ZFS which dataset actually holds this volume. Layout is version
    # dependent (<pool>/subvol-... or legacy <pool>/data/subvol-...), so never
    # build the path ourselves.
    local name mp
    while IFS=$'\t' read -r name mp; do
        [[ -z $name ]] && continue
        if [[ ${name##*/} == "$vol" && $name == "$CT_POOL"/* ]]; then
            CT_DS=$name
            CT_ROOTFS_PATH=$mp
            break
        fi
    done < <(zfs list -H -o name,mountpoint -t filesystem -r "$CT_POOL" 2>/dev/null || true)

    if [[ -z $CT_DS ]]; then
        RESOLVE_REASON="no ZFS filesystem dataset named '$vol' under pool '$CT_POOL' (another node? imported?)"
        log_debug "ct $ctid: $RESOLVE_REASON"
        return 1
    fi

    if [[ -z $CT_ROOTFS_PATH || $CT_ROOTFS_PATH == "-" || $CT_ROOTFS_PATH == legacy ]]; then
        CT_ROOTFS_PATH=$(zfs get -H -o value mountpoint "$CT_DS" 2>/dev/null || true)
    fi
    if [[ -z $CT_ROOTFS_PATH || $CT_ROOTFS_PATH == "-" || $CT_ROOTFS_PATH == legacy ]]; then
        RESOLVE_REASON="dataset '$CT_DS' has no usable mountpoint"
        log_warn "ct $ctid: $RESOLVE_REASON"
        return 1
    fi

    # Cross-check against PVE's own resolver; a disagreement means we do not know
    # which path is authoritative, so refuse to wipe anything.
    if command -v pvesm >/dev/null 2>&1; then
        local pvepath
        if pvepath=$(pvesm path "$store:$vol" 2>/dev/null) && [[ -n $pvepath ]]; then
            if [[ $(realpath "$pvepath" 2>/dev/null || printf '%s' "$pvepath") != $(realpath "$CT_ROOTFS_PATH" 2>/dev/null || printf '%s' "$CT_ROOTFS_PATH") ]]; then
                RESOLVE_REASON="pvesm reports '$pvepath' but ZFS reports '$CT_ROOTFS_PATH' for '$CT_DS'"
                log_warn "ct $ctid: $RESOLVE_REASON"
                return 1
            fi
        fi
    fi

    validate_rootfs_dataset "$ctid" "$CT_DS" "$CT_ROOTFS_PATH"
}

validate_rootfs_dataset() {
    local ctid=$1 ds=$2 path=$3

    [[ -d $path ]] || { log_warn "ct $ctid: '$path' is not a directory"; return 1; }

    local type mounted real
    type=$(zfs list -H -o type "$ds" 2>/dev/null || true)
    if [[ $type != filesystem ]]; then
        log_warn "ct $ctid: dataset '$ds' is type '${type:-unknown}', expected a ZFS filesystem"
        return 1
    fi

    mounted=$(zfs get -H -o value mounted "$ds" 2>/dev/null || true)
    if [[ $mounted != yes ]]; then
        log_warn "ct $ctid: dataset '$ds' is not mounted"
        return 1
    fi

    # The directory we are going to wipe must be exactly the dataset mountpoint,
    # never a parent directory that happens to contain other data.
    local exact
    exact=$(zfs list -H -o name -d 0 "$path" 2>/dev/null || true)
    if [[ $exact != "$ds" ]]; then
        log_warn "ct $ctid: '$path' resolves to dataset '${exact:-nothing}', expected '$ds'"
        return 1
    fi

    real=$(realpath "$path" 2>/dev/null || true)
    local mp
    mp=$(zfs get -H -o value mountpoint "$ds" 2>/dev/null || true)
    if [[ -n $mp && $mp != "-" && $mp != legacy && $(realpath "$mp" 2>/dev/null || true) != "$real" ]]; then
        log_warn "ct $ctid: '$path' does not match the dataset mountpoint '$mp'"
        return 1
    fi

    CT_ROOTFS_PATH=$real
    return 0
}

# ----------------------------------------------------------------------------
# Digest helpers
# ----------------------------------------------------------------------------

digest_file() { printf '%s/%s.digest' "$DIGEST_DIR" "$1"; }

read_local_digest() {
    local f
    f=$(digest_file "$1")
    [[ -f $f ]] && head -n1 "$f" || true
}

write_local_digest() {
    local ctid=$1 digest=$2 f tmp
    f=$(digest_file "$ctid")
    tmp="$f.tmp.$$"
    printf '%s\n' "$digest" > "$tmp"
    mv -f "$tmp" "$f"
}

remote_digest() {
    local image=$1
    skopeo inspect --format '{{.Digest}}' "docker://$image" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Snapshot helpers
# ----------------------------------------------------------------------------

snapshot_list() {
    local ds=$1
    zfs list -H -o name -t snapshot -s creation -d 1 "$ds" 2>/dev/null |
        grep "@${SNAPSHOT_PREFIX}-" || true
}

prune_snapshots() {
    local ds=$1 keep=$2
    local -a snaps=()
    mapfile -t snaps < <(snapshot_list "$ds")
    local n=${#snaps[@]}
    ((keep >= n)) && return 0
    local i
    for ((i = 0; i < n - keep; i++)); do
        log_info "pruning snapshot ${snaps[$i]}"
        run_cmd zfs destroy "${snaps[$i]}" || log_warn "failed to prune ${snaps[$i]}"
    done
}

oci_dir_for() { printf '%s/ct-%s' "$OCI_DIR" "$1"; }

cleanup_oci() {
    local d
    d=$(oci_dir_for "$1")
    [[ -d $d ]] && run_cmd find "$d" -xdev -mindepth 1 -delete
    return 0
}

# ----------------------------------------------------------------------------
# Container state helpers
# ----------------------------------------------------------------------------

ct_status() { pct status "$1" 2>/dev/null || true; }   # "status: running" / "status: stopped"
ct_is_running() { [[ $(ct_status "$1") == *"running"* ]]; }

rollback_container() {
    local ctid=$1 ds=$2 snap=$3 was_running=$4 reason=$5
    log_error "ct $ctid: ROLLBACK ($reason)"
    run_cmd zfs rollback -f "$snap" ||
        log_error "ct $ctid: zfs rollback FAILED - manual recovery: zfs rollback -f $snap"
    if [[ $was_running == 1 ]]; then
        run_cmd pct start "$ctid" || log_warn "ct $ctid: could not restart after rollback"
    fi
    notify error "LXC $ctid update failed, rolled back" \
        "CT $ctid: update aborted ($reason). Filesystem restored from snapshot $snap."
    ABORT=1
}

# ----------------------------------------------------------------------------
# Per container processing
# ----------------------------------------------------------------------------

process_container() {
    local ctid=$1 conf=$2
    local keep=$SNAPSHOT_KEEP image ref

    local rc=0
    parse_container_conf "$ctid" "$conf" || rc=$?
    case $rc in
        1) log_debug "ct $ctid: no autoupdate block, skipping"; return 0 ;;
        2) log_info  "ct $ctid: autoupdate block found but invalid, skipping"; return 0 ;;
    esac

    image=$VALIDATED_IMAGE
    [[ -n $CFG_KEEP ]] && keep=$CFG_KEEP

    if ! resolve_rootfs "$ctid" "$CFG_ROOTFS_VOL" "$CFG_ROOTFS_STORE"; then
        printf 'ct %-6s image=%s  -> NOT RESOLVED: %s\n' "$ctid" "$image" "${RESOLVE_REASON:-unknown reason}"
        log_info "ct $ctid: opted in but its ZFS rootfs could not be resolved safely, skipping"
        return 0
    fi

    local ds=$CT_DS path=$CT_ROOTFS_PATH

    if [[ $LIST_ONLY == 1 ]]; then
        printf 'ct %-6s image=%s\n' "$ctid" "$image"
        printf '         store=%s pool=%s\n' "$CFG_ROOTFS_STORE" "$CT_POOL"
        printf '         dataset=%s\n' "$ds"
        printf '         rootfs=%s keep=%s unprivileged=%s\n' "$path" "$keep" "$CFG_UNPRIVILEGED"
        return 0
    fi

    log_info "ct $ctid: image=$image dataset=$ds rootfs=$path"

    # ---- digest check ------------------------------------------------------
    local remote local_digest
    if ! remote=$(remote_digest "$image"); then
        log_error "ct $ctid: skopeo inspect failed for $image (registry unreachable?)"
        notify warning "LXC $ctid update skipped" \
            "CT $ctid: could not inspect $image, no update applied."
        return 0
    fi
    local_digest=$(read_local_digest "$ctid")
    log_debug "ct $ctid: remote digest=${remote:-none} local digest=${local_digest:-none}"

    if [[ -n $remote && $remote == "$local_digest" && $FORCE != 1 ]]; then
        log_info "ct $ctid: already at $remote, nothing to do"
        return 0
    fi
    [[ -z $remote ]] && die_unreachable "$ctid" "$image"

    log_info "ct $ctid: digest change ${local_digest:-none} -> $remote"

    # ---- lock --------------------------------------------------------------
    local lockfd="" lockfile="$LOCK_DIR/pve-ct-autoupdate-$ctid.lock"
    if [[ $DRY_RUN != 1 ]]; then
        exec {lockfd}>"$lockfile"
        if ! flock -n "$lockfd"; then
            log_warn "ct $ctid: another run holds the lock, skipping"
            exec {lockfd}>&-
            return 0
        fi
    fi

    local was_running=0
    ct_is_running "$ctid" && was_running=1

    # ---- pull the image first: a pull failure must not touch the rootfs ---
    local oci
    oci=$(oci_dir_for "$ctid")
    run_cmd mkdir -p "$oci"
    cleanup_oci "$ctid"
    if ! run_cmd skopeo copy "docker://$image" "oci:$oci:autoupdate"; then
        log_error "ct $ctid: skopeo copy failed, rootfs untouched"
        cleanup_oci "$ctid"
        [[ -n $lockfd ]] && exec {lockfd}>&-
        notify error "LXC $ctid update failed" \
            "CT $ctid: could not pull $image. The container rootfs was not modified."
        return 0
    fi

    # ---- stop the container ------------------------------------------------
    if [[ $was_running == 1 ]]; then
        log_info "ct $ctid: stopping container"
        if ! run_cmd pct stop "$ctid"; then
            log_warn "ct $ctid: pct stop returned an error, re-checking status"
        fi
        if [[ $DRY_RUN != 1 ]] && ct_is_running "$ctid"; then
            log_error "ct $ctid: container is still running, aborting (rootfs untouched)"
            cleanup_oci "$ctid"
            [[ -n $lockfd ]] && exec {lockfd}>&-
            notify error "LXC $ctid update failed" "CT $ctid: container could not be stopped."
            return 0
        fi
    fi

    # ---- snapshot ----------------------------------------------------------
    local stamp snap
    stamp=$(date '+%Y%m%dT%H%M%S%3N')
    [[ $stamp == *'%3N'* ]] && stamp=$(date '+%Y%m%dT%H%M%S')$((RANDOM % 1000))
    snap="$ds@${SNAPSHOT_PREFIX}-${stamp}"
    if ! run_cmd zfs snapshot "$snap"; then
        log_error "ct $ctid: zfs snapshot failed, rootfs untouched"
        cleanup_oci "$ctid"
        [[ -n $lockfd ]] && exec {lockfd}>&-
        notify error "LXC $ctid update failed" "CT $ctid: could not snapshot $ds."
        return 0
    fi
    log_info "ct $ctid: snapshot $snap"

    # ---- everything below mutates the rootfs: rollback on failure ----------
    if ! run_cmd find "$path" -xdev -mindepth 1 -delete; then
        rollback_container "$ctid" "$ds" "$snap" "$was_running" "rootfs wipe failed"
        cleanup_oci "$ctid"
        return 0
    fi

    # umoci expects every option before the <rootfs> positional argument.
    local -a umoci_args=(raw unpack --image "$oci:autoupdate" --keep-dirlinks)
    if [[ $CFG_UNPRIVILEGED == 1 ]]; then
        umoci_args+=(--uid-map "$IDMAP" --gid-map "$IDMAP")
    fi
    umoci_args+=("$path")
    if ! run_cmd umoci "${umoci_args[@]}"; then
        rollback_container "$ctid" "$ds" "$snap" "$was_running" "umoci unpack failed"
        cleanup_oci "$ctid"
        return 0
    fi

    if [[ $DRY_RUN != 1 && -z $(ls -A "$path" 2>/dev/null) ]]; then
        rollback_container "$ctid" "$ds" "$snap" "$was_running" "rootfs is empty after unpack"
        cleanup_oci "$ctid"
        return 0
    fi

    if [[ $was_running == 1 ]]; then
        log_info "ct $ctid: starting container"
        if ! run_cmd pct start "$ctid"; then
            rollback_container "$ctid" "$ds" "$snap" "$was_running" "pct start failed"
            cleanup_oci "$ctid"
            return 0
        fi
        if [[ $DRY_RUN != 1 ]] && ! ct_is_running "$ctid"; then
            sleep 5
            if ! ct_is_running "$ctid"; then
                rollback_container "$ctid" "$ds" "$snap" "$was_running" "container not running after start"
                cleanup_oci "$ctid"
                return 0
            fi
        fi
    fi

    # ---- success ------------------------------------------------------------
    if [[ $DRY_RUN != 1 ]]; then
        write_local_digest "$ctid" "$remote"
    fi
    log_info "ct $ctid: updated to $remote"
    notify info "LXC $ctid updated" \
        "CT $ctid updated from ${local_digest:-none} to $remote (image: $image)."

    cleanup_oci "$ctid"
    prune_snapshots "$ds" "$keep"
    [[ -n $lockfd ]] && exec {lockfd}>&-
    return 0
}

die_unreachable() {
    local ctid=$1 image=$2
    log_error "ct $ctid: no digest available for $image"
    notify warning "LXC $ctid update skipped" "CT $ctid: no digest for $image."
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    NOTIFY_CMD=$(resolve_notify_cmd || true)
    [[ -n $NOTIFY_CMD ]] && log_debug "notification hook: $NOTIFY_CMD"

    [[ -d $LXC_DIR ]] || die "container config directory not found: $LXC_DIR"

    if [[ $DRY_RUN != 1 ]]; then
        if [[ $(id -u) != 0 ]]; then
            # escape hatch used by the test suite / CI containers
            [[ ${PVE_AUTOUPDATE_ALLOW_NON_ROOT:-0} == 1 ]] ||
                die "must be run as root (set PVE_AUTOUPDATE_ALLOW_NON_ROOT=1 to override)"
            log_warn "running as non-root (PVE_AUTOUPDATE_ALLOW_NON_ROOT=1)"
        fi
        check_deps
        run_cmd mkdir -p "$DIGEST_DIR" "$OCI_DIR"
    fi

    shopt -s nullglob
    local -a files=("$LXC_DIR"/*.conf)
    shopt -u nullglob
    ((${#files[@]})) || { log_warn "no container configs in $LXC_DIR"; return 0; }

    local rc=0 ctid conf want c
    for conf in "${files[@]}"; do
        ctid=${conf##*/}; ctid=${ctid%.conf}
        is_number "$ctid" || continue
        if ((${#ONLY_CTID[@]})); then
            want=0; c=""
            for c in "${ONLY_CTID[@]}"; do [[ $c == "$ctid" ]] && want=1; done
            ((want)) || continue
        fi
        if ! process_container "$ctid" "$conf"; then
            log_error "ct $ctid: processing failed"
            rc=1
        fi
        ((ABORT)) && { log_error "a rollback happened, stopping further container processing"; break; }
    done

    return $rc
}

main "$@"
