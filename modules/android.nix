{ ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      repoJson = import ./android/repo-json.nix { inherit pkgs lib; };
      environmentBuilder = import ./android/mk-environment.nix {
        inherit
          pkgs
          lib
          ;
        inherit (repoJson) defaultRepoJson;
      };
      mkAndroidEnvironment = args: environmentBuilder.mkAndroidEnvironment args;
      mkAndroidShell = args: (mkAndroidEnvironment args).shell;
      repoJsonInfo = repoJson // {
        default = repoJson.defaultRepoJson;
      };
    in
    {
      options.android = {
        repoJson = lib.mkOption {
          type = lib.types.attrs;
          readOnly = true;
          description = "Merged Android repository metadata and source file paths.";
        };

        mkEnvironment = lib.mkOption {
          type = lib.types.functionTo lib.types.anything;
          readOnly = true;
          description = "Build a configured Android environment record.";
        };

        mkShell = lib.mkOption {
          type = lib.types.functionTo lib.types.package;
          readOnly = true;
          description = "Build a configured Android development shell.";
        };
      };

      options.mkAndroidEnvironment = lib.mkOption {
        type = lib.types.functionTo lib.types.anything;
        readOnly = true;
        description = "Compatibility alias for android.mkEnvironment.";
      };

      options.mkAndroidShell = lib.mkOption {
        type = lib.types.functionTo lib.types.package;
        readOnly = true;
        description = "Compatibility alias for android.mkShell.";
      };

      config = {
        android = {
          repoJson = repoJsonInfo;
          mkEnvironment = mkAndroidEnvironment;
          mkShell = mkAndroidShell;
        };

        inherit mkAndroidEnvironment mkAndroidShell;
      };
    };
}
