# Rename Emulator Model

The model name shown by `adb devices -l` comes from:

```text
/product/etc/build.prop
ro.product.product.model=<new-name>
```

For this repo, the reliable persistent path is to patch the AVD's `product`
logical partition offline inside `system-qemu.img`.

Requirements:

- the target emulator must be stopped
- run inside a dev shell that exposes `ANDROID_SDK_ROOT`

Usage:

```bash
nix develop .#android-a32-33b
rename-emulator-model --avd a33b --model a33b
```

If the AVD does not already have a persistent `system-qemu.img`, the script
seeds one from the SDK image first. To reset it from the SDK image before
patching, use:

```bash
rename-emulator-model --avd a33b --model a33b --force-seed
```

Verify with a normal cold boot:

```bash
emulator -no-snapshot-load -verbose -show-kernel -gpu host -no-window -avd a33b -port 5556
adb -s emulator-5556 wait-for-device shell getprop ro.product.model
adb -s emulator-5556 wait-for-device shell getprop ro.product.product.model
adb devices -l
```
