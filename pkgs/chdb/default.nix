# chDB: ClickHouse as a library that runs inside your process. This is libchdb, the shared
# library with its C header, as chdb-io/chdb-core publishes it for a release. It is a
# prebuilt binary, pinned by hash (pin.json, written by scripts/update-chdb.sh), because
# building it means building ClickHouse. The upstream signs and attests nothing: the hash is
# the one the release's SHA256SUMS lists, which is all that is known about the file.
{
  lib,
  stdenv,
  fetchurl,
  patchelf,
}:

let
  pin = lib.importJSON ./pin.json;
  inherit (stdenv.hostPlatform) system;
  file = pin.systems.${system}.libchdb or (throw "chDB ${pin.version} has no libchdb for ${system}");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "chdb";
  inherit (pin) version;

  src = fetchurl { inherit (file) url hash; };
  # libchdb.so, chdb.h and chdb.hpp, with no directory around them
  sourceRoot = ".";

  nativeBuildInputs = [ patchelf ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -D -m755 libchdb.so $out/lib/libchdb.so
    install -D -m644 chdb.h chdb.hpp -t $out/include

    mkdir -p $out/lib/pkgconfig
    cat > $out/lib/pkgconfig/chdb.pc <<EOF
    prefix=$out
    Name: chdb
    Description: ClickHouse as a library in your process
    Version: ${finalAttrs.version}
    Libs: -L$out/lib -lchdb
    Cflags: -I$out/include
    EOF

    runHook postInstall
  '';

  # The library has a RUNPATH into the directory it was built in on the upstream's runner,
  # and needs nothing but libc, which the program that loads it provides.
  postFixup = ''
    patchelf --remove-rpath $out/lib/libchdb.so
  '';

  # one file of more than 500 MB that the upstream has already stripped
  dontStrip = true;

  passthru = {
    # The Python module comes with an engine of its own, the same release, as a wheel:
    # `chdb.pythonModule python3Packages`.
    pythonModule = pythonPackages: pythonPackages.callPackage ./python.nix { };
  };

  meta = {
    description = "ClickHouse as a library in your process (prebuilt libchdb)";
    homepage = "https://github.com/chdb-io/chdb-core";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames pin.systems;
  };
})
