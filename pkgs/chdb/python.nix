# The Python module of chDB, from the two wheels the upstream publishes: chdb-core, which
# holds the engine (a 550 MB extension module, built for every Python from 3.9 on), and
# chdb, the Python part that depends on it. Both install into the one directory `chdb`,
# and both ship its __init__.py. pip installs chdb-core first and chdb over it, so that is
# the order here. Prebuilt binaries, pinned by hash (pin.json, scripts/update-chdb.sh).
{
  lib,
  stdenv,
  buildPythonPackage,
  fetchurl,
  unzip,
  python,
  pandas,
  pyarrow,
}:

let
  pin = lib.importJSON ./pin.json;
  inherit (stdenv.hostPlatform) system;
  engine =
    pin.systems.${system}.coreWheel or (throw "chDB ${pin.version} has no wheel for ${system}");
  coreWheel = fetchurl { inherit (engine) url hash; };
  wrapperWheel = fetchurl { inherit (pin.wrapper.wheel) url hash; };
in
buildPythonPackage {
  pname = "chdb";
  inherit (pin.wrapper) version;
  format = "other";

  dontUnpack = true;
  nativeBuildInputs = [ unzip ];

  installPhase = ''
    runHook preInstall
    site=$out/${python.sitePackages}
    mkdir -p $site
    unzip -q ${coreWheel} -d $site
    unzip -q -o ${wrapperWheel} -d $site
    runHook postInstall
  '';

  dependencies = [
    pandas
    pyarrow
  ];

  # The extension modules find each other and the library they bundle by $ORIGIN, and need
  # nothing but libc. Stripping a file of 550 MB would only take time.
  dontStrip = true;

  pythonImportsCheck = [ "chdb" ];

  passthru = {
    engineVersion = pin.version;
  };

  meta = {
    description = "ClickHouse in your Python process (chdb and chdb-core, prebuilt)";
    homepage = "https://github.com/chdb-io/chdb";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames pin.systems;
  };
}
