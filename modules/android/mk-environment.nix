{
  pkgs,
  lib,
  defaultRepoJson,
}:
let
  defaultAbiVersion =
    if pkgs.stdenv.hostPlatform.isAarch64 then "arm64-v8a" else "x86_64";
in
{
  inherit defaultAbiVersion;

  mkAndroidEnvironment =
    {
      sdk ? { },
      emulator ? { },
      ndk ? { },
      cmake ? { },
      includeSources ? true,
      extraPackages ? [ ],
      includeExtras ? [ ],
      repoJson ? defaultRepoJson,
      repoXmls ? null,
      androidUserHome ? "$HOME/.android",
      androidAvdHome ? "$HOME/.android/avd",
      # JDK used for JAVA_HOME / the dev shell. Override from consumers, e.g.
      # `jdk = pkgs.jdk17;` (kapt-based builds require JDK 17 — JDK 21 breaks it).
      jdk ? pkgs.jetbrains.jdk-21,
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

      requirePin =
        component: enabled: value:
        if enabled && value == null then
          throw "Android ${component} is enabled but no version is pinned. Set the version explicitly (run `android-list-versions ${component}` to see the options), or disable it."
        else
          value;

      # Nesting the arguments loses Nix's own "unexpected argument" check, so
      # reinstate it per group — a typo must fail rather than silently default.
      checkKeys =
        groupName: known: group:
        let
          unknown = builtins.filter (key: !(builtins.elem key known)) (builtins.attrNames group);
        in
        if unknown == [ ] then
          group
        else
          throw "Unknown ${groupName} option${lib.optionalString (builtins.length unknown > 1) "s"}: ${lib.concatStringsSep ", " unknown}. Known options: ${lib.concatStringsSep ", " known}.";

      sdkOpts = checkKeys "sdk" [
        "platformVersions"
        "buildToolsVersions"
        "cmdLineToolsVersion"
      ] sdk;
      emulatorOpts = checkKeys "emulator" [
        "version"
        "enable"
        "platformVersions"
        "images"
        "systemImageTypes"
        "includeSystemImages"
        "abiVersions"
        "contentAddressedSystemImages"
      ] emulator;
      ndkOpts = checkKeys "ndk" [
        "versions"
        "enable"
      ] ndk;
      cmakeOpts = checkKeys "cmake" [
        "versions"
        "enable"
      ] cmake;

      platformVersions = sdkOpts.platformVersions or [ ];
      # First entry is the one Gradle's aapt2 override points at.
      buildToolsVersions = sdkOpts.buildToolsVersions or [ ];
      cmdLineToolsVersion =
        sdkOpts.cmdLineToolsVersion
          or (throw "sdk.cmdLineToolsVersion is required — it provides sdkmanager/avdmanager. Run `android-list-versions cmdline-tools` to see the options.");

      emulatorVersion = emulatorOpts.version or null;
      includeEmulator = emulatorOpts.enable or (emulatorVersion != null);
      # Each platform x type combination is multiple GB, so `images` maps a
      # platform to exactly the types wanted for it:
      #
      #   images = { "36" = [ "google_apis" ]; "33" = [ "android-automotive" ]; };
      #
      # `platformVersions` + `systemImageTypes` is the coarser shorthand: it
      # gives every listed platform the same set of types.
      emulatorPlatformVersions = emulatorOpts.platformVersions or platformVersions;
      systemImageTypes = emulatorOpts.systemImageTypes or [ ];
      imagesFromLists = lib.genAttrs (map toString emulatorPlatformVersions) (_: systemImageTypes);
      # Upstream silently skips platform/type pairs it has no archive for, which
      # turns a typo or an unavailable combination into a missing image rather
      # than an error. An explicit `images` request is checked against the
      # catalog; the shorthand is not, since crossing lists is expected to hit
      # combinations that do not exist.
      checkImageAvailable =
        platform: types:
        let
          available = builtins.attrNames (repo.images.${platform} or { });
          missing = builtins.filter (type: !(builtins.elem type available)) types;
        in
        if available == [ ] then
          throw "No system images for platform ${platform}. Run `android-list-images` to see what is available."
        else if missing != [ ] then
          throw "No ${lib.concatStringsSep ", " missing} system image for platform ${platform}. Available for ${platform}: ${lib.concatStringsSep ", " available}."
        else
          types;
      requestedImages = lib.filterAttrs (_: types: types != [ ]) (
        if emulatorOpts ? images then
          lib.mapAttrs (platform: types: checkImageAvailable platform (lib.toList types)) emulatorOpts.images
        else
          imagesFromLists
      );
      includeSystemImages = emulatorOpts.includeSystemImages or null;
      # First entry is the primary ABI reported in the shell banner.
      abiVersions = emulatorOpts.abiVersions or [ defaultAbiVersion ];
      contentAddressedSystemImages = emulatorOpts.contentAddressedSystemImages or false;

      ndkVersions = ndkOpts.versions or [ ];
      includeNdk = ndkOpts.enable or (ndkVersions != [ ]);
      cmakeVersions = cmakeOpts.versions or [ ];
      includeCmake = cmakeOpts.enable or (cmakeVersions != [ ]);

      resolvedCmdLineToolsVersion = toString cmdLineToolsVersion;
      resolvedEmulatorVersion = requirePin "emulator" includeEmulator (
        if emulatorVersion == null then null else toString emulatorVersion
      );
      resolvedPlatformVersions = lib.unique (map toString platformVersions);
      resolvedEmulatorPlatformVersions = builtins.attrNames requestedImages;
      # Platforms that only exist to carry a system image still need their
      # platform package present for avdmanager to resolve the target.
      allPlatformVersions = lib.unique (resolvedPlatformVersions ++ resolvedEmulatorPlatformVersions);
      resolvedBuildToolsVersions = lib.unique (map toString buildToolsVersions);
      resolvedAbiVersions = lib.unique (map toString abiVersions);
      resolvedNdkVersions = requirePin "ndk" includeNdk (
        if includeNdk && ndkVersions == [ ] then null else lib.unique (map toString ndkVersions)
      );
      resolvedNdkVersion = if resolvedNdkVersions == [ ] then null else lib.head resolvedNdkVersions;
      resolvedCmakeVersions = requirePin "cmake" includeCmake (
        if includeCmake && cmakeVersions == [ ] then null else lib.unique (map toString cmakeVersions)
      );
      sourcePlatformsAvailable = builtins.attrNames (repo.packages.sources or { });
      missingSourcePlatforms = builtins.filter (
        platformVersion: !(builtins.elem platformVersion sourcePlatformsAvailable)
      ) resolvedPlatformVersions;
      availableSourcePlatforms = builtins.filter (
        platformVersion: builtins.elem platformVersion sourcePlatformsAvailable
      ) resolvedPlatformVersions;
      effectiveIncludeSources = includeSources && missingSourcePlatforms == [ ];
      effectiveIncludeSystemImages =
        if includeSystemImages != null then includeSystemImages else requestedImages != { };

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

        platformVersions = allPlatformVersions;
        buildToolsVersions = resolvedBuildToolsVersions;
        ndkVersion = resolvedNdkVersion;
        ndkVersions = resolvedNdkVersions;
        cmakeVersions = if includeCmake then resolvedCmakeVersions else [ ];
        abiVersions = resolvedAbiVersions;

        # Images come from imageComposition below, which crosses only
        # resolvedEmulatorPlatformVersions with systemImageTypes.
        includeSystemImages = false;
        systemImageTypes = [ ];
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

      # composeAndroidPackages only crosses one platform list with one type list,
      # so build a composition per distinct type-set and merge the results. That
      # is what lets `images` request different types per platform. Everything
      # unrelated is switched off, so these only add system-images derivations.
      imageCompositions = map (
        typeSet:
        pkgs.androidenv.composeAndroidPackages (
          sdkArgs
          // {
            platformVersions = lib.attrNames (
              lib.filterAttrs (_: types: types == typeSet) requestedImages
            );
            includeSystemImages = true;
            systemImageTypes = typeSet;
            buildToolsVersions = [ ];
            cmakeVersions = [ ];
            ndkVersions = [ ];
            includeSources = false;
            includeEmulator = false;
            includeNDK = false;
            includeExtras = [ ];
          }
        )
      ) (lib.unique (lib.attrValues requestedImages));

      systemImages = pkgs.runCommandLocal "android-system-images" { } ''
        mkdir -p "$out"
        ${lib.concatMapStrings (composition: ''
          for platformDir in ${composition.androidsdk}/libexec/android-sdk/system-images/*; do
            platformBase="$(basename "$platformDir")"
            mkdir -p "$out/$platformBase"
            for typeDir in "$platformDir"/*; do
              ln -sfn "$typeDir" "$out/$platformBase/$(basename "$typeDir")"
            done
          done
        '') imageCompositions}
      '';
      systemImagesDir = "${systemImages}";

      platformTools = androidComposition.platform-tools;
      compatibleArchives = builtins.filter (
        archive:
        let
          isTargetOs = if builtins.hasAttr "os" archive then archive.os == repoOs || archive.os == "all" else true;
          isTargetArch =
            if builtins.hasAttr "arch" archive then archive.arch == repoArch || archive.arch == "all" else true;
        in
        isTargetOs && isTargetArch
      );
      extraSourcesPackages =
        if !includeSources || effectiveIncludeSources then
          [ ]
        else
          map (
            platformVersion:
            let
              package = repo.packages.sources.${platformVersion};
            in
            androidComposition.deployAndroidPackage {
              package = package // {
                archives = map (
                  archive:
                  pkgs.fetchurl {
                    name = builtins.baseNameOf archive.url;
                    url = archive.url;
                    sha1 = archive.sha1;
                  }
                ) (compatibleArchives package.archives);
              };
            }
          ) availableSourcePlatforms;
      customEmulatorPackageInfo =
        if resolvedEmulatorVersion == null then
          null
        else
          lib.attrByPath [ "packages" "emulator" resolvedEmulatorVersion ] null repo;
      customEmulatorArchives =
        if customEmulatorPackageInfo == null then
          [ ]
        else
          compatibleArchives customEmulatorPackageInfo.archives;
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

      useCaSystemImages = contentAddressedSystemImages && effectiveIncludeSystemImages;

      caSystemImages = pkgs.runCommand "android-system-images-ca" {
        __contentAddressed = true;
        outputHashAlgo = "sha256";
        outputHashMode = "recursive";
      } ''cp -rL --reflink=auto ${systemImagesDir} "$out"'';

      runtimeAndroidSdk =
        if customEmulator == null && !effectiveIncludeSystemImages && extraSourcesPackages == [ ] then
          sdkDir
        else
          pkgs.runCommandLocal
            "android-sdk"
            { }
            ''
              mkdir -p "$out"

              for sdkEntry in ${androidSdk}/libexec/android-sdk/*; do
                  sdkEntryBase="$(basename "$sdkEntry")"
                  case "$sdkEntryBase" in
                      cmdline-tools) ;;
                      ${lib.optionalString (customEmulator != null) "emulator) ;;"}
                      ${lib.optionalString useCaSystemImages "system-images) ;;"}
                      *) ln -s "$sdkEntry" "$out/$sdkEntryBase" ;;
                  esac
              done

              ${lib.optionalString (effectiveIncludeSystemImages && useCaSystemImages) ''ln -s ${caSystemImages} "$out/system-images"''}
              ${lib.optionalString (effectiveIncludeSystemImages && !useCaSystemImages) ''ln -s ${systemImagesDir} "$out/system-images"''}

              ${lib.optionalString (extraSourcesPackages != [ ]) ''
                mkdir -p "$out/sources"
                ${lib.concatMapStrings (sourcesPackage: ''
                  for sourcesDir in ${sourcesPackage}/libexec/android-sdk/sources/*; do
                    ln -s "$sourcesDir" "$out/sources/$(basename "$sourcesDir")"
                  done
                '') extraSourcesPackages}
              ''}

              mkdir -p "$out/cmdline-tools"
              cp -r ${androidSdk}/libexec/android-sdk/cmdline-tools/${resolvedCmdLineToolsVersion} "$out/cmdline-tools/"
              ${lib.optionalString (
                customEmulator != null
              ) ''cp -rs ${customEmulator}/libexec/android-sdk/emulator "$out"/emulator''}
            '';

      wrappedAndroidTools = pkgs.runCommandLocal
        "android-tools"
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

      pinnedVersions = {
        build-tools = resolvedBuildToolsVersions;
        cmake = resolvedCmakeVersions;
        cmdline-tools = [ resolvedCmdLineToolsVersion ];
        emulator = lib.optional (resolvedEmulatorVersion != null) resolvedEmulatorVersion;
        ndk = resolvedNdkVersions;
        platforms = resolvedPlatformVersions;
      };

      androidVersionCatalogJson = pkgs.writeText "android-version-catalog.json" (
        builtins.toJSON (
          lib.flatten (
            lib.mapAttrsToList (
              component: versions:
              lib.mapAttrsToList (version: package: {
                inherit component version;
                displayName = package.displayName or "${component} ${version}";
                latest = (repo.latest.${component} or null) == version;
                pinned = builtins.elem version (pinnedVersions.${component} or [ ]);
              }) versions
            ) repo.packages
          )
        )
      );

      androidListVersions = pkgs.writeShellApplication {
        name = "android-list-versions";
        runtimeInputs = [ pkgs.jq ];
        text = ''
          component="''${1:-}"
          jq -r --arg component "$component" '
            def versionKey:
              [ .version | scan("[0-9]+|[a-zA-Z]+") | tonumber? // . ];
            map(select($component == "" or .component == $component)) |
            sort_by(.component, versionKey)[] |
            [ (if .pinned then "pinned" else empty end),
              (if .latest then "upstream-latest" else empty end) ] as $tags |
            "\(.component)\t\(.version)\t\($tags | join(" "))"
          ' ${androidVersionCatalogJson}
        '';
      };

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
          exec ruby -e 'load ARGV.shift' ${../../scripts/rename-emulator-model.rb} "$@"
        '';
      };

      refreshAvds = pkgs.writeShellApplication {
        name = "refresh-avds";
        runtimeInputs = [ pkgs.ruby ];
        text = ''
          exec ruby -e 'load ARGV.shift' ${../../scripts/refresh-avds.rb} "$@"
        '';
      };

      resizeAvd = pkgs.writeShellApplication {
        name = "resize-avd";
        runtimeInputs = [ pkgs.ruby ];
        text = ''
          exec ruby -e 'load ARGV.shift' ${../../scripts/resize-avd.rb} "$@"
        '';
      };

      cloneAvd = pkgs.writeShellApplication {
        name = "clone-avd";
        runtimeInputs = [ pkgs.ruby ];
        text = ''
          exec ruby -e 'load ARGV.shift' ${../../scripts/clone-avd.rb} "$@"
        '';
      };

      avdConfig = pkgs.writeShellApplication {
        name = "avd-config";
        runtimeInputs = [ pkgs.ruby ];
        text = ''
          exec ruby -e 'load ARGV.shift' ${../../scripts/avd-config.rb} "$@"
        '';
      };

      setDisplayPreset = pkgs.writeShellApplication {
        name = "set-display-preset";
        runtimeInputs = [ pkgs.ruby ];
        text = ''
          exec ruby -e 'load ARGV.shift' ${../../scripts/set-display-preset.rb} "$@"
        '';
      };

      tracebox = pkgs.callPackage ../../pkgs/tracebox.nix { };

      perfettoBridge = pkgs.writeShellApplication {
        name = "perfetto-bridge";
        text = ''
          adb start-server
          echo "Bridge for https://ui.perfetto.dev (ws://127.0.0.1:8037/adb); Ctrl-C to stop."
          exec ${tracebox}/bin/tracebox websocket_bridge
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
        resolvedAbiVersions
        androidComposition
        androidImageCatalogJson
        androidListImages
        androidVersionCatalogJson
        androidListVersions
        androidSdk
        platformTools
        renameEmulatorModel
        resolvedBuildToolsVersions
        resolvedCmakeVersions
        missingSourcePlatforms
        resolvedEmulatorVersion
        resolvedPlatformVersions
        runtimeAndroidSdk
        sdkArgs
        sdkDir
        requestedImages
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
            androidListVersions
            renameEmulatorModel
            refreshAvds
            resizeAvd
            cloneAvd
            avdConfig
            setDisplayPreset
            tracebox
            perfettoBridge
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
          ${lib.optionalString (resolvedBuildToolsVersions != [ ]) ''export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=${sdkDir}/build-tools/${lib.head resolvedBuildToolsVersions}/aapt2"''}
          export DIRENV_LOG_FORMAT=""
          ${localProp}
          echo "Android SDK: ${runtimeAndroidSdk}"
          echo "Platforms: ${lib.concatStringsSep ", " resolvedPlatformVersions}"
          ${lib.optionalString effectiveIncludeSystemImages ''echo "System images (${lib.concatStringsSep ", " resolvedAbiVersions}): ${lib.concatStringsSep "; " (lib.mapAttrsToList (platform: types: "${platform} -> ${lib.concatStringsSep ", " types}") requestedImages)}"''}
          ${lib.optionalString includeEmulator ''echo "Emulator binary: $(command -v emulator)"''}
          ${lib.optionalString includeEmulator ''echo "Nix emulator binary: $(command -v emulator-nix)"''}
          echo "Installed Android packages:"
          sdkmanager --list_installed
          ${lib.optionalString includeEmulator ''
            echo "AVD status:"
            refresh-avds || true
          ''}
          ${lib.optionalString (includeSources && !effectiveIncludeSources) ''echo "No sources package for ${lib.concatStringsSep ", " missingSourcePlatforms}${lib.optionalString (availableSourcePlatforms != [ ]) "; installed sources for ${lib.concatStringsSep ", " availableSourcePlatforms}"}"''}
        '';
      };
    };
}
