# RufusX for macOS

RufusX is a native macOS application designed to create bootable USB drives from ISO images, inspired by the popular Windows tool Rufus. It brings powerful features like Windows installation customization, Linux persistence, and robust drive formatting to the Mac ecosystem.

<img width="962" height="798" alt="image" src="https://github.com/user-attachments/assets/b32f4a30-19c9-4598-930d-2bd93b2a08e5" />


## Features

### 🚀 Bootable USB Creation

- **Windows Support**: Create bootable Windows 10/11 installation drives.
- **Linux Support**: Create bootable Linux drives (Ubuntu, Fedora, Debian, etc.) with support for both BIOS (Syslinux) and UEFI booting.
- **Hybrid ISOs**: Support for DD mode writing for hybrid ISO images.

### 🛠️ Windows Customization (User Experience)

Customize your Windows installation media directly from the app:

- **Bypass Requirements**: Remove checks for TPM 2.0, Secure Boot, and 4GB+ RAM.
- **Local Account**: Create a local account with a custom username (defaulting to your current macOS username).
- **Privacy**: Disable data collection and skip privacy questions.
- **Regional Settings**: Automatically set regional options to match your current system.

### 💾 Advanced Formatting & File Systems

- **FAT32 Support**: The default standard for maximum compatibility.
- **WIM Splitting**: Automatically splits large `install.wim` files (>4GB) to fit on FAT32 drives (requires `wimlib`).
- **Auto-ExFAT**: Automatically switches to ExFAT if a file is too large and WIM splitting is not available.
- **UEFI & BIOS**: Supports both target systems, including MBR and GPT partition schemes.
- **Linux Persistence**: Create a persistent partition to save data across reboots on Live Linux drives.

### 🛡️ Robust & Safe

- **Force Unmount**: Intelligent retry mechanism to handle stubborn mounted drives (`diskutil unmountDisk force`).
- **Admin Privileges**: Securely handles `sudo` operations for low-level disk writing (`dd`, `fdisk`, `mkfs`).
- **Validation**: Built-in checksum calculation (MD5, SHA1, SHA256) to verify ISO integrity.

## Installation

### Prerequisites

- macOS 13.0 (Ventura) or later.
- **Optional**: `wimlib` for splitting large Windows files on FAT32.
  ```bash
  brew install wimlib
  ```
  _Alternatively, you can bundle the `wimlib-imagex` binary directly into the app._

### Building from Source

1.  Clone the repository:
    ```bash
    git clone https://github.com/KoukeNeko/RufusX.git
    ```
2.  Open `RufusX.xcodeproj` in Xcode.
3.  Build and Run (Cmd+R).

## Usage

1.  **Select Device**: Choose your USB drive from the dropdown list.
2.  **Select ISO**: Click "Select" to choose your Windows or Linux ISO image.
3.  **Customize (Windows only)**:
    - If a Windows ISO is selected, click the "Windows User Experience" button (checkmark icon) to configure bypass options and local accounts.
4.  **Start**: Click "START" to begin the process.
    - You will be prompted for your system password to allow low-level disk access.
5.  **Wait**: The app will format the drive, copy files (splitting if necessary), and install the bootloader.

## Architecture

- **SwiftUI**: Modern, responsive user interface.
- **Combine**: Reactive state management.
- **GCD / Swift Concurrency**: Optimized background processing for heavy I/O operations to keep the UI responsive.
- **Shell Integration**: Direct interaction with system tools (`diskutil`, `hdiutil`, `dd`, `fdisk`) via a secure shell service.

## License

GPL-3.0 license
