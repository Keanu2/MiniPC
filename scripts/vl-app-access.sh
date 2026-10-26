#!/system/bin/sh
# Administrative setup for in-process VL. No inference service or boot policy.
set -eu
work=/data/local/tmp/minipc-vl-app-access
state=$work/state
cache=/data/app/el2/100/base/com.jiuwen.registrychatui/cache
legacy_nodes='/dev/npu0 /dev/npu_manager /dev/dma_heap/system_heap /dev/dma_heap/npu_device_hugepage_heap'
nodes='/dev/npu0 /dev/npu_manager /dev/dma_heap/system_heap'
# Some PC chipsets expose no separate hugepage heap. Grant only existing nodes.
if test -e /dev/dma_heap/npu_device_hugepage_heap; then nodes=$legacy_nodes; fi
fail() { echo "ERROR: $*" >&2; exit 1; }
test "$(id -u)" = 0 || fail 'A root HDC session is required.'
test -d "$work" && test ! -L "$work" || fail 'Invalid setup directory.'
test "$(stat -c %u "$work")" = 0 || fail 'Setup directory must be root-owned.'
boot=$(cat /proc/sys/kernel/random/boot_id)

restore() {
  test -d "$state" || { echo 'No active access setup.'; return 0; }
  if test "$(cat "$state/boot")" != "$boot"; then
    if test -f "$state/worker.enabled" && test ! -e "$cache/vl-worker/enabled"; then
      mv "$state/worker.enabled" "$cache/vl-worker/enabled"
    fi
    mv "$state" "$work/previous-boot-$(date +%s)-$$"
    echo 'Earlier boot state archived; current driver permissions and SELinux mode left intact.'
    return 0
  fi
  local result=0 index=0 node inode device owner group mode expected current restore_nodes
  if test -f "$state/nodes"; then restore_nodes=$(cat "$state/nodes"); else restore_nodes=$legacy_nodes; fi
  # Restore only nodes whose identity and current permissions still match our lease.
  for node in $restore_nodes; do
    read -r inode device owner group mode expected < "$state/node-$index"
    current=$(stat -c '%i %t:%T %u %g %a' "$node")
    if test "$current" = "$inode $device $expected $group $mode"; then
      chown "$owner:$group" "$node" || result=1
    elif test "$current" != "$inode $device $owner $group $mode"; then
      echo "RESTORE_CONFLICT $node: $current" >&2; result=1
    fi
    index=$((index + 1))
  done
  local original
  original=$(cat "$state/selinux")
  case "$original" in Enforcing) setenforce 1 || result=1;; Permissive) setenforce 0 || result=1;; *) result=1;; esac
  if test -f "$state/worker.enabled"; then
    if test ! -e "$cache/vl-worker/enabled"; then
      mv "$state/worker.enabled" "$cache/vl-worker/enabled" || result=1
    else
      echo 'RESTORE_CONFLICT: worker enabled marker was changed separately.' >&2; result=1
    fi
  fi
  if test "$result" = 0; then
    mv "$state" "$work/restored-$(date +%s)-$$"
    echo 'Original SELinux mode and node ownership restored.'
  fi
  return "$result"
}

status() {
  echo "SELinux: $(getenforce)"
  if test -d "$state"; then
    echo "Saved boot: $(cat "$state/boot")"
    echo "Current boot: $boot"
    echo "App UID: $(cat "$state/uid")"
  else echo 'No active access setup.'; fi
  stat -c '%u %g %a %n' $nodes
  if test -e "$cache/vl-worker/enabled"; then echo 'Legacy worker marker: enabled'; else echo 'Legacy worker marker: disabled'; fi
}

case "${1:-status}" in
  status) status;;
  stop) restore; status;;
  start)
    uid=$(stat -c %u "$cache")
    case "$uid" in 2[0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) fail 'Open the installed compute HAP first; invalid app cache UID.';; esac
    if test -d "$state"; then
      if test "$(cat "$state/boot")" = "$boot"; then
        test "$(cat "$state/uid")" = "$uid" || fail 'App UID changed. Restore the prior setup first.'
        test "$(getenforce)" = Permissive || fail 'SELinux changed separately. Use Stop before Start.'
        index=0
        if test -f "$state/nodes"; then active_nodes=$(cat "$state/nodes"); else active_nodes=$legacy_nodes; fi
        for node in $active_nodes; do
          read -r inode device owner group mode expected < "$state/node-$index"
          test "$(stat -c '%i %t:%T %u %g %a' "$node")" = "$inode $device $expected $group $mode" || fail "Node changed separately: $node. Use Stop before Start."
          index=$((index + 1))
        done
        echo 'Access setup already exists; use Status or Stop before changing it.'
        status; exit 0
      fi
      # Reboot resets driver nodes. Never replay old inode ownership onto new nodes.
      if test -f "$state/worker.enabled" && test ! -e "$cache/vl-worker/enabled"; then
        mv "$state/worker.enabled" "$cache/vl-worker/enabled"
      fi
      mv "$state" "$work/previous-boot-$(date +%s)-$$"
    fi
    pending=$work/preparing-$$
    mkdir -m 700 "$pending"
    printf '%s\n' "$boot" > "$pending/boot"
    printf '%s\n' "$uid" > "$pending/uid"
    printf '%s\n' "$nodes" > "$pending/nodes"
    getenforce > "$pending/selinux"
    case "$(cat "$pending/selinux")" in Enforcing|Permissive) ;; *) fail 'Unsupported SELinux state.';; esac
    index=0
    for node in $nodes; do
      test -c "$node" && test ! -L "$node" || fail "Not a driver character node: $node"
      original=$(stat -c '%i %t:%T %u %g %a' "$node")
      read -r inode device owner group mode <<EOF
$original
EOF
      case "$mode" in
        660) test "$owner" = "$group" || fail "Owner/group differ on $node; refusing to remove the old owner's access."; expected=$uid;;
        666) expected=$owner;;
        *) fail "Unsupported original permissions on $node: $mode";;
      esac
      printf '%s %s\n' "$original" "$expected" > "$pending/node-$index"
      index=$((index + 1))
    done
    # Publish a complete snapshot before the first device mutation.
    mv "$pending" "$state"
    trap 'restore || true' EXIT
    index=0
    for node in $nodes; do
      read -r inode device owner group mode expected < "$state/node-$index"
      if test "$expected" != "$owner"; then chown "$expected" "$node"; fi
      index=$((index + 1))
    done
    if test -f "$cache/vl-worker/enabled"; then mv "$cache/vl-worker/enabled" "$state/worker.enabled"; fi
    setenforce 0
    trap - EXIT
    echo 'Direct VL access enabled. Restart the compute HAP after a prior initialization failure.'
    status
    ;;
  *) fail 'Usage: vl-app-access.sh start|status|stop';;
esac
