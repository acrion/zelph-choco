# zelph (Chocolatey Package)

This repository contains the source files for the [official zelph Chocolatey package](https://community.chocolatey.org/packages/zelph).

**zelph** is a sophisticated semantic network system capable of encoding inference rules within the network itself.

🔗 Main Project Source Code: [acrion/zelph](https://github.com/acrion/zelph)

## 📦 Installation

To install zelph on Windows via Chocolatey, run:

```powershell
choco install zelph
```

To upgrade to the latest version:

```powershell
choco upgrade zelph
```

## 🛠 Maintainer Guide (How to update)

Steps to release a new version (e.g., `0.9.3`):

1.  Wait for the main [GitHub Release](https://github.com/acrion/zelph/releases) to be built.
2.  Get the SHA256 checksum of the new `zelph-windows.zip`.
3.  Update `zelph.nuspec`:
    *   Update `<version>`.
4.  Update `tools/chocolateyinstall.ps1`:
    *   Update `$url` (version number).
    *   Update `$checksum`.
5.  Pack and test locally:
    ```powershell
    choco pack
    choco uninstall zelph -y
    choco install zelph --source . -y --force
    zelph --version
    ```
6.  Push to Chocolatey:
    ```powershell
    choco push zelph.x.y.z.nupkg --source https://push.chocolatey.org/
    ```
7.  Commit and push changes to this repository.
