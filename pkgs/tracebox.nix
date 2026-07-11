{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
stdenv.mkDerivation rec {
  pname = "tracebox";
  version = "57.2";

  src = fetchurl {
    url = "https://commondatastorage.googleapis.com/perfetto-luci-artifacts/v${version}/linux-amd64/tracebox";
    sha256 = "af22b25abb57260eb22bd4dc5bd64ea25d88fd781c1c221f446d0d49eaff59e8";
  };

  dontUnpack = true;
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  installPhase = ''
    install -Dm755 $src $out/bin/tracebox
  '';

  meta = {
    description = "Perfetto tracebox: all-in-one tracing binary (traced, perfetto, websocket_bridge, ...)";
    homepage = "https://perfetto.dev/docs/";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
