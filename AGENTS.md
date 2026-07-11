# AGENTS

## Android Overlay Maintenance

The Android flake merges three metadata sources in [modules/android/repo-json.nix](modules/android/repo-json.nix):

- upstream `nixpkgs` Android metadata: `pkgs/development/mobile/androidenv/repo.json`
- local automotive system-image overlay: [android-automotive-images.json](android-automotive-images.json)
- local emulator-version overlay: [android-emulator-overlay.json](android-emulator-overlay.json)

### `android-automotive-images.json`

Purpose:
- adds automotive system images that are missing or mis-modeled in upstream `nixpkgs` metadata

Source:
- Google automotive system-image repository XML:
  `https://dl.google.com/android/repository/sys-img/android-automotive/sys-img2-3.xml`

How to bump already-pinned images (preferred):
- run [scripts/upgrade-android-automotive-images.rb](scripts/upgrade-android-automotive-images.rb)
- dry run by default; compares pinned entries against upstream per channel and only rewrites outdated entries

```bash
./scripts/upgrade-android-automotive-images.rb            # dry run
./scripts/upgrade-android-automotive-images.rb --apply    # write upgrades
```

Notes:
- stable and beta channels are accepted by default; `--dev` (all images) or
  `--dev-image API/TYPE/ABI` (one image) opt into dev-channel revisions
- `--only API[/TYPE[/ABI]]` limits the run to matching images
- it never downgrades: a lower revision on an allowed channel is not offered
  when the pin points at a higher dev-channel revision
- it warns when an upgrade requires a newer emulator than
  `latest.emulator` in [android-emulator-overlay.json](android-emulator-overlay.json)

How to regenerate from scratch (needed to pick up images not pinned yet):
- run [scripts/update-android-automotive-overlay.rb](scripts/update-android-automotive-overlay.rb)

```bash
./scripts/update-android-automotive-overlay.rb
```

Notes:
- the script rewrites the whole of [android-automotive-images.json](android-automotive-images.json)
- it keys images by package path components, so `android-automotive` and `android-automotive-playstore` remain distinct
- caveat: it is not channel-aware; when the same package exists in several
  channels it can mix metadata from one channel with archives from another.
  Run the upgrade script afterwards to reconcile such entries.

### `android-emulator-overlay.json`

Purpose:
- exposes emulator versions newer than what upstream `nixpkgs` `repo.json` currently contains
- can also override `latest.emulator`

Source:
- Google main Android repository metadata:
  `https://dl.google.com/android/repository/repository2-3.xml`

How it is generated:
- run [scripts/update-android-emulator-overlay.rb](scripts/update-android-emulator-overlay.rb)

Refresh command:

```bash
./scripts/update-android-emulator-overlay.rb
```

Notes:
- the script writes [android-emulator-overlay.json](android-emulator-overlay.json)
- the script also writes [android-emulator-availability.json](android-emulator-availability.json) with the upstream versions it saw plus `newVersions`, `changedVersions`, and `removedVersions` relative to the current overlay
- by default the script preserves the current `latest.emulator` if that version still exists upstream
- pass `--latest stable` to move `latest.emulator` to the newest stable upstream version, `--latest newest` for the newest version regardless of channel, or `--latest <version>` to pin a specific version
- if the flake should treat a new version as a custom emulator build, add the version to `customEmulatorVersions` in [modules/android/mk-environment.nix](modules/android/mk-environment.nix)

### Flake Evaluation Note

Because this repo is used as a git flake, new overlay files must be tracked by git or `nix` will not see them during evaluation.
