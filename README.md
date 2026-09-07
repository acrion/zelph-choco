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

A new version may be released in two ways. `scripts/release.sh` handles the whole job from Linux, including the push. The manual route on Windows is kept below, because it is the only one that can run the package’s own install script before publishing. Both produce the same package.

### Releasing from Linux

Set this up once:

1. Install mono and jq. On Arch Linux:

   ```bash
   sudo pacman -S mono jq
   ```

2. Fetch Chocolatey CLI into `~/.local/lib/chocolatey`:

   ```bash
   scripts/install-choco.sh
   ```

   Chocolatey CLI is a .NET Framework program, and mono runs it. Packing and pushing are supported on Linux, installing is not.

3. Store your chocolatey.org API key outside of this repository. It is shown under [your account](https://community.chocolatey.org/account):

   ```bash
   mkdir -p ~/.config/zelph-choco
   printf '%s' 'YOUR-API-KEY' > ~/.config/zelph-choco/apikey
   chmod 600 ~/.config/zelph-choco/apikey
   ```

   The key never belongs in the repository. `scripts/release.sh` turns down a key file that others are allowed to read.

Then, once the [GitHub Release](https://github.com/acrion/zelph/releases) of the new version has been built:

```bash
scripts/release.sh
```

The script takes the newest zelph release, works out version and checksum from it, rewrites `zelph.nuspec` and `tools/chocolateyinstall.ps1`, packs, validates and asks before it pushes. It stops with an error at the first thing that does not hold:

- the tag is not of the form `vMAJOR.MINOR.PATCH`
- the repository has uncommitted changes
- the API key file is missing, readable by others, empty, or holds more than the bare key
- the release does not exist on GitHub, or carries no `zelph-windows.zip`
- that version is already published on the community feed
- the archive does not hash to the digest GitHub records for it
- `--package-fix` was asked for while the three-component version is not on the community feed
- the archive lacks `zelph.exe`, `zelph_tests.exe`, `zelph.dll` or the standard library
- rewriting the nuspec or the install script did not take effect
- the built package is missing any of the manifest elements listed below, states the wrong version, or carries an install script with the wrong checksum or URL

Useful options: `--tag vX.Y.Z` releases a version apart from the latest, `--package-fix N` publishes the package again around unchanged binaries (see below), `--no-push` stops after packing and validating, `--yes` skips the question, `--api-key-file` and `--choco-home` direct to alternative locations. `--help` displays every one.

Commit the two rewritten files afterwards. The script does not commit.

### Why the built package is validated

Packing rewrites the manifest, and this is where `nuget pack` and `dotnet pack` falter when creating a Chocolatey package: their manifest model lacks `packageSourceUrl`, `projectSourceUrl`, `docsUrl` and `bugTrackerUrl`, so those four elements are dropped without a word. The result installs correctly and still ends up in the community repository devoid of its source, documentation and issue links, where the moderation rules flag it. Chocolatey CLI keeps them.

That is why the script drives the real Chocolatey CLI, and why it opens the package it has just built to confirm the four elements survived.

### Publishing the package again without a new zelph release

The community feed never takes the same version twice. Where the binaries are right and only the package was wrong – the 1.0.1 install script ran a test suite, and the verifier killed the install when its timeout expired – Chocolatey’s response is a package fix version, a fourth component on the release version:

```bash
scripts/release.sh --tag v1.0.1 --package-fix 1
```

That publishes `1.0.1.1`. Only the `<version>` of the manifest moves; the archive, its checksum, the release notes and the tag all stay on `v1.0.1`. The script turns the option down when `1.0.1` is not on the feed, because the version to push is then that one.

### What the install script checks

After unpacking, the package puts three statements through `zelph.exe` and requires the answer to carry the fact they imply. It takes a few milliseconds, and it proves the chain that matters on a stranger's machine: the executable started, `zelph.dll` loaded beside it, the parser read a rule, and the engine derived something that stands in none of the three lines. The failure it exists for is a processor below `x86-64-v3`, which stops the binaries with an illegal instruction instead of a message.

Until 1.0.1 the script ran the fast test tier instead. That takes twenty-one seconds here, forty-six on the project's Windows runner, and more than forty-three minutes on the Chocolatey verifier, which killed the install when its execution timeout expired and turned the package down. A package may not spend a user's time on a test suite, and a budget measured on a machine you own says nothing about one you have never seen.

### Releasing on Windows

Steps to release a new version (e.g., `0.9.3`):

1.  Wait for the main [GitHub Release](https://github.com/acrion/zelph/releases) to be built.
2.  Get the SHA256 checksum of the new `zelph-windows.zip`.
3.  Update `zelph.nuspec`:
    *   Update `<version>`.
    *   Update `<releaseNotes>` (version number).
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

Step 5 has no counterpart on Linux, because the install script uses Windows-only Chocolatey functions. It is the step the section below is about.

### Testing the package without publishing anything

`scripts/release.sh` never runs the install script – Chocolatey installs only on Windows – so the two ways to exercise it before a push are:

- On any Windows machine, against a package built here: `choco pack`, then `choco install zelph --source . -y --force`. The GitHub release the script downloads from is public before the Chocolatey push, so this needs nothing new to be published.
- Against the verifier's own setup: [chocolatey-community/chocolatey-test-environment](https://github.com/chocolatey-community/chocolatey-test-environment) is the Vagrant box the package verifier mirrors. It runs on Linux with VirtualBox, and it is the only way to meet a machine as slow as theirs.

`bats tests/` covers what can be checked without Windows, including that a real zelph still derives the line the install script waits for. That case needs a binary; point `ZELPH_BIN` at one, otherwise it is skipped:

```bash
ZELPH_BIN=/path/to/zelph bats tests/
shellcheck scripts/*.sh
```

The last test packs with the real Chocolatey CLI and is skipped where none is installed. Everything else runs offline.
