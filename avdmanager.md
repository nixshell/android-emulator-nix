# avdmanager

`avdmanager` manages Android Virtual Device definitions. It creates, lists, renames, and deletes AVDs. It does not boot them; `emulator` boots them.

## Command shape

```bash
avdmanager [global options] [action] [action options]
```

## Global options

- `-s`, `--silent`: errors only.
- `-v`, `--verbose`: more logging.
- `--clear-cache`: clears the SDK repository manifest cache.
- `-h`, `--help`: help for a command.

## Most useful action: `create avd`

```bash
avdmanager create avd \
  --name test-36 \
  --package 'system-images;android-36.1;google_apis;x86_64' \
  --device 'pixel_8'
```

Useful flags:

- `-n`, `--name`: required. The AVD name.
- `-k`, `--package`: required in practice. The system-image package path.
- `-d`, `--device`: hardware profile to base the AVD on. Can be an id or index from `avdmanager list device`.
- `-b`, `--abi`: choose ABI if a package supports more than one. Often unnecessary when the package path already implies one.
- `-g`, `--tag`: choose the system-image tag if ambiguous, such as `google_apis` or `google_apis_playstore`.
- `-p`, `--path`: where to store the AVD directory. If omitted, it uses the normal AVD location.
- `-c`, `--sdcard`: attach an SD card image or create one with a size like `512M`.
- `--skin`: choose a skin.
- `-f`, `--force`: overwrite an existing AVD with the same name.

How to think about the important ones:

- `--package` chooses the Android system image.
- `--device` chooses the virtual hardware shape.
- `--name` chooses how you refer to it later with `emulator -avd <name>`.

## Useful listing commands

- `avdmanager list avd`: show existing AVDs.
- `avdmanager list device`: show device profiles you can use with `--device`.
- `avdmanager list target`: show installed targets and system-image families.

Useful list flags:

- `-c`, `--compact`: script-friendly output.
- `-0`, `--null`: null-delimited output, mostly useful with `--compact`.

## Management commands

- `avdmanager delete avd --name test-36`: remove an AVD.
- `avdmanager move avd --name test-36 --rename pixel-test`: rename it.
- `avdmanager move avd --name test-36 --path /some/other/dir`: move its storage directory.

## Practical workflow in this repo

Inside `nix develop .#android-emulator`, the shell puts `avdmanager`, `sdkmanager`, and `emulator` on `PATH`. It also sets `ANDROID_USER_HOME` and `ANDROID_AVD_HOME`.

1. List available system images:

```bash
android-list-images
```

2. List available device profiles:

```bash
avdmanager list device
```

3. Create an AVD:

```bash
avdmanager create avd \
  --name pixel36 \
  --package 'system-images;android-36.1;google_apis;x86_64' \
  --device 'pixel_8'
```

4. Run it:

```bash
emulator -avd pixel36
```

## Notes

- If `avdmanager create avd` prompts about a custom hardware profile, answering `no` is usually fine.
- `google_apis_playstore` images are heavier but include Play Store support.
- If you only need a quick emulator, `google_apis` is often the simpler choice.
