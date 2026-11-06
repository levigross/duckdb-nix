# A C interface to NeuG, which has only a C++ one (bindings/neug-c): libneug_c.so, built against
# the installed NeuG the way any program is, through its CMake package. It exports the functions
# of neug_c.h and nothing else; the protobuf, abseil and glog that the headers of NeuG are made
# of are linked into it as static archives and hidden. The Rust crates are made on it.
{
  lib,
  stdenv,
  cmake,
  ninja,
  neug,
}:

stdenv.mkDerivation {
  pname = "neug-c";
  # the version of NeuG it is built against; the version of the interface is NEUG_C_ABI_VERSION
  inherit (neug) version;

  src = ../../bindings/neug-c;

  strictDeps = true;
  nativeBuildInputs = [
    cmake
    ninja
  ];
  buildInputs = [ neug ];

  meta = {
    description = "A C interface to NeuG, the embedded graph database";
    homepage = "https://github.com/alibaba/neug";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
