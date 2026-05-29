#!/usr/bin/env bash
set -euo pipefail

# Verifies the GPT "no competing ESP" fix in USBFormatterService.formatDevice.
#
# Background: `diskutil eraseDisk FAT32 <label> GPT <disk>` lays down its own
# ~200 MB EFI System Partition. During a Windows install that auto-ESP competes
# with the target disk's ESP, so bcdboot can write boot files onto the USB
# (pull the USB afterwards and the machine won't boot). The fix passes -noEFI so
# the USB gets a single Microsoft Basic Data partition, exactly like Rufus.
#
# This harness is NON-destructive: it operates only on a throwaway sparse disk
# image, never on a physical disk. No sudo required (the user owns the image).

readonly IMAGE_PATH="${TMPDIR:-/tmp}/rufusx_verify_gpt_no_esp.sparseimage"
readonly IMAGE_SIZE="8g"            # realistic USB size; <1 GB is too small to trigger the ESP
readonly LABEL_BASELINE="DATABASE"  # deliberately free of the substring "EFI"
readonly LABEL_FIXED="DATAVOL"

attached_disk=""

cleanup() {
    if [[ -n "${attached_disk}" ]]; then
        hdiutil detach "${attached_disk}" >/dev/null 2>&1 || true
    fi
    rm -f "${IMAGE_PATH}"
}
trap cleanup EXIT

# Counts partition rows whose TYPE column is exactly "EFI" (an EFI System
# Partition). Matching the type column avoids false positives from volume names.
count_esp() {
    local disk="$1"
    diskutil list "${disk}" | grep -cE ':[[:space:]]+EFI[[:space:]]' || true
}

main() {
    echo "==> Creating throwaway ${IMAGE_SIZE} sparse image"
    rm -f "${IMAGE_PATH}"
    hdiutil create -size "${IMAGE_SIZE}" -type SPARSE -layout GPTSPUD "${IMAGE_PATH%.sparseimage}" >/dev/null

    attached_disk="$(hdiutil attach -nomount "${IMAGE_PATH}" | head -1 | awk '{print $1}')"
    if [[ -z "${attached_disk}" ]]; then
        echo "FAIL: could not attach disk image" >&2
        exit 1
    fi
    echo "    attached as ${attached_disk}"

    echo "==> CASE A: current-style erase WITHOUT -noEFI (expect a competing ESP)"
    diskutil eraseDisk FAT32 "${LABEL_BASELINE}" GPT "${attached_disk}" >/dev/null
    diskutil list "${attached_disk}"
    local esp_baseline
    esp_baseline="$(count_esp "${attached_disk}")"

    echo "==> CASE B: fixed erase WITH -noEFI (expect a single Basic Data partition)"
    diskutil eraseDisk -noEFI FAT32 "${LABEL_FIXED}" GPT "${attached_disk}" >/dev/null
    diskutil list "${attached_disk}"
    local esp_fixed
    esp_fixed="$(count_esp "${attached_disk}")"

    echo
    echo "==> RESULT: ESP count without -noEFI = ${esp_baseline}, with -noEFI = ${esp_fixed}"
    if [[ "${esp_baseline}" -ge 1 && "${esp_fixed}" -eq 0 ]]; then
        echo "PASS: -noEFI removes the competing EFI System Partition."
        exit 0
    fi

    echo "FAIL: expected an ESP without -noEFI and none with it." >&2
    exit 1
}

main "$@"
