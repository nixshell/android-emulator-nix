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
            extraBuildToolsVersions = [
              # "34.0.0"
              # "35.0.0"
              # "36.0.0"
            ];
            platformVersions = [
              # "33"
              # "34"
              # "36"
            ];
            systemImageTypes = [ ];
            includeExtras = [ "extras;google;auto" ];
            androidUserHome = "$HOME/.android";
            androidAvdHome = "$HOME/.android/avd";
            extraPackages = [
            ];
          };

          devShells.default = config.devShells.sdk;
        };
    };
}
