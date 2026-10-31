#!/usr/bin/env bash
set -euo pipefail
test -r /dev/kvm && test -w /dev/kvm && test -c /dev/net/tun
printf 'MemoryMaxBytes=%s\n' "$(cat /sys/fs/cgroup/memory.max)"
df -Pk / | awk 'NR==2 {print "DiskFreeKiB=" $4}'
awk '/MemAvailable:/ {print "VMAvailableKiB=" $2}' /proc/meminfo
printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"query-kvm","id":"mutator-kvm"}' '{"execute":"quit"}' |
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 128M -nodefaults -display none -S -qmp stdio
