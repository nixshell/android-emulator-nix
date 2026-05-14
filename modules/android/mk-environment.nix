{
  pkgs,
  lib,
  defaultRepoJson,
}:
let
  defaultAbiVersion =
    if pkgs.stdenv.hostPlatform.isAarch64 then "arm64-v8a" else "x86_64";

  sanitizeName = value: lib.replaceStrings [ "." "_" ] [ "-" "-" ] value;
in
{
  inherit defaultAbiVersion sanitizeName;

  mkAndroidEnvironment =
    {
      platformVersions ? [
        "36"
      ],
      buildToolsVersion ? "latest",
      extraBuildToolsVersions ? [
        "36.0.0"
      ],
      cmdLineToolsVersion ? "latest",
      includeEmulator ? true,
      emulatorVersion ? "latest",
      includeNdk ? false,
      ndkVersion ? "latest",
      includeSources ? true,
      includeSystemImages ? null,
      systemImageTypes ? [ ],
      extraPackages ? [ ],
      includeExtras ? [ ],
      repoJson ? defaultRepoJson,
      repoXmls ? null,
      abiVersion ? defaultAbiVersion,
      androidUserHome ? "$HOME/.android",
      androidAvdHome ? "$HOME/.android/avd",
    }:
    let
      repo = builtins.fromJSON (builtins.readFile repoJson);
      repoOs =
        {
          x86_64-linux = "linux";
          x86_64-darwin = "macosx";
          aarch64-linux = "linux";
          aarch64-darwin = "macosx";
        }
        .${pkgs.stdenv.hostPlatform.system} or "all";
      repoArch =
        {
          x86_64-linux = "x64";
          x86_64-darwin = "x64";
          aarch64-linux = "aarch64";
          aarch64-darwin = "aarch64";
        }
        .${pkgs.stdenv.hostPlatform.system} or "all";

      resolveRepoVersion = key: version: if version == "latest" then repo.latest.${key} else toString version;

      resolvedCmdLineToolsVersion = resolveRepoVersion "cmdline-tools" cmdLineToolsVersion;
      resolvedEmulatorVersion = resolveRepoVersion "emulator" emulatorVersion;
      resolvedPlatformVersions = lib.unique (map (resolveRepoVersion "platforms") platformVersions);
      resolvedBuildToolsVersions = lib.unique (
        map (resolveRepoVersion "build-tools") ([ buildToolsVersion ] ++ extraBuildToolsVersions)
      );
      resolvedNdkVersion = resolveRepoVersion "ndk" ndkVersion;
      sourcePlatformsAvailable = builtins.attrNames (repo.packages.sources or { });
      missingSourcePlatforms = builtins.filter (
        platformVersion: !(builtins.elem platformVersion sourcePlatformsAvailable)
      ) resolvedPlatformVersions;
      effectiveIncludeSources = includeSources && missingSourcePlatforms == [ ];
      effectiveIncludeSystemImages =
        if includeSystemImages != null then includeSystemImages else systemImageTypes != [ ];

      customEmulatorVersions = [
        "36.5.10"
        "36.6.3"
      ];
      useCustomEmulator = includeEmulator && builtins.elem resolvedEmulatorVersion customEmulatorVersions;

      sdkArgs = {
        inherit
          cmdLineToolsVersion
          includeExtras
          repoJson
          repoXmls
          ;

        platformVersions = resolvedPlatformVersions;
        buildToolsVersions = resolvedBuildToolsVersions;
        ndkVersion = resolvedNdkVersion;
        abiVersions = [ abiVersion ];

        includeSystemImages = effectiveIncludeSystemImages;
        inherit systemImageTypes;
        includeSources = effectiveIncludeSources;

        includeEmulator =
          if useCustomEmulator then false else if includeEmulator then "if-supported" else false;
        emulatorVersion = emulatorVersion;
        includeNDK = if includeNdk then "if-supported" else false;

        extraLicenses = [
          "android-sdk-preview-license"
          "android-googletv-license"
          "android-sdk-arm-dbt-license"
          "google-gdk-license"
          "intel-android-extra-license"
          "intel-android-sysimage-license"
          "mips-android-sysimage-license"
        ];
      };

      androidComposition = pkgs.androidenv.composeAndroidPackages sdkArgs;
      platformTools = androidComposition.platform-tools;
      customEmulatorPackageInfo = lib.attrByPath [ "packages" "emulator" resolvedEmulatorVersion ] null repo;
      customEmulatorArchives =
        if customEmulatorPackageInfo == null then
          [ ]
        else
          builtins.filter (
            archive:
            let
              isTargetOs = if builtins.hasAttr "os" archive then archive.os == repoOs || archive.os == "all" else true;
              isTargetArch =
                if builtins.hasAttr "arch" archive then archive.arch == repoArch || archive.arch == "all" else true;
            in
            isTargetOs && isTargetArch
          ) customEmulatorPackageInfo.archives;
      fetchedCustomEmulatorPackage =
        if !useCustomEmulator then
          null
        else if customEmulatorPackageInfo == null then
          throw "Android emulator ${resolvedEmulatorVersion} is missing from repo metadata."
        else if customEmulatorArchives == [ ] then
          throw "Android emulator ${resolvedEmulatorVersion} has no archive for ${repoOs}/${repoArch}."
        else
          customEmulatorPackageInfo
          // {
            archives = map (
              archive:
              pkgs.fetchurl {
                name = builtins.baseNameOf archive.url;
                url = archive.url;
                sha1 = archive.sha1;
              }
            ) customEmulatorArchives;
          };
      customEmulator =
        if !useCustomEmulator then
          null
        else
          (
            pkgs.callPackage (pkgs.path + "/pkgs/development/mobile/androidenv/emulator.nix") {
              deployAndroidPackage = androidComposition.deployAndroidPackage;
              package = fetchedCustomEmulatorPackage;
              os = repoOs;
              arch = repoArch;
              postInstall = "";
              meta = pkgs.androidenv.meta;
            }
          ).overrideAttrs
            (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.libgbm ];
              patchInstructions =
                (old.patchInstructions or "")
                + ''
                  addAutoPatchelfSearchPath ${pkgs.libgbm}/lib
                '';
            });
      androidSdk = androidComposition.androidsdk;
      sdkDir = "${androidSdk}/libexec/android-sdk";
      jdk = pkgs.jetbrains.jdk-21;

      runtimeSdkLayoutVersion = "3";
      runtimeAndroidSdk =
        if customEmulator == null then
          sdkDir
        else
          pkgs.runCommandLocal
            "android-sdk-runtime-${sanitizeName resolvedEmulatorVersion}-${sanitizeName resolvedCmdLineToolsVersion}-v${runtimeSdkLayoutVersion}"
            { }
            ''
              mkdir -p "$out"

              for sdkEntry in ${androidSdk}/libexec/android-sdk/*; do
                  sdkEntryBase="$(basename "$sdkEntry")"
                  case "$sdkEntryBase" in
                      cmdline-tools|emulator) ;;
                      *) ln -s "$sdkEntry" "$out/$sdkEntryBase" ;;
                  esac
              done

              mkdir -p "$out/cmdline-tools"
              cp -r ${androidSdk}/libexec/android-sdk/cmdline-tools/${resolvedCmdLineToolsVersion} "$out/cmdline-tools/"
              cp -rs ${customEmulator}/libexec/android-sdk/emulator "$out"/emulator
            '';

      wrappedAndroidTools = pkgs.runCommandLocal
        "android-tools-${sanitizeName resolvedEmulatorVersion}-${sanitizeName resolvedCmdLineToolsVersion}-v${runtimeSdkLayoutVersion}"
        { }
        ''
          mkdir -p "$out/bin"
          cat > "$out/bin/avdmanager" <<'EOF'
          #!${pkgs.runtimeShell}
          exec ${runtimeAndroidSdk}/cmdline-tools/${resolvedCmdLineToolsVersion}/bin/.avdmanager-wrapped "$@"
          EOF
          cat > "$out/bin/sdkmanager" <<'EOF'
          #!${pkgs.runtimeShell}
          exec ${runtimeAndroidSdk}/cmdline-tools/${resolvedCmdLineToolsVersion}/bin/.sdkmanager-wrapped "$@"
          EOF
          ${lib.optionalString includeEmulator ''ln -s ${runtimeAndroidSdk}/emulator/emulator "$out/bin/emulator-nix"''}
          chmod +x "$out/bin/avdmanager" "$out/bin/sdkmanager"
        '';

      androidImageCatalogJson = pkgs.writeText "android-image-catalog.json" (
        builtins.toJSON (
          lib.flatten (
            lib.mapAttrsToList (
              platformVersion: imageTypes:
              lib.flatten (
                lib.mapAttrsToList (
                  imageType: abis:
                  lib.mapAttrsToList (
                    abi: image:
                    {
                      platform = platformVersion;
                      type = imageType;
                      abi = abi;
                      displayName = image.displayName or "${platformVersion}/${imageType}/${abi}";
                      path = image.path;
                      revision = image.revision;
                    }
                  ) abis
                ) imageTypes
              )
            ) repo.images
          )
        )
      );

      androidListImages = pkgs.writeShellApplication {
        name = "android-list-images";
        runtimeInputs = [ pkgs.jq ];
        text = ''
          jq -r '
            sort_by(.platform, .type, .abi)[] |
            "\(.platform)\t\(.type)\t\(.abi)\t\(.path)"
          ' ${androidImageCatalogJson}
        '';
      };

      renameEmulatorModel = pkgs.writeShellApplication {
        name = "rename-emulator-model";
        runtimeInputs = [
          pkgs.ruby
          pkgs.util-linux
          pkgs.e2fsprogs
          pkgs.android-tools
        ];
        text = ''
          exec ruby ${../../scripts/rename-emulator-model.rb} "$@"
        '';
      };

      localProp = ''
        mkdir -p "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME"
        cat > local.properties <<EOF
        ## This file must *NOT* be checked into Version Control Systems,
        # as it contains information specific to your local configuration.
        #
        # Location of the SDK. This is only used by Gradle.
        sdk.dir=$ANDROID_SDK_ROOT
        EOF
      '';
    in
    rec {
      inherit
        abiVersion
        androidComposition
        androidImageCatalogJson
        androidListImages
        androidSdk
        platformTools
        renameEmulatorModel
        resolvedBuildToolsVersions
        missingSourcePlatforms
        resolvedEmulatorVersion
        resolvedPlatformVersions
        runtimeAndroidSdk
        sdkArgs
        sdkDir
        systemImageTypes
        wrappedAndroidTools
        ;

      shell = pkgs.mkShell.override { stdenv = pkgs.gccStdenv; } {
        packages =
          [
            pkgs.cmake
            androidSdk
            platformTools
            pkgs.git-repo
            pkgs.scrcpy
            androidListImages
            renameEmulatorModel
            wrappedAndroidTools
          ]
          ++ lib.optional (customEmulator != null) customEmulator
          ++ extraPackages;

        JAVA_HOME = jdk.home;

        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
          pkgs.fontconfig
          pkgs.cups
          pkgs.libxinerama
          pkgs.libxrandr
          pkgs.file
          pkgs.gtk3
          pkgs.glib
          pkgs.libGL
          pkgs.libx11
        ];

        shellHook = ''
          export QT_QPA_PLATFORM=${if pkgs.stdenv.isLinux then "xcb" else ""}
          export ANDROID_USER_HOME="${androidUserHome}"
          export ANDROID_AVD_HOME="${androidAvdHome}"
          export JAVA_HOME="${jdk.home}"
          export ANDROID_SDK_ROOT="${runtimeAndroidSdk}"
          export ANDROID_HOME="$ANDROID_SDK_ROOT"
          export PATH="$JAVA_HOME/bin:${wrappedAndroidTools}/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/${resolvedCmdLineToolsVersion}/bin:$PATH"
          ${lib.optionalString includeEmulator ''export PATH="$ANDROID_SDK_ROOT/emulator:$PATH"''}
          nvidiaVkIcd=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json
          nvidiaEglVendor=/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json
          if [ -f "$nvidiaVkIcd" ] && [ -f "$nvidiaEglVendor" ]; then
            export VK_ICD_FILENAMES="${"$"}{VK_ICD_FILENAMES:-$nvidiaVkIcd}"
            export __NV_PRIME_RENDER_OFFLOAD="${"$"}{__NV_PRIME_RENDER_OFFLOAD:-1}"
            export __VK_LAYER_NV_optimus="${"$"}{__VK_LAYER_NV_optimus:-NVIDIA_only}"
            export __GLX_VENDOR_LIBRARY_NAME="${"$"}{__GLX_VENDOR_LIBRARY_NAME:-nvidia}"
            export __EGL_VENDOR_LIBRARY_FILENAMES="${"$"}{__EGL_VENDOR_LIBRARY_FILENAMES:-$nvidiaEglVendor}"
            export LD_LIBRARY_PATH="/run/opengl-driver/lib:${"$"}LD_LIBRARY_PATH"
          fi
          export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=${sdkDir}/build-tools/${lib.head resolvedBuildToolsVersions}/aapt2"
          export DIRENV_LOG_FORMAT=""
          ${localProp}
          echo "Android SDK: ${runtimeAndroidSdk}"
          echo "Platforms: ${lib.concatStringsSep ", " resolvedPlatformVersions}"
          ${lib.optionalString effectiveIncludeSystemImages ''echo "System image types: ${lib.concatStringsSep ", " systemImageTypes} (${abiVersion})"''}
          ${lib.optionalString includeEmulator ''echo "Emulator binary: $(command -v emulator)"''}
          ${lib.optionalString includeEmulator ''echo "Nix emulator binary: $(command -v emulator-nix)"''}
          echo "Installed Android packages:"
          sdkmanager --list_installed
          ${lib.optionalString (includeSources && !effectiveIncludeSources) ''echo "Sources disabled: no sources package for ${lib.concatStringsSep ", " missingSourcePlatforms}"''}
        '';
      };
    };
}
