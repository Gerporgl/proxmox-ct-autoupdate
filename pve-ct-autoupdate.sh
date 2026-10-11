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
VERSION="1.1.0"

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
CLEAN_MOUNTPOINTS=${PVE_AUTOUPDATE_CLEAN_MOUNTPOINTS:-1}
VERBOSE=${PVE_AUTOUPDATE_VERBOSE:-0}
LOG_TIMESTAMPS=${PVE_AUTOUPDATE_LOG_TIMESTAMPS:-0}
FORCE=0
ABORT=0
declare -a ONLY_CTID=()

# ----------------------------------------------------------------------------
# Logging / notifications
# ----------------------------------------------------------------------------

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Log prefix: empty by default, "YYYY-MM-DD HH:MM:SS " with --log-timestamps.
_log_prefix() {
    if [[ $LOG_TIMESTAMPS == 1 ]]; then
        printf '%s ' "$(_ts)"
    fi
    return 0
}

log_debug() {
    [[ $VERBOSE == 1 ]] && printf '%s[debug] %s\n' "$(_log_prefix)" "$*" >&2
    return 0
}
log_info() { printf '%s[info ] %s\n' "$(_log_prefix)" "$*" >&2; }
log_warn() { printf '%s[warn ] %s\n' "$(_log_prefix)" "$*" >&2; }
log_error() { printf '%s[error] %s\n' "$(_log_prefix)" "$*" >&2; }

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
# Message building
# ----------------------------------------------------------------------------
#
# A short title carrying the container name plus the version change, and a body
# of aligned "key  value" lines. Container names use the hostname from the LXC
# config; the CTID is always part of the name.

# CT_HOSTNAME / CT_IMAGE are set by process_container and used by the failure
# notifications below.
CT_CTID="" CT_HOSTNAME="" CT_IMAGE=""

ct_name() {
    local ctid=$1 host=$2
    if [[ -n $host ]]; then printf '%s (LXC %s)' "$host" "$ctid"
    else printf 'LXC %s' "$ctid"; fi
}

# A full digest is unreadable in a push notification; keep enough to identify it.
short_digest() {
    local d=$1
    if [[ ${#d} -gt 19 ]]; then printf '%s…' "${d:0:19}"
    else printf '%s' "$d"; fi
}

# "old → new" when both are known and different, the known value otherwise.
diff_value() {
    local old=$1 new=$2
    if [[ -n $old && -n $new && $old != "$new" ]]; then printf '%s → %s' "$old" "$new"
    elif [[ -n $new ]]; then printf '%s' "$new"
    elif [[ -n $old ]]; then printf '%s' "$old"; fi
}

update_title() {
    local name=$1 oldv=$2 newv=$3
    if [[ -n $oldv && -n $newv && $oldv != "$newv" ]]; then
        printf '%s: %s → %s' "$name" "$oldv" "$newv"
    elif [[ -n $newv ]]; then
        printf '%s → %s' "$name" "$newv"
    else
        printf '%s updated' "$name"
    fi
}

declare -a KV_KEYS=() KV_VALS=()

kv_add() { [[ -z $2 ]] && return 0; KV_KEYS+=("$1"); KV_VALS+=("$2"); return 0; }

# Renders KV_KEYS/KV_VALS as aligned "key  value" lines.
kv_render() {
    local w=0 i k
    for k in "${KV_KEYS[@]}"; do if (( ${#k} > w )); then w=${#k}; fi; done
    for ((i = 0; i < ${#KV_KEYS[@]}; i++)); do
        printf '%s\n' "$(printf '%-*s  %s' "$w" "${KV_KEYS[i]}" "${KV_VALS[i]}")"
    done
    return 0
}

# Common identification block of every notification body.
kv_start() { # <name> [image]
    KV_KEYS=() KV_VALS=()
    kv_add Container "$1"
    [[ $# -ge 2 ]] && kv_add Image "$2" || true
    return 0
}

# Failure notification: <severity> <title suffix> <reason> [extra key value ...]
notify_fail() {
    local severity=$1 suffix=$2 reason=$3
    local name body
    name=$(ct_name "$CT_CTID" "$CT_HOSTNAME")
    kv_start "$name" "$CT_IMAGE"
    body=$(kv_render)
    body+=$'\n'$'\n'"$reason"
    notify "$severity" "$name $suffix" "$body"
}

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

die() { log_error "$*"; exit 1; }

run_cmd() {
    if [[ $DRY_RUN == 1 ]]; then
        printf '%s[dry-run] %s\n' "$(_log_prefix)" "$*"
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
  --no-clean-mountpoints
                     Do not re-empty the rootfs directories that mpN: mounts are
                     bound over. On by default: Proxmox keeps those directories
                     empty and vzdump needs that invariant, but an OCI image
                     re-creates shadowed files (e.g. /root/.bashrc) on unpack.
  --verbose          Extra debug logging.
  --log-timestamps   Prefix every log line with a YYYY-MM-DD HH:MM:SS timestamp
                     (also for --dry-run output). Off by default.
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
  PVE_AUTOUPDATE_LOG_TIMESTAMPS, PVE_AUTOUPDATE_DRY_RUN,
  PVE_AUTOUPDATE_CLEAN_MOUNTPOINTS
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
        --clean-mountpoints) CLEAN_MOUNTPOINTS=1 ;;
        --no-clean-mountpoints) CLEAN_MOUNTPOINTS=0 ;;
        --verbose) VERBOSE=1 ;;
        --log-timestamps) LOG_TIMESTAMPS=1 ;;
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
CLEAN_MOUNTPOINTS=${CLEAN_MOUNTPOINTS:-1}
is_number "$SNAPSHOT_KEEP" || die "--snapshot-keep must be a number"
[[ $CLEAN_MOUNTPOINTS == 0 || $CLEAN_MOUNTPOINTS == 1 ]] ||
    die "PVE_AUTOUPDATE_CLEAN_MOUNTPOINTS must be 0 or 1"

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
CFG_HOSTNAME=""
CFG_ROOTFS_STORE=""
CFG_ROOTFS_VOL=""
CFG_UNPRIVILEGED=0
declare -a CFG_MOUNTPOINTS=()

parse_container_conf() {
    local ctid=$1 conf=$2
    local line key value fence=0 fences=0 image_seen=0 autoupdate_seen=0 bad=0

    CFG_HAS_BLOCK=0 CFG_BLOCK_INVALID=0 CFG_IMAGE="" CFG_KEEP=""
    CFG_HOSTNAME="" CFG_ROOTFS_STORE="" CFG_ROOTFS_VOL="" CFG_UNPRIVILEGED=0
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
        elif [[ $line =~ ^[[:space:]]*hostname:[[:space:]]*([^,[:space:]]+) ]]; then
            CFG_HOSTNAME=${BASH_REMATCH[1]}
        elif [[ $line =~ ^[[:space:]]*(mp[0-9]+):[[:space:]]*(.*)$ ]]; then
            # "mp0: store:volid,mp=/data,backup=1,size=8G" — the mp= option is what
            # names the rootfs directory the volume gets bound over. Parse the whole
            # option list so the position of mp= does not matter, and keep the
            # mountpoint even when backup=0 (they are all cleaned the same way).
            local mp_opt mp_target="" mp_rest=${BASH_REMATCH[2]}
            local -a mp_opts=()
            mp_rest=${mp_rest%"${mp_rest##*[![:space:]]}"}     # rtrim
            IFS=',' read -ra mp_opts <<< "$mp_rest"
            for mp_opt in "${mp_opts[@]}"; do
                mp_opt=${mp_opt#"${mp_opt%%[![:space:]]*}"}     # ltrim
                if [[ $mp_opt == mp=* ]]; then mp_target=${mp_opt#mp=}; fi
            done
            if [[ -n $mp_target ]]; then
                CFG_MOUNTPOINTS+=("$mp_target")
            else
                log_debug "ct $ctid: ${BASH_REMATCH[1]}: has no mp= option, ignoring"
            fi
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

# Sidecar with the image metadata of the last applied update, so the next run
# can report what changed (version, build date, source repo) and not just that
# the digest moved.
meta_file() { printf '%s/%s.meta' "$DIGEST_DIR" "$1"; }

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

# Fields asked from skopeo in one inspect call, tab separated: digest, version,
# created (OCI label first, config field as fallback), source, revision.
skopeo_format() {
    local t=$'\t'
    printf '{{.Digest}}%s{{index .Labels "org.opencontainers.image.version"}}%s{{index .Labels "org.opencontainers.image.created"}}%s{{.Created}}%s{{index .Labels "org.opencontainers.image.source"}}%s{{index .Labels "org.opencontainers.image.revision"}}' \
        "$t" "$t" "$t" "$t" "$t"
}

# Go templates print these placeholders for missing/nil fields.
normalize_field() {
    case $1 in
        '<no value>' | '<nil>' | 'null' | '""') printf '' ;;
        *) printf '%s' "$1" ;;
    esac
    return 0
}

REMOTE_DIGEST="" REMOTE_VERSION="" REMOTE_CREATED="" REMOTE_SOURCE="" REMOTE_REVISION=""

# Fills REMOTE_* for an image; returns non-zero when the registry gave us no
# digest at all. Missing metadata labels are not an error: the image is simply
# reported without those lines.
remote_image_info() {
    local image=$1 out label_created
    REMOTE_DIGEST="" REMOTE_VERSION="" REMOTE_CREATED="" REMOTE_SOURCE="" REMOTE_REVISION=""

    if out=$(skopeo inspect --format "$(skopeo_format)" "docker://$image" 2>/dev/null) && [[ -n $out ]]; then
        IFS=$'\t' read -r REMOTE_DIGEST REMOTE_VERSION REMOTE_CREATED label_created REMOTE_SOURCE REMOTE_REVISION <<<"$out"
        REMOTE_DIGEST=${REMOTE_DIGEST%%$'\t'*}
        REMOTE_VERSION=$(normalize_field "$REMOTE_VERSION")
        REMOTE_SOURCE=$(normalize_field "$REMOTE_SOURCE")
        REMOTE_REVISION=$(normalize_field "$REMOTE_REVISION")
        REMOTE_CREATED=$(normalize_field "$REMOTE_CREATED")
        [[ -z $REMOTE_CREATED ]] && REMOTE_CREATED=$(normalize_field "$label_created")
        [[ -n $REMOTE_DIGEST ]] && return 0
    fi

    # Older skopeo whose --format cannot handle the label lookups: still get the
    # digest, just without metadata.
    out=$(skopeo inspect --format '{{.Digest}}' "docker://$image" 2>/dev/null) || return 1
    [[ -n $out ]] || return 1
    REMOTE_DIGEST=${out%%$'\t'*}
    return 0
}

META_IMAGE="" META_DIGEST="" META_VERSION="" META_CREATED="" META_SOURCE="" META_REVISION=""

read_local_meta() {
    local f=$1 line key value
    META_IMAGE="" META_DIGEST="" META_VERSION="" META_CREATED="" META_SOURCE="" META_REVISION=""
    [[ -r $f ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || continue
        key=${line%%=*}; value=${line#*=}
        case $key in
            image)     META_IMAGE=$value ;;
            digest)    META_DIGEST=$value ;;
            version)   META_VERSION=$value ;;
            created)   META_CREATED=$value ;;
            source)    META_SOURCE=$value ;;
            revision)  META_REVISION=$value ;;
            updated_at) : ;;
        esac
    done < "$f"
    return 0
}

write_local_meta() {
    local ctid=$1 f tmp
    f=$(meta_file "$ctid"); tmp="$f.tmp.$$"
    {
        printf 'image=%s\n' "$CT_IMAGE"
        printf 'digest=%s\n' "$REMOTE_DIGEST"
        printf 'version=%s\n' "$REMOTE_VERSION"
        printf 'created=%s\n' "$REMOTE_CREATED"
        printf 'source=%s\n' "$REMOTE_SOURCE"
        printf 'revision=%s\n' "$REMOTE_REVISION"
        printf 'updated_at=%s\n' "$(_ts)"
    } > "$tmp" && mv -f "$tmp" "$f"
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
    CT_CTID=$ctid
    notify_fail error "update failed, rolled back" \
        "Update aborted ($reason). The rootfs was restored from snapshot $snap."
    ABORT=1
}

# ----------------------------------------------------------------------------
# mpN: mountpoint sanitising
# ----------------------------------------------------------------------------
#
# Proxmox never lets a secondary volume (mpN:) be bound over a *non-empty*
# directory in the rootfs, and vzdump relies on that invariant: it snapshots the
# rootfs dataset and chokes when a mounted volume would cover real files (a
# common symptom is a backup failing over /root because the image shipped
# .bashrc/.profile/.cache there). A fresh `umoci raw unpack` re-creates exactly
# those shadowed files, so we empty the shadowed directories again right after
# unpacking.
#
# Why this is safe to do there and only there:
#   * the container is stopped, so the mpN: volumes are NOT mounted and every
#     path below $root is rootfs content, not volume content;
#   * the rootfs was just wiped and re-populated by umoci alone, so nothing we
#     delete is operator data — it is only what the image shipped;
#   * everything under a mountpoint target is hidden by the bind mount for the
#     whole lifetime of the container, so removing it cannot change behaviour;
#   * we never resolve the mpN: source volume at all — the only path we ever
#     name is "$root/<target>" with $root the already validated ZFS dataset
#     mountpoint, and the guards below refuse a target that looks like a mount.

MP_CLEANED=() MP_SKIPPED=()

# Owner that rootfs files get from the host side of the id mapping.
map_owner() {
    if [[ $CFG_UNPRIVILEGED == 1 ]]; then
        local host=${IDMAP#*:}
        host=${host%%:*}
        if [[ $host =~ ^[0-9]+$ ]]; then
            printf '%s:%s' "$host" "$host"
            return 0
        fi
    fi
    printf '0:0'
    return 0
}

# Absolute, normalised, no '.'/'..'/'//' components, no whitespace.
mp_target_rel() { # <target> -> prints the path relative to the rootfs
    local t=$1 rel comp
    local -a comps=()
    [[ $t == /* ]] || return 1
    [[ $t =~ [[:space:]] ]] && return 1
    rel=${t#/}
    while [[ $rel == */ ]]; do rel=${rel%/}; done
    [[ -n $rel ]] || return 1
    IFS='/' read -ra comps <<< "$rel"
    for comp in "${comps[@]}"; do
        if [[ -z $comp || $comp == . || $comp == .. ]]; then return 1; fi
    done
    printf '%s' "$rel"
    return 0
}

# Reject a target whose path crosses a symlink inside the rootfs: an image could
# ship /var as a symlink and "clean" would then follow it somewhere else.
mp_crosses_symlink() { # <root> <rel>
    local cur=$1 comp
    local -a comps=()
    IFS='/' read -ra comps <<< "$2"
    for comp in "${comps[@]}"; do
        cur="$cur/$comp"
        if [[ -L $cur ]]; then return 0; fi
    done
    return 1
}

is_mount_point() { # <path>
    [[ -r /proc/mounts ]] || return 1
    awk -v p="$1" '$2 == p { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts
}

# Create the empty target directory PVE expects, then hand ownership of every
# component we created to the container's root (host-side uid): a directory
# owned by the host's uid 0 would be "nobody" inside an unprivileged CT.
ensure_mp_dir() { # <root> <rel>
    local root=$1 rel=$2 cur=$root comp owner first_missing=""
    local -a comps=()
    IFS='/' read -ra comps <<< "$rel"
    for comp in "${comps[@]}"; do
        cur="$cur/$comp"
        if [[ -z $first_missing && ! -e $cur ]]; then first_missing=$cur; fi
    done
    run_cmd mkdir -p "$root/$rel" || return 1
    [[ -z $first_missing ]] && return 0
    owner=$(map_owner)
    cur=$first_missing
    while [[ $cur == "$root"/* ]]; do
        run_cmd chown "$owner" "$cur" ||
            log_warn "could not chown '$cur' to $owner (mountpoint target ownership may be wrong)"
        cur=${cur%/*}
    done
    return 0
}

# Returns non-zero only when a delete/create actually failed: a refusal (odd
# path, symlink, mounted target) is a warning, never a reason to roll back.
clean_mountpoint_targets() { # <ctid> <rootfs path>
    local ctid=$1 root=$2
    local t rel dir dev rc=0

    MP_CLEANED=() MP_SKIPPED=()
    if ((${#CFG_MOUNTPOINTS[@]} == 0)); then
        return 0
    fi
    dev=$(stat -c %d "$root" 2>/dev/null || printf '%s' "")

    for t in "${CFG_MOUNTPOINTS[@]}"; do
        if ! rel=$(mp_target_rel "$t"); then
            log_warn "ct $ctid: mountpoint target '$t' is not a usable absolute path, leaving it alone"
            MP_SKIPPED+=("$t")
            continue
        fi
        dir="$root/$rel"

        if mp_crosses_symlink "$root" "$rel"; then
            log_warn "ct $ctid: '$dir' crosses a symlink inside the rootfs, refusing to touch it"
            MP_SKIPPED+=("$t")
            continue
        fi
        if is_mount_point "$dir"; then
            log_warn "ct $ctid: '$dir' is a mount point (secondary volume still mounted?), refusing"
            MP_SKIPPED+=("$t")
            continue
        fi
        if [[ -d $dir && ! -L $dir && -n $dev ]] &&
           [[ $(stat -c %d "$dir" 2>/dev/null || printf '%s' unknown) != "$dev" ]]; then
            log_warn "ct $ctid: '$dir' is on another device than the rootfs, refusing to clean it"
            MP_SKIPPED+=("$t")
            continue
        fi

        if [[ -e $dir && ! -L $dir ]] && [[ ! -d $dir ]]; then
            log_warn "ct $ctid: mountpoint target '$t' exists but is not a directory, refusing to touch it"
            MP_SKIPPED+=("$t")
            continue
        fi

        if [[ -d $dir ]]; then
            if [[ $DRY_RUN != 1 && -z $(ls -A "$dir" 2>/dev/null) ]]; then
                log_debug "ct $ctid: mountpoint target '$t' is already empty"
                continue
            fi
            log_info "ct $ctid: emptying '$t' — files there are shadowed by the mount anyway"
            if ! run_cmd find "$dir" -xdev -mindepth 1 -delete; then
                log_error "ct $ctid: could not empty the mountpoint target '$t'"
                MP_SKIPPED+=("$t")
                rc=1
                continue
            fi
            MP_CLEANED+=("$t")
        else
            log_info "ct $ctid: creating empty mountpoint target '$t' (absent from the image)"
            if ! ensure_mp_dir "$root" "$rel"; then
                log_error "ct $ctid: could not create the mountpoint target '$t'"
                MP_SKIPPED+=("$t")
                rc=1
                continue
            fi
        fi
    done
    if ((${#MP_CLEANED[@]})) || ((${#MP_SKIPPED[@]})); then
        log_info "ct $ctid: mountpoint targets emptied: ${MP_CLEANED[*]:-none}; left alone: ${MP_SKIPPED[*]:-none}"
    fi
    return $rc
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
    CT_CTID=$ctid CT_HOSTNAME=$CFG_HOSTNAME CT_IMAGE=$image
    [[ -n $CFG_KEEP ]] && keep=$CFG_KEEP

    if ! resolve_rootfs "$ctid" "$CFG_ROOTFS_VOL" "$CFG_ROOTFS_STORE"; then
        printf 'ct %-6s image=%s  -> NOT RESOLVED: %s\n' "$ctid" "$image" "${RESOLVE_REASON:-unknown reason}"
        log_info "ct $ctid: opted in but its ZFS rootfs could not be resolved safely, skipping"
        return 0
    fi

    local ds=$CT_DS path=$CT_ROOTFS_PATH

    if [[ $LIST_ONLY == 1 ]]; then
        local known_digest known_version
        known_digest=$(read_local_digest "$ctid")
        read_local_meta "$(meta_file "$ctid")" || true
        known_version=$META_VERSION
        printf 'ct %-6s image=%s\n' "$ctid" "$image"
        printf '         hostname=%s\n' "${CFG_HOSTNAME:-—}"
        printf '         store=%s pool=%s\n' "$CFG_ROOTFS_STORE" "$CT_POOL"
        printf '         dataset=%s\n' "$ds"
        printf '         rootfs=%s keep=%s unprivileged=%s\n' "$path" "$keep" "$CFG_UNPRIVILEGED"
        printf '         mountpoints=%s clean=%s\n' "${CFG_MOUNTPOINTS[*]:-none}" "$CLEAN_MOUNTPOINTS"
        printf '         applied digest=%s version=%s\n' "${known_digest:-none}" "${known_version:-unknown}"
        return 0
    fi

    log_info "ct $ctid: image=$image dataset=$ds rootfs=$path"

    # ---- digest check ------------------------------------------------------
    local remote local_digest
    if ! remote_image_info "$image"; then
        log_error "ct $ctid: skopeo inspect failed for $image (registry unreachable?)"
        notify_fail warning "update skipped" \
            "The image could not be inspected, no update was applied."
        return 0
    fi
    remote=$REMOTE_DIGEST
    local_digest=$(read_local_digest "$ctid")
    read_local_meta "$(meta_file "$ctid")" || true
    log_debug "ct $ctid: remote digest=${remote:-none} local digest=${local_digest:-none} remote version=${REMOTE_VERSION:-none} local version=${META_VERSION:-none}"

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
        notify_fail error "update failed" \
            "The image could not be pulled. The container rootfs was not modified."
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
            notify_fail error "update failed" \
                "The container could not be stopped; the rootfs was not modified."
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
        notify_fail error "update failed" \
            "Could not snapshot $ds; the rootfs was not modified."
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

    # ---- keep the mpN: mountpoint targets empty (PVE backup invariant) -----
    if [[ $CLEAN_MOUNTPOINTS == 1 ]] &&
       ! clean_mountpoint_targets "$ctid" "$path"; then
        rollback_container "$ctid" "$ds" "$snap" "$was_running" "mountpoint cleanup failed"
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
        write_local_meta "$ctid"
    fi
    log_info "ct $ctid: updated to $remote"

    # ---- notification: aligned key/value block ---------------------------
    local name title body
    name=$(ct_name "$ctid" "$CFG_HOSTNAME")
    title=$(update_title "$name" "$META_VERSION" "$REMOTE_VERSION")
    kv_start "$name" "$image"
    kv_add Digest "$(diff_value "$(short_digest "$local_digest")" "$(short_digest "$remote")")"
    kv_add Version "$(diff_value "$META_VERSION" "$REMOTE_VERSION")"
    kv_add Built "$(diff_value "$META_CREATED" "$REMOTE_CREATED")"
    kv_add Source "${REMOTE_SOURCE:-$META_SOURCE}"
    body=$(kv_render)
    notify info "$title" "$body"

    cleanup_oci "$ctid"
    prune_snapshots "$ds" "$keep"
    [[ -n $lockfd ]] && exec {lockfd}>&-
    return 0
}

die_unreachable() {
    local ctid=$1 image=$2
    log_error "ct $ctid: no digest available for $image"
    CT_CTID=$ctid CT_IMAGE=$image
    notify_fail warning "update skipped" "The registry reported no digest for this image."
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
