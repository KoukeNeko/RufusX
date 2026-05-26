# RufusX for macOS

RufusX is a native macOS USB formatting and boot media utility inspired by
Rufus. The product goal is functional parity with the Rufus feature surface
while keeping a macOS-native interface and safety model.

The canonical upstream feature reference is the
[Rufus README](https://github.com/pbatard/rufus/blob/master/README.md).

<img width="962" height="798" alt="image" src="https://github.com/user-attachments/assets/b32f4a30-19c9-4598-930d-2bd93b2a08e5" />

## Feature Surface

RufusX exposes the Rufus feature set through a shared capability registry. Each
feature is classified as available, experimental, requires bundled tools, or
platform-limited.

### Capability Statuses

| Status | Meaning | Destructive execution behavior |
| :----- | :------ | :----------------------------- |
| Available | Implemented or available through macOS system tools. | May run when source image, device, and job plan validation pass. |
| Experimental | Visible in the UI, partially wired, or requiring VM/physical USB validation. | May warn, or may be blocked by executor guardrails until validated. |
| Requires bundled tool | Rufus-compatible surface exists, but a redistributable backend/tool asset is required. | Blocked before unmount/erase/write when the backend is missing or not wired. |
| Platform limited | Exposed for Rufus parity, but blocked by macOS platform limits, redistribution limits, or missing reliable backend. | Always blocked before unmount/erase/write. |

### Capability Matrix

| Feature | Status | Detail |
| :------ | :----- | :----- |
| Format removable drives | Available | Uses `diskutil` for FAT/FAT32/UDF/exFAT/APFS formatting. |
| UEFI boot media | Available | ISO file copy and EFI structure handling are available. |
| Bootable ISO images | Available | Windows/Linux ISO detection and copy flow are present. |
| Bootable disk images | Available | Raw write uses `dd` after preflight. |
| MD5/SHA1/SHA256/SHA512 | Available | MD5/SHA1/SHA256 are implemented; SHA512 remains visible in UI. |
| UEFI Shell ISO download | Available | UEFI Shell download URL is available. |
| No-install portable app behavior | Available | The app runs without installation from its bundle. |
| FAT/FAT32/NTFS/UDF/exFAT/ReFS/ext2/ext3 | Requires bundled tool | NTFS and ext support need bundled filesystem tools; ReFS is platform-limited. |
| FreeDOS boot media | Requires bundled tool | Requires a bundled FreeDOS boot image. |
| UEFI:NTFS boot media | Requires bundled tool | Requires bundled UEFI:NTFS helper assets. |
| Compressed disk images | Requires bundled tool | Requires a bundled extraction backend before writing. |
| ext2/ext3 filesystem support | Requires bundled tool | Requires bundled e2fsprogs-compatible tools. |
| BIOS boot media | Experimental | Existing syslinux/fdisk path is present but needs full boot validation. |
| Windows 11 requirement bypass | Experimental | UI exists; media injection must be completed and validated. |
| Windows To Go | Experimental | Selection exists; deployment backend still needs validation. |
| Persistent Linux partitions | Experimental | Persistence partition code exists; distro boot parameter validation remains required. |
| UEFI runtime validation | Experimental | Requires VM/firmware validation harness. |
| Windows OOBE customization | Experimental | UI exists; unattended file injection must be wired into media creation. |
| Bad block and fake-drive checks | Experimental | UI exists; scan executor needs destructive test validation. |
| Official Windows ISO download | Experimental | Microsoft retail ISO flow exists but depends on current public endpoints. |
| Localized UI foundation | Experimental | String extraction and locale files still need to be added. |
| MS-DOS boot media | Platform limited | MS-DOS boot files cannot be redistributed or generated reliably on macOS. |
| Create VHD/DD/VHDX/FFU images | Platform limited | Creating VHDX/FFU images needs a backend not available in this macOS build. |
| ReFS formatting | Platform limited | ReFS formatting is Windows-specific and blocked on macOS. |

### UI Option Matrix

| Area | Option | Status | Detail |
| :--- | :----- | :----- | :----- |
| Boot selection | Non bootable | Available | Formats the target drive without boot files. |
| Boot selection | Disk or ISO image | Available | Windows/Linux ISO detection and copy flow are present. |
| Boot selection | FreeDOS | Requires bundled tool | Requires a bundled FreeDOS boot image; executor guardrails currently block destructive use. |
| Boot selection | MS-DOS | Platform limited | MS-DOS boot files cannot be redistributed or generated reliably on macOS. |
| Boot selection | UEFI Shell | Available | UEFI Shell download URL is available. |
| Boot selection | Raw disk image | Available | Raw write uses `dd` after preflight. |
| Boot selection | Compressed image | Requires bundled tool | Requires a bundled extraction backend; executor guardrails currently block destructive use. |
| Boot selection | VHD/DD image | Experimental | Visible in UI, but qemu-img conversion/write executor is not wired yet. |
| Boot selection | VHDX image | Platform limited | VHDX write support needs a backend not available in this macOS build. |
| Boot selection | FFU image | Platform limited | FFU write support needs a backend not available in this macOS build. |
| File system | FAT, FAT32, exFAT, UDF, APFS | Available | Supported by macOS `diskutil` formatting. |
| File system | NTFS | Requires bundled tool | Requires bundled NTFS write/format backend; executor guardrails currently block destructive use. |
| File system | ext2, ext3 | Requires bundled tool | Requires bundled e2fsprogs-compatible tools; executor guardrails currently block destructive use. |
| File system | ext4 | Experimental | Persistence service can use e2fsprogs when available; general ext4 media still needs validation. |
| File system | ReFS | Platform limited | Windows-specific and blocked on macOS. |
| Target system | UEFI (non CSM) | Available | UEFI boot media path is available. |
| Target system | BIOS or UEFI | Experimental | Dual BIOS/UEFI setup exists for some ISOs but needs VM and hardware validation. |
| Target system | BIOS (or UEFI-CSM) | Experimental | Existing syslinux/fdisk path is present but needs full boot validation. |
| Partition scheme | MBR | Available | Supported by `diskutil`. |
| Partition scheme | GPT | Experimental | Supported by `diskutil`; boot compatibility varies by image and target system. |
| Windows image option | Standard Windows installation | Available | Creates standard installer media. |
| Windows image option | Windows To Go | Experimental | UI exists, but deployment is not wired into the executor yet. |

### Bundled Tool Slots

| Tool slot | Used for | Current expectation |
| :-------- | :------- | :------------------ |
| `wimlib-imagex` | Windows `install.wim` splitting and image operations. | May be bundled or found on the system. |
| `UEFI:NTFS` | Boot helper media for NTFS-based Windows installers. | Requires redistributable bundled helper assets before destructive use. |
| `Syslinux` | BIOS boot media support. | Requires bundled/system boot assets plus VM and hardware validation. |
| `GRUB` | Linux BIOS/UEFI boot media support. | Requires bundled/system boot assets plus distro validation. |
| `dosfstools` | FAT filesystem tooling parity. | May be bundled or found on the system when needed. |
| `e2fsprogs` | ext filesystems and Linux persistence partition creation. | Required before ext/persistence destructive paths can run. |
| `NTFS writer` | NTFS formatting and write support. | Required before NTFS destructive paths can run. |
| `qemu-img` | VHD/VHDX conversion/write workflows. | Required before VHD-family image workflows can run. |

Platform-limited paths are visible in the UI but are blocked before RufusX
unmounts, erases, or writes to a drive.

## Safety Model

Before any destructive operation, RufusX:

1. Analyzes the selected source image.
2. Builds a `RufusJobPlan` from the selected options and tool inventory.
3. Reports warnings for experimental or tool-backed paths.
4. Blocks platform-limited or missing-backend paths.
5. Logs the planned destructive steps before touching the USB drive.

## Tested Configuration

| OS                    | Architecture | Partition Scheme | Target System  | File System | Status  | Notes                              |
| :-------------------- | :----------- | :--------------- | :------------- | :---------- | :------ | :--------------------------------- |
| **Windows 11 (25H2)** | x64          | MBR              | UEFI (non CSM) | exFAT       | Success | Booted and installed successfully. |

Additional Rufus parity paths must be promoted from experimental to available
only after automated checks plus VM or physical USB boot validation.

## Installation

### Prerequisites

- macOS 13.0 (Ventura) or later.
- Xcode.

### Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/KoukeNeko/RufusX.git
   ```
2. Open `RufusX.xcodeproj` in Xcode.
3. Build and run with Cmd+R.

## Development Verification

```bash
xcodebuild -project RufusX.xcodeproj -scheme RufusX -configuration Debug -derivedDataPath /tmp/RufusXDerivedData-cca7 CODE_SIGNING_ALLOWED=NO build
```

## Packaging

Build a Developer ID-signed DMG on a Mac that has the Developer ID Application
certificate installed:

```bash
scripts/package_dmg.sh --output-dir dist
```

The script archives the Release app, signs nested executables, signs the app
bundle, creates a DMG, and signs the DMG. Add `--notarize` with either
`--notary-profile <profile>` or these environment variables to submit to Apple:

```bash
APPLE_NOTARY_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
APPLE_NOTARY_KEY_ID=XXXXXXXXXX
APPLE_NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000
```

CI builds every push and pull request without signing. The manual DMG workflow
can create a signed/notarized artifact when these GitHub secrets are configured:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `BUILD_KEYCHAIN_PASSWORD`
- `APPLE_NOTARY_KEY_P8_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

## License

GPL-3.0 license
