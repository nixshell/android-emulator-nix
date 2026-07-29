# New machine setup

This guide creates the `a33a` and `a33b` Android 33 Automotive AVDs with the
repository's standard displays:

- primary display: 1920x1080 @160dpi
- second display: 3840x1100 @213dpi

The Android SDK, emulator, and system image come from Nix. Android Studio is
installed separately and is only needed for the final compatibility check.

## 1. Check prerequisites

Use an x86_64 Linux machine with Nix flakes enabled and hardware
virtualization available:

```bash
uname -m
nix --version
test -r /dev/kvm && test -w /dev/kvm && echo "KVM is available"
```

The expected architecture is `x86_64`. If the KVM check prints nothing, give
the user access to `/dev/kvm` before starting the emulator.

The repository is private, so configure GitLab SSH access before cloning.

## 2. Clone the shell

```bash
mkdir -p ~/projects/nix/shells
cd ~/projects/nix/shells
git clone git@gitlab.com:nixshell/android-emulator-nix.git
cd android-emulator-nix
```

GitLab is the source of truth. Do not add the GitHub mirror as a local remote.

## 3. Enter the Automotive shell

```bash
nix develop .#a12
```

The first invocation downloads the pinned Android SDK, emulator, and
Automotive images, so it can take a while and use several gigabytes.

The shell sets:

- `ANDROID_SDK_ROOT` to the read-only Nix SDK
- `ANDROID_USER_HOME` to `$HOME/.android`
- `ANDROID_AVD_HOME` to `$HOME/.android/avd`

Confirm that the Android 33 image is present:

```bash
sdkmanager --list_installed
```

The output must include:

```text
system-images;android-33;android-automotive;x86_64
```

## 4. Set up both AVDs

Run the setup command once for each AVD:

```bash
setup-avd a33a
setup-avd a33b
```

`setup-avd` only takes the AVD name. It currently selects the named setup
profile `automotive-1920x1080-160dpi`, which contains the system-image,
hardware-profile, display-preset, and verification settings.

The profile is self-contained in
`profiles/automotive-1920x1080-160dpi/`: `profile.rb` contains the setup
values and `device.xml` contains Android's hardware definition. Both generic
commands load that profile instead of embedding its values.

For a missing AVD, the command:

1. checks that the required Android 33 Automotive image exists
2. creates the AVD without `--force`
3. installs or merges the custom hardware profile
4. links the AVD to that profile and applies all display values
5. verifies the resulting `config.ini`

The command is idempotent. For an existing AVD using the expected system
image, it reapplies and verifies the profile without touching userdata. It
refuses to repurpose an existing AVD using a different image or overwrite an
orphaned AVD directory.

When additional complete setup profiles are added, they can share the same
creation workflow; no second profile choice is exposed while only one exists.

## 5. Verify the stored profile

`setup-avd` already performs this verification. To inspect the stored values
manually:

```bash
avd-config \
  --avd a33a \
  --avd a33b \
  --get hw.device.name \
  --get hw.lcd.width \
  --get hw.lcd.height \
  --get hw.lcd.density \
  --get hw.display2.width \
  --get hw.display2.height \
  --get hw.display2.density
```

Expected values after each `a33a:`/`a33b:` prefix:

```text
hw.device.name=automotive_1920x1080_160dpi
hw.lcd.width=1920
hw.lcd.height=1080
hw.lcd.density=160
hw.display2.width=3840
hw.display2.height=1100
hw.display2.density=213
```

The profile should also appear in:

```bash
avdmanager list device
```

## 6. Launch the emulators

Run each command in its own terminal after entering `nix develop .#a12`:

```bash
emulator -no-snapshot-load -verbose -show-kernel -gpu host \
  -avd a33a -port 5554
```

```bash
emulator -no-snapshot-load -verbose -show-kernel -gpu host \
  -avd a33b -port 5556
```

The even emulator ports map to these ADB serials:

- `a33a`: `emulator-5554`
- `a33b`: `emulator-5556`

## 7. Verify the live primary displays

After each emulator finishes booting:

```bash
adb -s emulator-5554 wait-for-device
adb -s emulator-5554 shell wm size
adb -s emulator-5554 shell wm density

adb -s emulator-5556 wait-for-device
adb -s emulator-5556 shell wm size
adb -s emulator-5556 shell wm density
```

Each must report:

```text
Physical size: 1920x1080
Physical density: 160
```

To check the configured secondary display:

```bash
adb -s emulator-5554 shell dumpsys display |
  grep -E 'Emulator 2D Display|3840 x 1100'
```

## 8. Verify Android Studio compatibility

Open a real Android project in Android Studio. Merely showing the welcome
screen may not initialize Device Manager, so pass the project directory:

```bash
android-studio /path/to/android/project
```

Wait at least 30 seconds, then check the persisted values again from a shell
where `nix develop .#a12` is active:

```bash
avd-config \
  --avd a33a \
  --avd a33b \
  --get hw.device.name \
  --get hw.lcd.width \
  --get hw.lcd.height \
  --get hw.lcd.density
```

They must remain linked to `automotive_1920x1080_160dpi` at
1920x1080 @160dpi. Android Studio may refresh `hw.device.hash2` once for its
SDK tools version; that is expected and does not change the display.

## Updating this installation

After pulling repository changes:

```bash
git pull origin main
nix develop .#a12
setup-avd a33a
setup-avd a33b
```

The setup commands update the installed profile if necessary and remain
no-ops when everything already matches.

`refresh-avds` is a dry run, but `refresh-avds --apply` recreates stale AVDs
and wipes their userdata. Do not use `--apply` as a routine update step.
