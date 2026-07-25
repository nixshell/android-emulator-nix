# Removed `"latest"` defaults

`mkAndroidEnvironment` used to accept `"latest"` for version arguments and
resolve it at eval time against `repo.latest.<key>` from the merged
`androidenv-repo.json`. That meant a `nix flake update` could silently change
which SDK components a shell built with.

All of this was removed: the `resolveRepoVersion` helper is gone, `"latest"` is
no longer accepted, and no version is ever guessed — consumers pin them by hand.

Omitting a version argument means **"leave this component out"**, not "pick one
for me". Only `cmdLineToolsVersion` is required, since `sdkmanager`/`avdmanager`
are always on the shell's `PATH` and their store paths embed that version. A
shell setting nothing else builds successfully with no platforms, build-tools,
emulator, NDK, or CMake.

Enabling a component without pinning it — `includeEmulator = true` with no
`emulatorVersion`, or `includeNdk = true` with an empty `ndkVersions` — throws
rather than falling back to `repo.latest`. That distinction is the whole point:
"I don't want this" and "I forgot to pin this" must not look the same.

## Arguments that lost their defaults

| Argument | Old default | New default | Meaning when omitted |
| --- | --- | --- | --- |
| `platformVersions` | `[ "36" ]` | `[ ]` | no platforms installed |
| `buildToolsVersion` | `"latest"` | argument removed | — |
| `extraBuildToolsVersions` | `[ "36.0.0" ]` | argument removed | — |
| `buildToolsVersions` | — | `[ ]` | no build-tools installed |
| `cmdLineToolsVersion` | `"latest"` | **required** | — must always be pinned |
| `emulatorVersion` | `"latest"` | `null` | emulator excluded |
| `ndkVersion` | `"latest"` | argument removed | — |
| `ndkVersions` | `[ ndkVersion ]` | `[ ]` | NDK excluded |
| `cmakeVersion` | `"latest"` | argument removed | — |
| `cmakeVersions` | `[ cmakeVersion ]` | `[ ]` | CMake excluded |

`includeEmulator`, `includeNdk`, and `includeCmake` now default to whether the
corresponding version argument was supplied, so the version pin alone is enough
to turn a component on. Set them to `true` explicitly only if you want the
"enabled but unpinned" error as a guard.

## `buildToolsVersion` + `extraBuildToolsVersions` → `buildToolsVersions`

The two build-tools arguments were merged into one list, matching the shape of
`ndkVersions` and `cmakeVersions`. They were only ever concatenated into a
single list internally, so the split bought nothing except a misleading name —
"extra" implied a supplement to a required primary, but after the `"latest"`
removal neither was required.

```nix
# before
buildToolsVersion = "36.0.0";
extraBuildToolsVersions = [ "35.0.0" "34.0.0" ];

# after
buildToolsVersions = [ "36.0.0" "35.0.0" "34.0.0" ];
```

Order is significant: the **first** entry is what Gradle's
`aapt2FromMavenOverride` points at. Everything else treats the list as an
unordered set, and duplicates are removed. An empty list installs no build-tools
and omits the `GRADLE_OPTS` export entirely.

Both old names are removed rather than deprecated — passing either now fails
with `called with unexpected argument 'buildToolsVersion'`.

## Flat arguments → per-component groups

The signature was flat, which made it impossible to see that `abiVersions` and
`systemImageTypes` only matter to the emulator — `abiVersions` sat between
`contentAddressedSystemImages` and `androidUserHome`, nowhere near the option it
depends on. Arguments are now nested under the component they configure:

| Old flat argument | New location |
| --- | --- |
| `platformVersions` | `sdk.platformVersions` |
| `buildToolsVersions` | `sdk.buildToolsVersions` |
| `cmdLineToolsVersion` | `sdk.cmdLineToolsVersion` |
| `emulatorVersion` | `emulator.version` |
| `includeEmulator` | `emulator.enable` |
| `systemImageTypes` | `emulator.systemImageTypes` |
| `includeSystemImages` | `emulator.includeSystemImages` |
| `abiVersions` | `emulator.abiVersions` |
| `contentAddressedSystemImages` | `emulator.contentAddressedSystemImages` |
| `ndkVersions` | `ndk.versions` |
| `includeNdk` | `ndk.enable` |
| `cmakeVersions` | `cmake.versions` |
| `includeCmake` | `cmake.enable` |

`includeSources`, `includeExtras`, `extraPackages`, `repoJson`, `repoXmls`,
`jdk`, `androidUserHome`, and `androidAvdHome` stayed top-level — they apply to
the environment rather than to one component.

Nesting costs Nix's built-in "unexpected argument" check, since a group is just
an attrset. A `checkKeys` helper reinstates it per group, so a typo throws
instead of silently defaulting:

```
error: Unknown emulator option: systemImageType. Known options: version, enable,
systemImageTypes, includeSystemImages, abiVersions, contentAddressedSystemImages.
```

Missing `sdk.cmdLineToolsVersion` throws its own message pointing at
`android-list-versions cmdline-tools`. Old flat arguments still fail loudly via
Nix's own check, since the top-level signature no longer accepts them.

The singular `ndkVersion` and `cmakeVersion` arguments were dropped rather than
made mandatory: they only ever served as the default element of the plural
lists, so keeping them would have forced callers to pass a value even when
supplying the list directly. `sdkArgs.ndkVersion` is now derived from the head
of `ndkVersions` (`null` when that list is empty).

## `repo.latest` values at the time of removal

Resolved from the merged repo JSON on 2026-07-25. These are the values the old
`"latest"` would have produced, and the source for the pins above:

```json
{
  "build-tools": "36.0.0",
  "cmake": "3.31.6",
  "cmdline-tools": "19.0",
  "emulator": "36.5.10",
  "ndk": "28.0.13004108",
  "ndk-bundle": "22.1.7171670",
  "platform-tools": "35.0.2",
  "platforms": "36",
  "skiaparser": "7",
  "sources": "36",
  "tools": "26.1.1"
}
```

`platform-tools`, `ndk-bundle`, `skiaparser`, `sources`, and `tools` are listed
for completeness — no argument ever resolved against those keys.

## How to update from now on

Run `android-list-versions` inside any shell to see every version the repo
metadata offers. Pass a component name to filter:

```bash
android-list-versions            # everything
android-list-versions emulator   # just the emulator
```

Rows are `component<TAB>version<TAB>tags`, sorted numerically. The version the
current shell pins is tagged `pinned`; the version upstream nixpkgs considers
newest is tagged `upstream-latest`. When both tags sit on the same row the pin
is current — when they diverge, that component has an update waiting.

To check what is outdated across the board:

```bash
android-list-versions | grep -E 'pinned|upstream-latest'
```

`repo.latest` still exists in the upstream repo JSON; it is simply no longer
consulted for resolution, only surfaced as the `upstream-latest` tag. After
picking versions, edit the pins in `flake.nix` by hand.

Bumping a pin only changes what a shell builds — it does not fetch new
metadata. New versions appear in the listing only after `nix flake update`
pulls a newer nixpkgs (or after the local overlay JSONs gain entries).

## Note on `platformVersions` in the `sdk` shell

The `sdk` shell previously passed `platformVersions = [ ]`, which overrode the
`[ "36" ]` default and built with no platforms at all. It is now pinned to
`[ "36" ]`. Set it back to `[ ]` if the empty list was intentional.
