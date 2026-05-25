# RufusX for macOS

RufusX is a native macOS app for creating bootable USB drives from ISO images.

The current build intentionally supports one verified path only:

**Windows installer ISO -> MBR -> UEFI (non CSM) -> exFAT**

Other Rufus-style modes are visible in the app as future directions, but they
are not selectable or supported yet.

<img width="962" height="798" alt="image" src="https://github.com/user-attachments/assets/b32f4a30-19c9-4598-930d-2bd93b2a08e5" />

## Currently Supported

- Create a bootable USB installer from a Windows ISO.
- Use MBR partition scheme.
- Use UEFI (non CSM) target system.
- Use exFAT file system.
- Validate that the selected ISO is a Windows installer before the app touches
  the USB drive.
- Format the selected external physical USB drive and copy Windows installer
  files to it.

## Planned / Not Supported Yet

The following options may appear in the app or codebase, but they are currently
locked or guarded because they are not complete:

- Linux bootable USB creation.
- Linux persistence partitions.
- DD image writing mode.
- BIOS / legacy boot.
- GPT target media.
- FAT/FAT32 boot media and WIM splitting as a supported flow.
- NTFS, UDF, ReFS, ext2, ext3, ext4, and APFS boot media flows.
- Cluster size customization.
- Advanced drive options such as old BIOS fixes and Rufus MBR BIOS ID.
- Advanced format options such as bad block checks and extended label/icon
  generation.
- Windows installer customization such as TPM/Secure Boot/RAM bypasses, local
  account creation, privacy defaults, and regional settings.
- Built-in Windows ISO download flow.

## Tested Configurations

| OS                    | Architecture | Partition Scheme | Target System  | File System | Status     | Notes                              |
| :-------------------- | :----------- | :--------------- | :------------- | :---------- | :--------- | :--------------------------------- |
| **Windows 11 (25H2)** | x64          | MBR              | UEFI (non CSM) | exFAT       | Success    | Booted and installed successfully. |

All other combinations should be treated as unsupported until they are added to
this table with successful test notes.

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

## Usage

1. Select an external USB drive from the Device menu.
2. Select a Windows installer ISO.
3. Wait for RufusX to validate the ISO.
4. Confirm that the visible settings are:
   - Partition scheme: MBR
   - Target system: UEFI (non CSM)
   - File system: exFAT
   - Persistent partition size: 0 GB
5. Click START.
6. Approve the macOS administrator prompt when asked.
7. Wait for the format and copy operation to finish.

RufusX rejects unsupported settings and non-Windows ISOs before unmounting or
formatting the USB drive.

## Architecture

- SwiftUI for the macOS user interface.
- Combine for app state observation.
- GCD and Swift concurrency for background I/O.
- Shell integration with macOS tools such as `diskutil` and `hdiutil`.

## License

GPL-3.0 license
