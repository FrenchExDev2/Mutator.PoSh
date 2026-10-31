#!/usr/bin/env bash
# Replaces only the OS-launch boundary during the offline seed isolation probe.
set -euo pipefail
disk=/storage/data.qcow2
base=/seed/storage/data.qcow2
test -f "$disk" && test -f "$base"
qemu-img info --output=json "$disk" > /shared/disk-info.json
qemu-io -r -f qcow2 -c 'read 1048576 512' "$base" > /shared/base-baseline.log
if qemu-io -r -f qcow2 -c 'read -P 0x5a 1048576 512' "$base" >/shared/base-read.log 2>&1; then
    echo 'The baseline already contains the test pattern; isolation cannot be proven.' >&2
    exit 1
fi
grep -qi 'Pattern verification failed' /shared/base-read.log
if [ "$MUTATOR_OVERLAY_PROBE" = writer ]; then
    qemu-io -f qcow2 -c 'write -P 0x5a 1048576 512' "$disk" > /shared/write.log
    qemu-io -f qcow2 -c 'read -P 0x5a 1048576 512' "$disk" > /shared/read.log
else
    qemu-io -r -f qcow2 -c 'read 1048576 512' "$disk" > /shared/reader-baseline.log
    if qemu-io -r -f qcow2 -c 'read -P 0x5a 1048576 512' "$disk" >/shared/read.log 2>&1; then
        echo 'A write from another clone leaked into this overlay.' >&2
        exit 1
    fi
    grep -qi 'Pattern verification failed' /shared/read.log
fi
if qemu-io -r -f qcow2 -c 'read -P 0x5a 1048576 512' "$base" >/shared/base-after.log 2>&1; then
    echo 'The backing disk was modified by a clone.' >&2
    exit 1
fi
grep -qi 'Pattern verification failed' /shared/base-after.log
jq -n --arg mode "$MUTATOR_OVERLAY_PROBE" --arg run "$MUTATOR_OVERLAY_RUN" --argjson bytes "$(stat -c %s "$disk")" \
    '{Outcome:"Success",Mode:$mode,RunId:$run,OverlayBytes:$bytes,WindowsBooted:false}' > /shared/overlay-proof.json
