{ pkgs, lib }:
let
  baseRepoJson = pkgs.path + "/pkgs/development/mobile/androidenv/repo.json";
  automotiveOverlayJson = ../../android-automotive-images.json;
  emulatorOverlayJson = ../../android-emulator-overlay.json;
  mergedRepoJson =
    let
      baseRepo = builtins.fromJSON (builtins.readFile baseRepoJson);
      automotiveOverlay =
        if builtins.pathExists automotiveOverlayJson then
          builtins.fromJSON (builtins.readFile automotiveOverlayJson)
        else
          { };
      emulatorOverlay =
        if builtins.pathExists emulatorOverlayJson then
          builtins.fromJSON (builtins.readFile emulatorOverlayJson)
        else
          { };
    in
    pkgs.writeText "androidenv-repo.json" (
      builtins.toJSON (lib.recursiveUpdate (lib.recursiveUpdate baseRepo automotiveOverlay) emulatorOverlay)
    );
in
{
  inherit
    automotiveOverlayJson
    baseRepoJson
    emulatorOverlayJson
    mergedRepoJson
    ;

  defaultRepoJson = mergedRepoJson;
}
