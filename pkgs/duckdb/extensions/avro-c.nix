# DuckDB's fork of avro-c, which the avro extension before 2.0 expects to find as a
# library. vcpkg builds it, from the revision that the port in DuckDB's registry
# names; the extension calls functions that the fork adds (writing with metadata,
# writing to memory at an offset), so nixpkgs' avro-c will not do.
{
  lib,
  stdenv,
  cmake,
  jansson,
  snappy,
  xz,
  zlib,
  src,
}:

stdenv.mkDerivation {
  pname = "duckdb-avro-c";
  version = "1.11.3";
  inherit src;
  sourceRoot = "${src.name}/lang/c";

  # its CMake runs version.sh, which expects /bin/bash
  postPatch = "patchShebangs version.sh";

  nativeBuildInputs = [ cmake ];
  buildInputs = [
    jansson
    snappy
    xz
    zlib
  ];

  cmakeFlags = [
    (lib.cmakeBool "BUILD_EXAMPLES" false)
    (lib.cmakeBool "BUILD_TESTS" false)
    (lib.cmakeBool "BUILD_DOCS" false)
    # its CMake predates version 3.5, which CMake no longer accepts
    (lib.cmakeFeature "CMAKE_POLICY_VERSION_MINIMUM" "3.5")
    # it predates C23, which newer compilers default to
    (lib.cmakeFeature "CMAKE_C_STANDARD" "17")
    (lib.cmakeFeature "CMAKE_C_FLAGS" "-Wno-incompatible-pointer-types")
  ];

  meta = {
    description = "DuckDB's fork of Apache Avro's C library";
    homepage = "https://github.com/duckdb/duckdb-avro-c";
    license = lib.licenses.asl20;
  };
}
