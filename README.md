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

Arguments are grouped by the component they configure, so it is clear which
knobs belong together:

```nix
devShells.a12 = config.android.mkShell {
  sdk = {
    platformVersions = [ "32" ];
    buildToolsVersions = [ "36.0.0" ];
    cmdLineToolsVersion = "19.0";
  };
  emulator = {
    version = "36.5.10";
    systemImageTypes = [ "android-automotive-playstore" ];
    abiVersions = [ "x86_64" ];
  };
  ndk.versions = [ "28.0.13004108" ];
  cmake.versions = [ "3.31.6" ];
  includeExtras = [ "extras;google;auto" ];
};
```

| Group | Options |
| --- | --- |
| `sdk` | `platformVersions`, `buildToolsVersions`, `cmdLineToolsVersion` |
| `emulator` | `version`, `enable`, `systemImageTypes`, `includeSystemImages`, `abiVersions`, `contentAddressedSystemImages` |
| `ndk` | `versions`, `enable` |
| `cmake` | `versions`, `enable` |

Omit a whole group to leave that component out — `mkShell { sdk.cmdLineToolsVersion = "19.0"; }`
is a valid shell with no platforms, build-tools, emulator, NDK, or CMake. Unknown
keys inside a group are rejected rather than ignored:

```
error: Unknown emulator option: systemImageType. Known options: version, enable,
systemImageTypes, includeSystemImages, abiVersions, contentAddressedSystemImages.
```

Ungrouped arguments (`includeSources`, `includeExtras`, `extraPackages`,
`repoJson`, `repoXmls`, `jdk`, `androidUserHome`, `androidAvdHome`) apply to the
environment as a whole. `androidUserHome` and `androidAvdHome` default to
`$HOME/.android` and `$HOME/.android/avd`, so set them only when a shell needs
somewhere else.

All the `*Versions` options take lists. For `sdk.buildToolsVersions` the order
matters — the first entry is the version Gradle's `aapt2FromMavenOverride`
points at, and the rest are installed so projects requesting them resolve:

```nix
sdk.buildToolsVersions = [ "36.0.0" "35.0.0" ];  # Gradle uses 36.0.0's aapt2
```

The shells currently defined are:

| Shell | What it is |
| --- | --- |
| `sdk` (`default`) | Minimal toolchain; components commented out in `flake.nix`, enable by uncommenting a version |
| `latest` | Every component pinned to upstream nixpkgs' newest, no system images |
| `a12` | Automotive emulator setup with system images |

`latest` tracks the newest versions upstream offers, but it is still a set of
hand-written pins — it does not resolve anything at eval time. Refresh it by
running `android-list-versions` and bumping any row where `pinned` and
`upstream-latest` have drifted apart. New upstream versions only appear there
after `nix flake update`.

`sdk.platformVersions`, `emulator.systemImageTypes`, and `emulator.abiVersions`
select the system images; `emulator.version` selects the emulator build. Version
arguments no longer accept `"latest"` and are never guessed — you pin them by
hand.

`emulator.abiVersions` is the CPU architecture of the *system image*
(`x86_64`, `arm64-v8a`, …). It defaults to the host architecture, so on an
x86_64 machine you get one x86_64 image; list several to install images for
several architectures side by side. It has no effect unless
`emulator.systemImageTypes` is set, and it does not influence the NDK, which
always builds for all of its target architectures.

Omitting a version argument means *"leave this component out"*, not "pick one
for me". `sdk.cmdLineToolsVersion` is the one required argument — it provides
`sdkmanager`/`avdmanager`, which the shell always puts on `PATH`.

Asking for a component without pinning it (`includeNdk = true` with no
`ndkVersions`) is an error rather than a silent default:

```
error: Android ndk is enabled but no version is pinned. Set the version
explicitly (run `android-list-versions ndk` to see the options), or disable it.
```

To
see which platform/type/abi combinations the catalog offers, run
`android-list-images` inside any shell — it lists what *can* be provisioned,
not what is installed.

To see which versions are available for the pinned components, run
`android-list-versions` inside any shell. With no argument it lists every
component; pass one to filter (`build-tools`, `cmake`, `cmdline-tools`,
`emulator`, `ndk`, `platforms`, …):

```bash
android-list-versions emulator
```

Each row is `component<TAB>version<TAB>tags`, sorted by version numerically.
The version this shell pins is tagged `pinned`, and whatever upstream nixpkgs
currently considers newest is tagged `upstream-latest` — so a component due for
a bump is one where those two tags are on different rows.

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

### 9. Change AVD settings in bulk

`avd-config` reads or sets `config.ini` values across all AVDs (or selected
ones with `--avd NAME`). Changes take effect on the next cold boot:

```bash
avd-config --get hw.multi_display_window
avd-config --set hw.multi_display_window=yes     # each display in its own window
avd-config --avd a33a --set hw.multi_display_window=no
```

Multi-display AVDs (e.g. automotive: head unit, cluster, passenger screens)
define their screens as `hw.displayN.*` blocks in `config.ini`; the primary
screen's size also depends on `environment.width`/`environment.height` and
`hw.lcd.*`, so keep those consistent across AVDs that should share a
resolution. `hw.multi_display_window` picks between one window per display or
a single window with the extra displays in Extended Controls. `refresh-avds
--apply` preserves `hw.display*`, `hw.lcd.*`, `environment.width`,
`environment.height`, `hw.multi_display_window`, and
`disk.dataPartition.size` when recreating an AVD.

### 10. Apply the standard display resolution to a new AVD

`avdmanager create avd --device <profile>` only seeds an initial
`config.ini`; it doesn't guarantee a specific resolution, and AVDs created
separately (or hand-edited) can drift apart even from the same profile. For
an AVD that should match a33/a33b's setup — primary display 1920x1080
@160dpi, second display 3840x1100 @213dpi — apply the preset after creating
it:

```bash
set-display-preset --avd a33c
```

This is a thin wrapper around the exact `avd-config --set ...` block used to
fix a33/a33b; equivalent to running `avd-config` once per key. Takes effect
on the AVD's next cold boot. Cloning an existing AVD with `clone-avd`
(step 8) carries its resolution over automatically and doesn't need this.

### 11. Trace with Perfetto

The shell ships Perfetto's `tracebox` (pinned in
[pkgs/tracebox.nix](pkgs/tracebox.nix)) and a `perfetto-bridge` command that
starts the adb WebSocket bridge for the Perfetto UI:

```bash
perfetto-bridge
```

Then open <https://ui.perfetto.dev>, and under "Record new trace" the running
devices/emulators appear via the WebSocket connection
(`ws://127.0.0.1:8037/adb`). Ctrl-C stops the bridge.

## Docs

- [avdmanager.md](avdmanager.md) — `avdmanager` reference and AVD workflow
- [remote.md](remote.md) — remote/headless emulator access via SSH forwarding
- [rename_emulator.md](rename_emulator.md) — patching an AVD's reported model name
- [AGENTS.md](AGENTS.md) — overlay maintenance notes for the metadata scripts
