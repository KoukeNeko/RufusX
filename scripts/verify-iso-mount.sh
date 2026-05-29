#!/usr/bin/env bash
set -euo pipefail

# Verifies the ISO mount-point detection used by USBFormatterService.mountISO.
#
# The old logic parsed `hdiutil attach`'s human-readable, tab-separated output
# and guessed the mount point from the last column. That is fragile for hybrid
# ISO9660/UDF images (e.g. Windows install ISOs) and could fail with
# "Could not determine mount point". The fix attaches with `-plist` and reads
# the mount-point of the system entity that exposes one.
#
# This harness builds a hybrid ISO (like a Windows ISO), attaches it with
# -plist, and asserts the mount point is resolved. Non-destructive; no sudo.

readonly WORK="${TMPDIR:-/tmp}/rufusx_iso_mount_test"
readonly SRC="${WORK}/src"
readonly ISO="${WORK}/hybrid.iso"
readonly VOLNAME="RUFUSXMOUNT"

mount_point=""
cleanup() {
    if [[ -n "${mount_point}" && -d "${mount_point}" ]]; then
        hdiutil detach "${mount_point}" >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

main() {
    echo "==> Building a hybrid ISO9660/UDF image (mimics a Windows ISO)"
    rm -rf "${WORK}"
    mkdir -p "${SRC}"
    printf 'rufusx mount harness\n' > "${SRC}/marker.txt"
    hdiutil makehybrid -o "${ISO}" -iso -udf -default-volume-name "${VOLNAME}" "${SRC}" >/dev/null

    echo "==> Attaching with -plist and extracting mount-point (the fix's approach)"
    local plist
    plist="$(hdiutil attach -plist -nobrowse -readonly -noverify -noautoopen "${ISO}")"
    mount_point="$(printf '%s' "${plist}" | python3 -c '
import sys, plistlib
pl = plistlib.loads(sys.stdin.buffer.read())
for entity in pl.get("system-entities", []):
    mp = entity.get("mount-point")
    if mp:
        print(mp)
        break
')"

    echo "    resolved mount-point = ${mount_point:-<none>}"
    if [[ -n "${mount_point}" && -d "${mount_point}" && -f "${mount_point}/marker.txt" ]]; then
        echo "PASS: -plist parsing resolved the ISO mount point."
        exit 0
    fi

    echo "FAIL: could not resolve a valid mount point via -plist." >&2
    exit 1
}

main "$@"
