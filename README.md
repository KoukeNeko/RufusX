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

### Available or Implemented Foundation

- Format removable drives through macOS disk tools.
- Create bootable media from Windows, Linux, and UEFI Shell ISOs.
- Write raw `.img`, `.dd`, and `.raw` disk images.
- Compute MD5, SHA1, and SHA256 checksums of the selected image.
- Download UEFI Shell media.
- Run as a no-install macOS app bundle.

### Experimental / Requires Validation

- BIOS and BIOS+UEFI boot media.
- GPT boot media compatibility.
- FAT32 Windows media with WIM splitting.
- Windows 11 requirement bypasses.
- Windows OOBE customization.
- Windows To Go.
- Persistent Linux partitions.
- Bad block and fake-drive checks.
- Official Windows ISO download.
- Runtime UEFI media validation.
- Localization infrastructure.

### Requires Bundled Tools

- NTFS formatting and writing.
- UEFI:NTFS helper media.
- FreeDOS boot assets.
- Compressed image extraction/writing.
- VHD/DD image conversion/writing.
- ext2/ext3/ext4 filesystem tooling.

### Platform-Limited on macOS

- MS-DOS boot media.
- ReFS formatting.
- VHDX and FFU image writing/creation until a reliable backend is available.

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
