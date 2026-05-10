# Remote Emulator Access

Use a fixed emulator port so the ADB port is predictable:

```bash
nix develop .#android-a32-33
emulator -no-snapshot-load -verbose -show-kernel -gpu host -no-window -avd a33 -port 5554
```

Port mapping:

- console port: `5554`
- adb port: `5555`

The emulator listens on localhost only, so use SSH port forwarding from another PC.

## Single Emulator

On the remote PC:

```bash
ssh -N -L 5555:localhost:5555 user@192.168.3.212
```

In another terminal on the remote PC:

```bash
adb connect localhost:5555
adb devices
```

## Android Studio

Once `adb connect` succeeds, Android Studio should see the device as:

```text
localhost:5555
```

## scrcpy

On the remote PC:

```bash
scrcpy -s localhost:5555
```

## Multiple Emulators

If the host runs multiple emulators, assign different even console ports:

```bash
emulator -avd a33 -port 5554 -no-snapshot-load -gpu host -no-window
emulator -avd other -port 5556 -no-snapshot-load -gpu host -no-window
```

This gives:

- emulator 1 adb port: `5555`
- emulator 2 adb port: `5557`

Forward both from the remote PC:

```bash
ssh -N \
  -L 5555:localhost:5555 \
  -L 5557:localhost:5557 \
  user@192.168.3.212
```

Then connect both:

```bash
adb connect localhost:5555
adb connect localhost:5557
adb devices
```

## Notes

- `-port <even>` sets the emulator console port.
- The emulator ADB port is always the next odd port.
- SSH forwarding is preferred over exposing emulator ports directly on the LAN.
