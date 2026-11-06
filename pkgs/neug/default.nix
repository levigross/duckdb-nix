# NeuG, the embedded graph database of Alibaba's GraphScope team, built from source: libneug
# with its headers and CMake package, the extensions that `LOAD` finds by name, and the
# addon for Node.js.
#
# The build wants a git checkout. Its sources come with every submodule (the fetcher takes
# the nested ones too), but this tree has no .git, so what the build does with `git apply`
# does nothing, and it is done here instead (postPatch). Nothing is fetched at build time.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  cmake,
  ninja,
  pkg-config,
  patch,
  tcl,
  nodejs,
  patchelf,
  openssl,
  zlib,
  zstd,
  lz4,
  curl,
  # the libraries behind vector_search, built on their own (pkgs/zvec)
  zvec,
  # The extensions to build, all of those NeuG has. They are shared libraries, loaded by
  # name with LOAD: NeuG has no way to link them in.
  extensions ? [
    "parquet"
    "pattern_matching"
    "gds"
    "httpfs"
    "fts"
    "vector_search"
  ],
}:

let
  pin = lib.importJSON ./pin.json;

  src = fetchFromGitHub {
    owner = "alibaba";
    repo = "neug";
    inherit (pin) rev hash;
    fetchSubmodules = true;
  };

  # The directory of the addon for Node.js that the loader (lib/binding.js) looks in:
  # build/Release/<os>_<arch>/neug_node_bind.node
  nodePlatform =
    {
      x86_64-linux = "linux_x86_64";
      aarch64-linux = "linux_arm64";
    }
    .${stdenv.hostPlatform.system};

  # the headers of the addon API, which the addon is built against; the build script of the
  # package would have npm fetch them
  nodeAddonApi = fetchurl { inherit (pin.nodeAddonApi) url hash; };

in
stdenv.mkDerivation {
  pname = "neug";
  inherit (pin) version;
  inherit src;

  # The addon for Node.js is a target of the same build as the library (it links its targets,
  # which no other build has), so it is an output of this one: the package neug-nodejs.
  outputs = [
    "out"
    "nodejs"
  ];

  postPatch = ''
    # Patches of the submodules, which the build applies with `git apply` in a checkout
    patch -p1 -d third_party/abseil-cpp -i ../abseil-cpp.patch
    patch -p1 -d third_party/protobuf -i ../protobuf.patch
    patch -p1 -d third_party/gflags -i ../gflags.patch
    patch -p1 -d third_party/leveldb -i ../leveldb.patch
    patch -p1 -d third_party/brpc -i ../brpc_cmake.patch

    # scripts that the build runs, which name /usr/bin/env
    patchShebangs third_party/brpc

    # brpc defines __STRICT_ANSI__ itself, and nothing of brpc looks at it. Together with GNU
    # mode that makes libstdc++ of GCC 16 define its __int128 traits twice.
    substituteInPlace third_party/brpc/CMakeLists.txt --replace-fail ' -D__STRICT_ANSI__"' '"'

    # the vendored yaml-cpp uses uint16_t without including <cstdint>, which GCC 15 no longer
    # lets pass
    sed -i '1i #include <cstdint>' third_party/yaml-cpp/src/emitterutils.cpp

    # The directory LOAD looks in is built into the library, as the output directory of the
    # build, which is gone once it is installed. NEUG_EXTENSION_HOME says where it is instead.
    substituteInPlace CMakeLists.txt --replace-fail \
      'if(DEFINED CMAKE_LIBRARY_OUTPUT_DIRECTORY AND CMAKE_LIBRARY_OUTPUT_DIRECTORY)' \
      'if(NEUG_EXTENSION_HOME)
        add_compile_definitions(NEUG_EXTENSION_HOME_MACRO="''${NEUG_EXTENSION_HOME}")
    elseif(DEFINED CMAKE_LIBRARY_OUTPUT_DIRECTORY AND CMAKE_LIBRARY_OUTPUT_DIRECTORY)'

    # The CMake of the addon for Node.js asks node for the headers of its API, as a package
    # in the node_modules next to it, which npm would put there
    mkdir -p tools/nodejs_bind/node_modules/node-addon-api
    tar -xzf ${nodeAddonApi} --strip-components=1 -C tools/nodejs_bind/node_modules/node-addon-api

    # carquet, which the parquet extension links, compiles its C with -flto=auto. The objects
    # are then only the compiler's intermediate form, the plain `ar` makes no index of the
    # symbols in them, and the linker extracts nothing from the archive: the extension is left
    # with its calls undefined and does not load. Debian's ar loads the plugin by itself.
    substituteInPlace third_party/carquet/CMakeLists.txt --replace-fail ' -flto=auto' ""

    # The headers of NeuG branch on these, and the library is built with them: a program
    # without them disagrees with the library about the layout of its types. The CMake package
    # exports the definitions of rapidjson only.
    substituteInPlace neug-config.in.cmake --replace-fail \
      'add_definitions(-DRAPIDJSON_HAS_CXX11_RANGE_FOR=1)' \
      'add_definitions(-DRAPIDJSON_HAS_CXX11_RANGE_FOR=1)
    add_definitions(-DNEUG_WITH_MIMALLOC -DENABLE_CHRONO_YMD -DNDEBUG)'
  ''
  + lib.optionalString (lib.elem "vector_search" extensions) ''

    # The extension is compiled against the headers of the zvec in NeuG's tree, and linked with
    # the libraries of the package zvec: they must be of the same commit
    diff -r ${zvec.src}/src/include third_party/zvec/src/include

    # zvec is built already (the package zvec): where the build would make it as an external
    # project, NEUG_ZVEC_PREBUILT names the directory with its libraries
    substituteInPlace cmake/BuildZVecAsThirdParty.cmake \
      --replace-fail \
        'set(_zvec_binary_dir "''${CMAKE_BINARY_DIR}/third_party/zvec-build")' \
        'set(_zvec_binary_dir "''${CMAKE_BINARY_DIR}/third_party/zvec-build")
        if(NEUG_ZVEC_PREBUILT)
            set(_zvec_binary_dir "''${NEUG_ZVEC_PREBUILT}")
        endif()' \
      --replace-fail \
        '"''${_zvec_binary_dir}/external/usr/local/lib/libroaring.a")' \
        '"''${_zvec_binary_dir}/external/usr/local/lib/libroaring.a")
        if(NEUG_ZVEC_PREBUILT)
            set(_zvec_roaring_library "''${NEUG_ZVEC_PREBUILT}/lib/libroaring.a")
        endif()' \
      --replace-fail \
        '    ExternalProject_Add(zvec_external' \
        '    if(NEUG_ZVEC_PREBUILT)
            add_custom_target(zvec_external)
        else()
        ExternalProject_Add(zvec_external' \
      --replace-fail \
        'CMAKE_ARGS ''${_zvec_cmake_args})' \
        'CMAKE_ARGS ''${_zvec_cmake_args})
        endif()'
  '';

  strictDeps = true;
  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    # for the patches that the build applies itself, with `patch` when it is not in git
    patch
    # SQLite's amalgamation, for the fts extension
    tcl
    # the addon for Node.js asks node where the headers are
    nodejs
    patchelf
  ];
  buildInputs = [
    zstd
    lz4
    curl
  ];

  # what the CMake package of NeuG looks for in a program that uses it (find_dependency)
  propagatedBuildInputs = [
    openssl
    zlib
  ];

  cmakeFlags = [
    (lib.cmakeBool "BUILD_PYTHON" false)
    (lib.cmakeBool "BUILD_NODEJS" true)
    (lib.cmakeFeature "NODE_INCLUDE_DIR" "${nodejs}/include/node")
    (lib.cmakeBool "BUILD_TEST" false)
    (lib.cmakeBool "BUILD_EXAMPLES" false)
    (lib.cmakeBool "BUILD_EXECUTABLES" false)
    # the server of the service mode
    (lib.cmakeBool "BUILD_HTTP_SERVER" true)
    (lib.cmakeBool "ENABLE_BACKTRACES" false)
    (lib.cmakeBool "NEUG_PACKAGE_BUILD" false)
    (lib.cmakeBool "NEUG_NATIVE_ARCH" false)
    # the submodules ask for CMake versions that CMake 4 no longer accepts
    (lib.cmakeFeature "CMAKE_POLICY_VERSION_MINIMUM" "3.5")
    # relative, as the vendored libraries (brpc) join them to the prefix, and nixpkgs gives
    # absolute ones
    (lib.cmakeFeature "CMAKE_INSTALL_LIBDIR" "lib")
    (lib.cmakeFeature "CMAKE_INSTALL_INCLUDEDIR" "include")
    (lib.cmakeFeature "BUILD_EXTENSIONS" (lib.concatStringsSep ";" extensions))
    (lib.cmakeFeature "NEUG_EXTENSION_HOME" "${placeholder "out"}/lib")
  ]
  ++ lib.optional (lib.elem "vector_search" extensions) (
    lib.cmakeFeature "NEUG_ZVEC_PREBUILT" "${zvec}"
  );

  # Extensions have no install rule. They are put where LOAD looks:
  # <home>/extension/<name>/lib<name>.neug_extension
  postInstall = ''
    for file in $(find extension -name '*.neug_extension'); do
      install -D -m755 "$file" "$out/lib/extension/$(basename "$(dirname "$file")")/$(basename "$file")"
    done

    # The addon for Node.js has no install rule either. It goes in the layout that the loader
    # of the package expects: lib/*.js, and build/Release/<os>_<arch>/neug_node_bind.node.
    # It links libneug.so, which is in $out. Its RPATH is that of the build directory, which is
    # gone, so it is replaced.
    package=$nodejs/lib/node_modules/neug
    install -D -m644 ../tools/nodejs_bind/package.json $package/package.json
    mkdir -p $package/lib
    cp -r ../tools/nodejs_bind/lib/. $package/lib/
    addon=$package/build/Release/${nodePlatform}/neug_node_bind.node
    install -D -m755 "$(find tools/nodejs_bind -name neug_node_bind.node)" $addon
    patchelf --set-rpath "$out/lib:${
      lib.makeLibraryPath [
        openssl
        stdenv.cc.cc.lib
      ]
    }" $addon
  '';

  passthru = {
    inherit extensions zvec;
    # where LOAD looks, without INSTALL and without a network
    extensionHome = "${placeholder "out"}/lib";
  };

  meta = {
    description = "NeuG, an embedded graph database, with its extensions";
    homepage = "https://github.com/alibaba/neug";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
