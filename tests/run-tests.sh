#!/usr/bin/env bash
# Self-contained test suite. No real Proxmox/ZFS/registry needed: tests/mockbin
# provides fake pct/zfs/skopeo/umoci/pvesm backed by flat files.

set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TESTS_DIR/../pve-ct-autoupdate.sh"
MOCKBIN="$TESTS_DIR/mockbin"

[[ -x $SCRIPT ]] || { echo "script not executable: $SCRIPT" >&2; exit 1; }

PASS=0 FAIL=0 CURRENT="" T=""

# ----------------------------------------------------------------------------
# Harness helpers
# ----------------------------------------------------------------------------

setup() {
    T=$(mktemp -d "${TMPDIR:-/tmp}/pveautotest.XXXXXX")
    export MOCK_CALLS=$T/calls.log
    export MOCK_ROLLBACKS=$T/rollbacks.log
    export MOCK_PCT=$T/pct.status
    export MOCK_PVESM=$T/pvesm.paths
    export MOCK_ZFS_DB=$T/zfs.db
    export MOCK_ZFS_SNAPS=$T/snapshots
    export MOCK_NOTIFY=$T/notify.log
    export MOCK_DIGEST=${MOCK_DIGEST:-sha256:aaaa1111}

    export PVE_AUTOUPDATE_LXC_DIR=$T/etc/pve/lxc
    export PVE_AUTOUPDATE_STORAGE_CFG=$T/etc/pve/storage.cfg
    export PVE_AUTOUPDATE_STATE_DIR=$T/var/lib/pve-ct-autoupdate
    export PVE_AUTOUPDATE_LOCK_DIR=$T/lock
    export PVE_AUTOUPDATE_ALLOW_NON_ROOT=1
    export PVE_AUTOUPDATE_NOTIFY_CMD=$T/notify

    mkdir -p "$PVE_AUTOUPDATE_LXC_DIR" "$PVE_AUTOUPDATE_LOCK_DIR"
    : > "$MOCK_CALLS"; : > "$MOCK_ROLLBACKS"; : > "$MOCK_ZFS_SNAPS"; : > "$MOCK_PVESM"
    : > "$MOCK_NOTIFY"
    export MOCK_DIGEST

    cat > "$MOCK_PCT" <<'EOF'
200	running
100	stopped
EOF

    cat > "$T/notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$MOCK_NOTIFY"
EOF
    chmod +x "$T/notify"

    PATH="$MOCKBIN:$PATH"
    export PATH
}

teardown() {
    [[ -n $T ]] && rm -rf "$T"
    T=""
    unset MOCK_UMOCI_FAIL MOCK_PCT_STOP_FAIL MOCK_SKOPEO_COPY_FAIL MOCK_SKOPEO_INSPECT_FAIL MOCK_DIGEST
}

zfs_add() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$MOCK_ZFS_DB"; mkdir -p "$3"; }
pvesm_add() { printf '%s\t%s\n' "$1" "$2" >> "$MOCK_PVESM"; }
pct_state() { printf '%s\t%s\n' "$1" "$2" > "$MOCK_PCT.tmp"; mv "$MOCK_PCT.tmp" "$MOCK_PCT"; }

# conf_write <ctid> <heredoc-body-via-stdin>
conf_write() { cat > "$PVE_AUTOUPDATE_LXC_DIR/$1.conf"; }

storage_write() { cat > "$PVE_AUTOUPDATE_STORAGE_CFG"; }

run_script() {
    OUT_FILE=$T/stdout.txt
    ERR_FILE=$T/stderr.txt
    "$SCRIPT" "$@" > "$OUT_FILE" 2> "$ERR_FILE"
    RC=$?
}

check() { # check <description> <condition-cmd...>
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$desc"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$desc"
        printf '       rc=%s\n' "${RC:-?}"
        sed 's/^/       stderr| /' "$ERR_FILE" 2>/dev/null | tail -n 12
        sed 's/^/       calls | /' "$MOCK_CALLS" 2>/dev/null | tail -n 12
    fi
}

calls_has()      { grep -F -q "$1" "$MOCK_CALLS"; }
calls_hasnt()    { ! grep -F -q "$1" "$MOCK_CALLS"; }
notify_has()     { grep -F -q "$1" "$MOCK_NOTIFY"; }
notify_hasnt()   { ! grep -F -q "$1" "$MOCK_NOTIFY"; }
file_has()       { grep -F -q "$2" "$1"; }
rolled_back()    { grep -F -q "$1" "$MOCK_ROLLBACKS"; }
count_lines() { local n; n=$(grep -c "$1" "$2" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
rollback_count() { [[ $(count_lines . "$MOCK_ROLLBACKS") == "$1" ]]; }
snapshot_count() { [[ $(count_lines "@autoupdate-" "$MOCK_ZFS_SNAPS") == "$1" ]]; }
digest_of()      { cat "$PVE_AUTOUPDATE_STATE_DIR/digest/$1.digest" 2>/dev/null; }

test_start() { CURRENT=$1; printf '\n== %s\n' "$1"; }

# ----------------------------------------------------------------------------
# Common fixtures
# ----------------------------------------------------------------------------

STORAGE_ZFS() {
    storage_write <<'EOF'
zfspool local-zfs
        pool rpool
        content images,rootdir
        digest 1

dir backup-nfs
        path /mnt/backup
        content backup
EOF
}

# modern layout: rpool/subvol-200-disk-0
MODERN_DS() {
    zfs_add rpool filesystem "$T/rpool" yes
    zfs_add rpool/subvol-200-disk-0 filesystem "$ROOTFS" yes
    pvesm_add local-zfs:subvol-200-disk-0 "$ROOTFS"
}

valid_block_conf() {
    conf_write 200 <<EOF
#\`\`\`
#AutoUpdate=registry
#Image=registry.example.com/org/app%3Alatest
#\`\`\`
arch: amd64
cores: 4
hostname: ctauto-demo
memory: 4096
net0: name=eth0,bridge=vmbr0,ip=dhcp,type=veth
ostype: ubuntu
rootfs: local-zfs:subvol-200-disk-0,size=16G
swap: 0
unprivileged: 1
EOF
}

ROOTFS=""

# case using the exact syntax PVE writes in /etc/pve/storage.cfg
case_real_storage_cfg_syntax() {
    test_start "real PVE storage.cfg syntax (zfspool: id, pool <pool>/data)"
    setup
    ROOTFS=$T/rpool/data/subvol-200-disk-0
    storage_write <<'EOF'
dir: local
        path /var/lib/vz
        content backup,vztmpl,iso

zfspool: local-zfs
        pool rpool/data
        content rootdir,images
        sparse 1

cifs: nas-backups
        server 192.0.2.10
        content backup
EOF
    zfs_add rpool/data filesystem "$T/rpool/data" yes
    zfs_add rpool/data/subvol-200-disk-0 filesystem "$ROOTFS" yes
    pvesm_add local-zfs:subvol-200-disk-0 "$ROOTFS"
    valid_block_conf
    run_script --list
    check "storage parsed as zfspool" grep -F -q "store=local-zfs pool=rpool/data" "$OUT_FILE"
    check "dataset resolved" grep -F -q "dataset=rpool/data/subvol-200-disk-0" "$OUT_FILE"
    check "rootfs resolved" grep -F -q "rootfs=$ROOTFS" "$OUT_FILE"
    teardown
}

# add a second container (ct 100) to the fake pool/config
extra_ct100() {
    conf_write 100 <<EOF
#\`\`\`
#AutoUpdate=registry
#Image=registry.example.com/org/second:latest
#\`\`\`
rootfs: local-zfs:subvol-100-disk-0,size=8G
unprivileged: 1
EOF
    zfs_add rpool/subvol-100-disk-0 filesystem "$T/rpool/subvol-100-disk-0" yes
    pvesm_add local-zfs:subvol-100-disk-0 "$T/rpool/subvol-100-disk-0"
}

# ----------------------------------------------------------------------------
# Cases
# ----------------------------------------------------------------------------

case_dry_run() {
    test_start "dry-run performs no mutation but prints the commands"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    printf 'old content\n' > "$ROOTFS/keepme.txt"
    run_script --dry-run
    check "exit 0" test "$RC" -eq 0
    check "plans skopeo copy"   grep -F -q "skopeo copy docker://registry.example.com/org/app:latest oci:$PVE_AUTOUPDATE_STATE_DIR/oci/ct-200:autoupdate" "$OUT_FILE"
    check "plans pct stop"      grep -F -q "pct stop 200" "$OUT_FILE"
    check "plans wipe"          grep -F -q "find $ROOTFS -xdev -mindepth 1 -delete" "$OUT_FILE"
    check "plans umoci unpack"  grep -F -q "umoci raw unpack" "$OUT_FILE"
    check "plans uid/gid maps"  grep -F -q -- "--uid-map 0:100000:65536" "$OUT_FILE"
    check "plans snapshot"      grep -F -q "zfs snapshot rpool/subvol-200-disk-0@autoupdate-" "$OUT_FILE"
    check "no digest committed"      test -z "$(digest_of 200)"
    check "rootfs untouched"         test -f "$ROOTFS/keepme.txt"
    check "notification is marked [dry-run]" notify_has "[dry-run] LXC 200 updated"
    teardown
}

case_update_success() {
    test_start "digest change triggers a full update, snapshot pruned, digest stored"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    printf 'stale\n' > "$ROOTFS/old-file.txt"
    run_script
    check "exit 0" test "$RC" -eq 0
    check "old file gone (rootfs wiped)" bash -c "! test -e '$ROOTFS/old-file.txt'"
    check "unpacked marker"   test -f "$ROOTFS/.autoupdate-unpacked"
    check "container restarted" calls_has "pct start 200"
    check "snapshot created"  calls_has "zfs snapshot rpool/subvol-200-disk-0@autoupdate-"
    check "snapshot pruned (keep=0)" snapshot_count 0
    check "digest stored"     test "$(digest_of 200)" = "$MOCK_DIGEST"
    check "no rollback happened" rollback_count 0
    check "notified about update" notify_has "LXC 200 updated"
    teardown
}

case_digest_unchanged() {
    test_start "same digest -> nothing happens, no notification"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    mkdir -p "$PVE_AUTOUPDATE_STATE_DIR/digest"
    printf '%s\n' "$MOCK_DIGEST" > "$PVE_AUTOUPDATE_STATE_DIR/digest/200.digest"
    run_script
    check "exit 0" test "$RC" -eq 0
    check "no pull"      calls_hasnt "skopeo copy"
    check "no stop"      calls_hasnt "pct stop"
    check "no snapshot"  calls_hasnt "zfs snapshot"
    check "no notification" notify_hasnt "LXC 200"
    teardown
}

case_no_block() {
    test_start "container without an opt-in block is skipped silently"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS
    conf_write 200 <<'EOF'
arch: amd64
rootfs: local-zfs:subvol-200-disk-0,size=16G
unprivileged: 1
EOF
    run_script
    check "exit 0" test "$RC" -eq 0
    check "nothing called" bash -c "! grep -qE 'skopeo copy|pct stop|zfs snapshot' '$MOCK_CALLS'"
    check "no notification" notify_hasnt "200"
    teardown
}

case_invalid_mode() {
    test_start "AutoUpdate != registry invalidates the block"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS
    conf_write 200 <<'EOF'
#```
#AutoUpdate=manual
#Image=registry.example.com/org/app:latest
#```
rootfs: local-zfs:subvol-200-disk-0,size=16G
unprivileged: 1
EOF
    run_script
    check "exit 0" test "$RC" -eq 0
    check "skipped"   calls_hasnt "skopeo copy"
    check "no notification" notify_hasnt "200"
    teardown
}

case_unclosed_fence() {
    test_start "unterminated code block is not accepted"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS
    conf_write 200 <<'EOF'
#```
#AutoUpdate=registry
#Image=registry.example.com/org/app:latest
arch: amd64
rootfs: local-zfs:subvol-200-disk-0,size=16G
unprivileged: 1
EOF
    run_script
    check "skipped" calls_hasnt "skopeo copy"
    teardown
}

case_key_outside_block() {
    test_start "keys outside the fenced block are not honoured"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS
    conf_write 200 <<'EOF'
#AutoUpdate=registry
#Image=registry.example.com/org/app:latest
rootfs: local-zfs:subvol-200-disk-0,size=16G
unprivileged: 1
EOF
    run_script
    check "skipped" calls_hasnt "skopeo copy"
    teardown
}

case_unknown_key_ignored() {
    test_start "unknown keys inside the block are ignored"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS
    conf_write 200 <<'EOF'
#```
#AutoUpdate=registry
#Image=registry.example.com/org/app:latest
#ContainerCmd=/bin/false
#```
rootfs: local-zfs:subvol-200-disk-0,size=16G
unprivileged: 1
EOF
    run_script
    check "still updates" calls_has "skopeo copy"
    teardown
}

case_tag_required() {
    test_start "Image without a tag is rejected"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS
    conf_write 200 <<'EOF'
#```
#AutoUpdate=registry
#Image=registry.example.com/org/app
#```
rootfs: local-zfs:subvol-200-disk-0,size=16G
unprivileged: 1
EOF
    run_script
    check "skipped" calls_hasnt "skopeo copy"
    teardown
}

case_non_zfs_storage() {
    test_start "non-ZFS storage is skipped"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    storage_write <<'EOF'
lvmthin local-lvm
        vgname pve
        content images,rootdir
EOF
    conf_write 200 <<'EOF'
#```
#AutoUpdate=registry
#Image=registry.example.com/org/app:latest
#```
rootfs: local-lvm:vm-200-disk-0,size=16G
unprivileged: 1
EOF
    run_script
    check "skipped" calls_hasnt "skopeo copy"
    check "no notification" notify_hasnt "200"
    teardown
}

case_legacy_data_layout() {
    test_start "legacy <pool>/data/subvol-... layout is resolved, not assumed"
    setup
    ROOTFS=$T/rpool/data/subvol-200-disk-0
    STORAGE_ZFS
    zfs_add rpool filesystem "$T/rpool" yes
    zfs_add rpool/data filesystem "$T/rpool/data" yes
    zfs_add rpool/data/subvol-200-disk-0 filesystem "$ROOTFS" yes
    pvesm_add local-zfs:subvol-200-disk-0 "$ROOTFS"
    valid_block_conf
    run_script
    check "legacy rootfs unpacked" test -f "$ROOTFS/.autoupdate-unpacked"
    check "snapshots the legacy dataset" calls_has "zfs snapshot rpool/data/subvol-200-disk-0@autoupdate-"
    check "update succeeded" test "$(digest_of 200)" = "$MOCK_DIGEST"
    teardown
}

case_mountpoint_mismatch() {
    test_start "refuses when the resolved dir is not the dataset mountpoint"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS
    # pvesm points somewhere else than the real ZFS mountpoint
    pvesm_add local-zfs:subvol-200-disk-0 "$T/wrong/path"
    run_script
    check "no update" calls_hasnt "find $ROOTFS -xdev"
    check "no digest" test -z "$(digest_of 200)"
    teardown
}

case_foreign_ct() {
    test_start "containers whose dataset is absent (other node) are skipped quietly"
    setup
    ROOTFS=$T/rpool/subvol-999-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    conf_write 999 <<'EOF'
#```
#AutoUpdate=registry
#Image=registry.example.com/other/app:latest
#```
rootfs: local-zfs:subvol-999-disk-0,size=8G
unprivileged: 1
EOF
    run_script
    check "ct 200 still updated" test "$(digest_of 200)" = "$MOCK_DIGEST"
    check "ct 999 skipped" test -z "$(digest_of 999)"
    check "ct 999 not notified" notify_hasnt "LXC 999"
    teardown
}

case_umoci_failure_rolls_back() {
    test_start "unpack failure -> zfs rollback, no digest, run aborted"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    extra_ct100
    pct_state 100 running
    export MOCK_UMOCI_FAIL=1
    run_script
    check "rollback executed" rolled_back "rpool/subvol-100-disk-0@autoupdate-"
    check "digest NOT committed" test -z "$(digest_of 100)"
    check "container restarted after rollback" calls_has "pct start 100"
    check "error notified" notify_has "rolled back"
    check "processing aborted after rollback" calls_hasnt "subvol-200-disk-0"
    teardown
}

case_stop_failure() {
    test_start "container that cannot be stopped is left untouched"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    export MOCK_PCT_STOP_FAIL=1
    run_script
    check "no snapshot taken" calls_hasnt "zfs snapshot"
    check "no wipe" calls_hasnt "-xdev -mindepth 1 -delete"
    check "no rollback needed" rollback_count 0
    check "no digest" test -z "$(digest_of 200)"
    check "notified" notify_has "could not be stopped"
    teardown
}

case_pull_failure() {
    test_start "pull failure leaves the rootfs untouched and processing continues"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    extra_ct100
    export MOCK_SKOPEO_COPY_FAIL=1
    run_script
    check "no snapshot" calls_hasnt "zfs snapshot"
    check "no rollback" rollback_count 0
    check "no digest for 200" test -z "$(digest_of 200)"
    check "oci staging cleaned" bash -c "[ -z \"\$(ls -A '$PVE_AUTOUPDATE_STATE_DIR/oci/ct-200' 2>/dev/null)\" ]"
    check "next container still processed" calls_has "skopeo copy docker://registry.example.com/org/second:latest"
    check "error notified" notify_has "LXC 200 update failed"
    teardown
}

case_snapshot_keep() {
    test_start "SnapshotKeep keeps the N most recent snapshots"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS
    conf_write 200 <<'EOF'
#```
#AutoUpdate=registry
#Image=registry.example.com/org/app:latest
#SnapshotKeep=2
#```
rootfs: local-zfs:subvol-200-disk-0,size=16G
unprivileged: 1
EOF
    for i in 1 2 3; do
        export MOCK_DIGEST="sha256:000000000000000000000000000000000000000000000000000000000000000$i"
        run_script
    done
    check "3 snapshots created" bash -c "[ \"\$(grep -c 'zfs snapshot' '$MOCK_CALLS')\" = 3 ]"
    check "1 snapshot pruned"   bash -c "[ \"\$(grep -c 'zfs destroy' '$MOCK_CALLS')\" = 1 ]"
    check "2 snapshots remain" snapshot_count 2
    teardown
}

case_pvesm_only_and_stopped_ct() {
    test_start "already-stopped container is not stopped nor started again"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    pct_state 200 stopped
    run_script
    check "no pct stop call" calls_hasnt "pct stop 200"
    check "no pct start call" calls_hasnt "pct start 200"
    check "still updated" test "$(digest_of 200)" = "$MOCK_DIGEST"
    teardown
}

case_list_mode() {
    test_start "--list reports the resolution without touching anything"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    run_script --list
    check "reports the dataset" grep -F -q "dataset=rpool/subvol-200-disk-0" "$OUT_FILE"
    check "reports the decoded image" grep -F -q "image=registry.example.com/org/app:latest" "$OUT_FILE"
    check "no mutation" calls_hasnt "skopeo copy"
    teardown
}

case_ctid_filter() {
    test_start "--ctid restricts the run"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS; valid_block_conf
    extra_ct100
    run_script --ctid 100
    check "only ct 100 pulled" calls_has "skopeo copy docker://registry.example.com/org/second:latest"
    check "ct 200 untouched" test -z "$(digest_of 200)"
    teardown
}

case_privileged_no_map() {
    test_start "privileged containers get no uid/gid map"
    setup
    ROOTFS=$T/rpool/subvol-200-disk-0
    STORAGE_ZFS; MODERN_DS
    conf_write 200 <<'EOF'
#```
#AutoUpdate=registry
#Image=registry.example.com/org/app:latest
#```
rootfs: local-zfs:subvol-200-disk-0,size=16G
EOF
    run_script
    check "umoci called" calls_has "umoci raw unpack"
    check "no uid map" calls_hasnt "--uid-map"
    teardown
}

# ----------------------------------------------------------------------------

for fn in case_dry_run case_update_success case_digest_unchanged case_no_block \
          case_invalid_mode case_unclosed_fence case_key_outside_block \
          case_unknown_key_ignored case_tag_required case_non_zfs_storage \
          case_legacy_data_layout case_real_storage_cfg_syntax case_mountpoint_mismatch case_foreign_ct \
          case_umoci_failure_rolls_back case_stop_failure case_pull_failure \
          case_snapshot_keep case_pvesm_only_and_stopped_ct case_list_mode \
          case_ctid_filter case_privileged_no_map; do
    MOCK_DIGEST_DEFAULT=sha256:aaaa1111
    "$fn"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
