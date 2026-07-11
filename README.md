# android-emulator-nix

Reusable flake-parts module for Android SDK and emulator environments. Its main
extra over upstream `nixpkgs` androidenv is a pinned catalog of Android
Automotive system images plus newer emulator versions, merged in
[modules/android/repo-json.nix](modules/android/repo-json.nix) from:

- upstream `nixpkgs` metadata: `pkgs/development/mobile/androidenv/repo.json`
- [android-automotive-images.json](android-automotive-images.json) — automotive system images
- [android-emulator-overlay.json](android-emulator-overlay.json) — emulator versions

Everything (SDK, emulator binary, system images) is downloaded by nix when you
enter a dev shell. There is no `sdkmanager --install` step; the SDK lives
read-only in the nix store.

## Workflow: from new upstream image to running emulator

### 1. Update the pinned image catalog

Check for updates to already-pinned automotive images (dry run by default,
nothing is written):

```bash
./scripts/upgrade-android-automotive-images.rb
```

Apply what it found:

```bash
./scripts/upgrade-android-automotive-images.rb --apply
```

Dev-channel revisions are reported but skipped unless you opt in:

```bash
./scripts/upgrade-android-automotive-images.rb --apply --dev
./scripts/upgrade-android-automotive-images.rb --apply --dev-image 32/android-automotive-playstore/x86_64
./scripts/upgrade-android-automotive-images.rb --apply --only 35x
```

To pick up images that are not pinned yet, regenerate the whole overlay:

```bash
./scripts/update-android-automotive-overlay.rb
```

To refresh available emulator versions (and optionally move the default):

```bash
./scripts/update-android-emulator-overlay.rb            # keeps current latest
./scripts/update-android-emulator-overlay.rb --latest stable
```

This repo is consumed as a git flake: `git add` new or changed overlay files,
otherwise `nix` will not see them during evaluation.

### 2. Add the image to a dev shell

Shells are defined in [flake.nix](flake.nix) via `config.android.mkShell`. The
`a12` shell shows the automotive setup:

```nix
devShells.a12 = config.android.mkShell {
  platformVersions = [ "32" ];
  systemImageTypes = [ "android-automotive-playstore" ];
  abiVersion = "x86_64";
  includeExtras = [ "extras;google;auto" ];
  androidUserHome = "$HOME/.android";
  androidAvdHome = "$HOME/.android/avd";
};
```

`platformVersions`, `systemImageTypes`, and `abiVersion` select the system
images; `emulatorVersion` (default `"latest"`) selects the emulator build. To
see which platform/type/abi combinations the catalog offers, run
`android-list-images` inside any shell — it lists what *can* be provisioned,
not what is installed.

### 3. Enter the shell (this is the download step)

```bash
nix develop .#a12
```

nix fetches the emulator and the selected system images from the URLs pinned
in the overlay JSONs. The shell puts `sdkmanager`, `avdmanager`, `emulator`,
`adb`, and `scrcpy` on `PATH`, sets `ANDROID_SDK_ROOT`, `ANDROID_USER_HOME`,
and `ANDROID_AVD_HOME`, and prints the installed packages on entry
(`sdkmanager --list_installed` shows them again later).

### 4. Create an AVD from the image

```bash
avdmanager list device        # pick a hardware profile
avdmanager create avd \
  --name a32 \
  --device automotive_1408p_landscape_with_google_apis \
  --package 'system-images;android-32;android-automotive-playstore;x86_64'
```

`--package` must match an installed image path from
`sdkmanager --list_installed`. See [avdmanager.md](avdmanager.md) for the full
command reference.

### 5. Run the emulator

```bash
emulator -avd a32
```

Headless, with a predictable ADB port:

```bash
emulator -avd a32 -port 5554 -no-snapshot-load -gpu host -no-window
```

- Access from another machine over SSH: [remote.md](remote.md)
- Change the device model name an AVD reports: [rename_emulator.md](rename_emulator.md)

### 6. After an image upgrade: refresh stale AVDs

An AVD's disk state (userdata, snapshots, `hardware-qemu.ini`) is built from
the system image it last booted, and image upgrades change that nix store
path. The shell reports each AVD's status on entry; `refresh-avds` shows the
same report on demand:

```bash
refresh-avds            # dry run: ok / STALE / image not in this shell
refresh-avds --apply    # recreate stale AVDs (wipes their data)
refresh-avds --apply --only a32
```

Recreation reuses the AVD's name, system image, and device profile from its
`config.ini`.

### 7. Increase an AVD's disk space

```bash
resize-avd --avd a32 --data-size 16G --wipe
```

This sets `disk.dataPartition.size` in the AVD's `config.ini` and, with
`--wipe`, deletes the built userdata/cache images and snapshots so the next
boot rebuilds them at the new size. Wiping erases the AVD's data; without
`--wipe` the existing userdata keeps its old size until the AVD is wiped or
recreated. `--sdcard-size 1G` adjusts the SD card the same way.

`refresh-avds --apply` keeps a custom `disk.dataPartition.size` and the SD
card when it recreates an AVD.

### 8. Clone an AVD (compare before/after side by side)

```bash
clone-avd --avd a32 --name a32-b
```

This copies the AVD's data directory (self-contained: its qcow2 disk overlays
reference their base images by relative path) and writes a matching pointer
ini for the new name. Snapshots and lock files are not carried over —
snapshots record absolute paths into the source directory, and stale locks
block booting. Clone with the source emulator stopped for a consistent copy.

Run both, on distinct even console ports:

```bash
emulator -avd a32 -port 5554 &
emulator -avd a32-b -port 5556 &
```

ADB sees them as `emulator-5554` and `emulator-5556` (see
[remote.md](remote.md) for the port scheme). For a throwaway second instance
of the *same* AVD without cloning, `emulator -avd a32 -read-only` also works,
but its changes are discarded on exit.

## Docs

- [avdmanager.md](avdmanager.md) — `avdmanager` reference and AVD workflow
- [remote.md](remote.md) — remote/headless emulator access via SSH forwarding
- [rename_emulator.md](rename_emulator.md) — patching an AVD's reported model name
- [AGENTS.md](AGENTS.md) — overlay maintenance notes for the metadata scripts
