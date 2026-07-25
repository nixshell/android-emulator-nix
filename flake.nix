{
  description = "Reusable flake-parts module for Android SDK and emulator environments";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ./modules/android.nix ];
      systems = [ "x86_64-linux" ];

      flake.flakeModules = {
        default = ./modules/android.nix;
        android = ./modules/android.nix;
      };

      perSystem =
        { system, config, ... }:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
            config.android_sdk.accept_license = true;
          };
        in
        {
          _module.args.pkgs = pkgs;

          devShells.sdk = config.android.mkShell {
            sdk = {
              cmdLineToolsVersion = "19.0";
              buildToolsVersions = [
                # "36.0.0"
                # "35.0.0"
                # "34.0.0"
              ];
              platformVersions = [
                # "36"
                # "33"
                # "34"
              ];
            };
            # emulator.version = "36.5.10";
            # ndk.versions = [ "28.0.13004108" ];
            # cmake.versions = [ "3.31.6" ];
            includeExtras = [ "extras;google;auto" ];
            extraPackages = [
            ];
          };

          # Pinned to what upstream nixpkgs reported as newest when this was
          # last refreshed. These are hand-updated like every other pin: run
          # `android-list-versions` and bump the rows tagged upstream-latest.
          devShells.latest = config.android.mkShell {
            sdk = {
              platformVersions = [ "36" ];
              buildToolsVersions = [ "36.0.0" ];
              cmdLineToolsVersion = "19.0";
            };
            emulator.version = "36.5.10";
            ndk.versions = [ "28.0.13004108" ];
            cmake.versions = [ "3.31.6" ];
            includeExtras = [ "extras;google;auto" ];
          };

          devShells.a12 = config.android.mkShell {
            sdk = {
              platformVersions = [ "32" "33" ];
              buildToolsVersions = [ "36.0.0" ];
              cmdLineToolsVersion = "19.0";
            };
            emulator = {
              version = "36.5.10";
              systemImageTypes = [
                "android-automotive-playstore"
                "android-automotive"
              ];
              abiVersions = [ "x86_64" ];
              contentAddressedSystemImages = true;
            };
            ndk.versions = [ "28.0.13004108" ];
            cmake.versions = [ "3.31.6" ];
            includeExtras = [ "extras;google;auto" ];
          };

          devShells.default = config.devShells.sdk;
        };
    };
}
