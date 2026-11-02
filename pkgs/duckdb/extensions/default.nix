{
  lib,
  runCommand,
  fetchFromGitHub,
  fetchurl,
  callPackage,
  python3,
  duckdbSrc,
  duckdbVersion,
  # this DuckDB version's pins and the Cargo.lock files for its Rust extensions
  pins,
  rustLocks,
  duckdbRustPlatform,
  aws-sdk-cpp,
  # older nixpkgs have none; default.nix leaves the extension out then
  azure-sdk-for-cpp ? null,
  bzip2,
  croaring,
  curl,
  expat,
  gdal,
  geos,
  jansson,
  libarchive,
  libpq,
  libxml2,
  mariadb-connector-c,
  miniz,
  minizip-ng,
  openssl,
  proj,
  snappy,
  sqlite,
  # unixODBC was renamed
  unixodbc ? unixODBC,
  unixODBC ? null,
  xz,
  zlib,
  zstd,
}:

let

  fetchPin =
    pin:
    fetchFromGitHub {
      inherit (pin)
        owner
        repo
        rev
        hash
        ;
    };

  # Only the services the extensions use, instead of the whole SDK.
  awsSdk = aws-sdk-cpp.override {
    apis = [
      "cloudformation"
      "core"
      "glue"
      "identity-management"
      "rds"
      "redshift"
      "redshift-serverless"
      "sso"
      "sts"
    ];
  };

  # The Rust part of an extension, built here instead of by cargo inside CMake.
  # It is the unpatched pin, so that its Cargo.lock is the one vendored.
  lanceFfi = callPackage ./lance.nix {
    rustPlatform = duckdbRustPlatform;
    src = fetchPin pins.lance;
    lockFile = rustLocks + "/lance.Cargo.lock";
    replaceLock = lib.versionOlder release "2";
  };
  deltaFfi = callPackage ./delta.nix {
    rustPlatform = duckdbRustPlatform;
    src = fetchPin pins.delta.kernel;
    lockFile = rustLocks + "/delta.Cargo.lock";
    version = lib.removePrefix "v" pins.delta.kernel.rev;
    features = deltaFeatures;
  };
  # what the extension's CMake builds delta-kernel-rs with (it passes --all-features
  # before 2.0), less the second TLS backend and what is for testing
  deltaFeatures =
    if lib.versionAtLeast release "2" then
      [
        "default-engine-rustls"
        "arrow"
        "test-ffi"
        "delta-kernel-unity-catalog"
        "tracing"
      ]
    else if lib.versionAtLeast release "1.5" then
      [
        "default-engine-rustls"
        "catalog-managed"
        "uc-catalog"
        "test-ffi"
        "tracing"
      ]
    else
      [
        "default-engine-rustls"
        "test-ffi"
        "tracing"
      ];
  # the library the avro extension finds before 2.0 (see avro-c.nix)
  avroC = callPackage ./avro-c.nix { src = fetchPin pins.avro.avroC; };
  vortexFfi = callPackage ./vortex.nix {
    rustPlatform = duckdbRustPlatform;
    src = fetchPin pins.vortex;
    lockFile = rustLocks + "/vortex.Cargo.lock";
    inherit duckdbSrc duckdbVersion;
    inherit (pins.vortex) gitHashes;
  };

  release = lib.removePrefix "v" duckdbVersion;

  # the library mysql_scanner asks vcpkg for: the MySQL client until 1.5, MariaDB's from then on
  mysqlPackage = if lib.versionOlder release "1.5" then "libmysql" else "libmariadb";

  # What differs from the definitions below for a DuckDB older than the one they
  # were written for (2.0), which pins older sources.
  versionOverrides =
    lib.optionalAttrs (lib.versionOlder release "2") {
      # Until 2.0 the extension builds the libpq of PostgreSQL itself. It downloads the
      # source, which CMake skips when the file is there and has the hash it expects,
      # and configures it. The link to the system libpq below does not apply.
      postgres_scanner = args: {
        postPatch = ''
          cp ${
            fetchurl {
              url = "https://github.com/postgres/postgres/archive/refs/tags/REL_15_13.tar.gz";
              hash = "sha256-5tAtnakTrppMUopc/LsvKaVma2XvTAbFM85+53xd1aw=";
            }
          } pg.tar.gz
        ''
        # 1.4 builds the loadable extension only, so the static library is added, as for mysql_scanner
        + lib.optionalString (lib.versionOlder release "1.5") ''

          cat >> CMakeLists.txt <<'EOF'

          set(EXTENSION_NAME ''${TARGET_NAME}_extension)
          add_library(''${EXTENSION_NAME} STATIC ''${ALL_OBJECT_FILES} ''${LIBPG_SOURCES_FULLPATH})
          target_include_directories(
            ''${EXTENSION_NAME}
            PRIVATE include postgres/src/include postgres/src/backend
                    postgres/src/interfaces/libpq ''${OPENSSL_INCLUDE_DIR})
          install(
            TARGETS ''${EXTENSION_NAME}
            EXPORT "''${DUCKDB_EXPORT_SET}"
            LIBRARY DESTINATION "''${INSTALL_LIB_DIR}"
            ARCHIVE DESTINATION "''${INSTALL_LIB_DIR}")
          EOF
        ''
        + ''

          # mysql_scanner defines it too, in a file of its own
          sed -i 's/^string EscapeConnectionString(/static &/' src/storage/postgres_catalog.cpp
          grep -q '^static string EscapeConnectionString(' src/storage/postgres_catalog.cpp
        ''
        + lib.replaceStrings [ " PostgreSQL::PostgreSQL" ] [ "" ] args.postPatch;
      };

      # iceberg defines GetUCCreateView too, in a file of its own
      unity_catalog = args: {
        postPatch = args.postPatch + ''

          sed -i 's/^string GetUCCreateView(/static &/' src/storage/uc_schema_entry.cpp
          grep -q '^static string GetUCCreateView(' src/storage/uc_schema_entry.cpp
        '';
      };

      # Before 2.0 the extension is laid out as it was in DuckDB's own tree
      fts.include = "extension/fts/include";

      # The same patch as below, for a CMake that writes the link lines over several
      # lines. Its range has to end at the first of them, or it takes the rest of the file.
      lance = args: {
        postPatch =
          lib.replaceStrings
            [ "target_link_libraries(\${EXTENSION_NAME} debug" ]
            [ "target_link_libraries($" ]
            args.postPatch;
      };

      # The same patch as below, for a CMake whose external project ends at LOG_BUILD
      delta = args: {
        postPatch = lib.replaceStrings [ "LOG_OUTPUT_ON_FAILURE ON)" ] [ "LOG_BUILD ON)" ] args.postPatch;
      };

      # Until 2.0 avro-c is a library the extension finds: vcpkg builds it, from DuckDB's
      # fork (see avro-c.nix). Here it is built the same way, and the rest comes from nixpkgs.
      avro = {
        buildInputs = [
          avroC
          jansson
          snappy
          xz
          zlib
        ];
        postPatch = ''
          substituteInPlace CMakeLists.txt \
            --replace-fail "find_library(AVRO_LIBRARY libavro.a REQUIRED)" "find_library(AVRO_LIBRARY avro REQUIRED)" \
            --replace-fail "find_library(JANSSON_LIBRARY libjansson.a REQUIRED)" "find_library(JANSSON_LIBRARY jansson REQUIRED)" \
            --replace-fail "find_library(LZMA_LIBRARY liblzma.a REQUIRED)" "find_library(LZMA_LIBRARY lzma REQUIRED)" \
            --replace-fail "find_library(ZLIB_LIBRARY libz.a REQUIRED)" "find_library(ZLIB_LIBRARY z REQUIRED)"
        '';
      };
    }
    // lib.optionalAttrs (lib.versionOlder release "1.5") {
      # Before 1.5 the extension carries the header of the library, so only the
      # library is needed from the external project.
      delta.postPatch = ''
        sed -i '/^ExternalProject_Add(/,/^  LOG_BUILD ON)/d' CMakeLists.txt
        cat > ffi.cmake <<'EOF'
        set(DELTA_KERNEL_LIBPATH "''${DELTA_KERNEL_FFI_LIBRARY}")
        add_custom_target(''${KERNEL_NAME})
        EOF
        sed -i '/^# Add rust_example as a CMake target/r ffi.cmake' CMakeLists.txt
        rm ffi.cmake
        ! grep -q 'ExternalProject_Add' CMakeLists.txt

        # ducklake has a class and two functions of these names, and a symbol has no
        # namespace but duckdb's
        grep -rlE '\b(BaseMetadataFunction|MetadataFunctionInit|MetadataFunctionExecute)\b' src |
          xargs sed -i -E 's/\b(BaseMetadataFunction|MetadataFunctionInit|MetadataFunctionExecute)\b/Delta\1/g'
        ! grep -rqE '\b(BaseMetadataFunction|MetadataFunctionInit|MetadataFunctionExecute)\b' src
      '';

      # The 1.4 sources use the API of MySQL's own client library (my_bool is gone from it,
      # but SSL_MODE_PREFERRED and mysql_com.h are not in MariaDB's), which nixpkgs only
      # has as part of mysql80.
      mysql_scanner.unsupported = "its sources need MySQL's client library, which nixpkgs only ships inside the server; MariaDB's is not the same API";

      # These sources still use the file handle interface of GDAL before 3.13, which
      # the definition below adapts newer sources away from, so only older GDAL builds them.
      spatial = {
        unsupported =
          if lib.versionAtLeast gdal.version "3.13" then
            "its sources need a GDAL older than 3.13, and this nixpkgs has ${gdal.version}"
          else
            null;
        testSkips = [ ];
        postPatch = ''
          substituteInPlace CMakeLists.txt \
            --replace-fail "set(ZLIB_USE_STATIC_LIBS ON)" "set(ZLIB_USE_STATIC_LIBS OFF)" \
            --replace-fail "set(OPENSSL_USE_STATIC_LIBS ON)" "set(OPENSSL_USE_STATIC_LIBS OFF)" \
            --replace-fail "find_package(unofficial-sqlite3 CONFIG REQUIRED)" "find_package(SQLite3 REQUIRED)" \
            --replace-fail "unofficial::sqlite3::sqlite3" "SQLite::SQLite3"

          substituteInPlace src/spatial/modules/gdal/gdal_module.cpp \
            --replace-fail "OGRRegisterAllInternal();" "GDALAllRegister();" \
            --replace-fail "int Eof() override {" "void ClearErr() override {
          }

          int Error() override {
            return 0;
          }

          int Eof() override {"

          # nixpkgs sqlite is built without SQLITE_USE_URI, so the embedded proj.db URI needs the flag
          substituteInPlace src/spatial/modules/proj/proj_module.cpp \
            --replace-fail "SQLITE_OPEN_READONLY, \"memvfs\")" "SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, \"memvfs\")"

          # the bundled proj.db is from an older proj, embed the one matching the linked proj instead
          python3 - ${proj}/share/proj/proj.db src/spatial/modules/proj/proj_db.c <<'PY'
          import sys

          data = open(sys.argv[1], "rb").read()
          with open(sys.argv[2], "w") as out:
              out.write("unsigned char proj_db[] = {\n")
              for i in range(0, len(data), 12):
                  out.write("  " + ", ".join(f"0x{b:02x}" for b in data[i : i + 12]) + ",\n")
              out.write(f"}};\nunsigned int proj_db_len = {len(data)};\n")
          PY

          substituteInPlace src/spatial/util/math.cpp \
            --replace-fail "#if SPATIAL_USE_GEOS" "#if 0"
        '';
      };
    };

  mkExtension = import ../mk-extension.nix { inherit lib; };

  # An extension at the commit that DuckDB's release (or the community
  # descriptor) pins, with its submodules and patches.
  mkPinned =
    name:
    {
      # tools postPatch needs
      patchTools ? [ ],
      # shell, run inside the writable copy of the extension source
      postPatch ? "",
      ...
    }@args:
    let
      pin = pins.${name};
      submodules = pin.submodules or { };
    in
    mkExtension (
      removeAttrs args [
        "patchTools"
        "postPatch"
      ]
      // {
        inherit name;
        version = lib.substring 0 10 pin.rev;
        include = args.include or (pin.include or null);

        # The pinned source with its submodules, DuckDB's patches for it and
        # ours applied. A separate derivation, so a patch that no longer applies
        # fails in seconds instead of after a DuckDB build.
        src =
          runCommand "duckdb-extension-${name}-source"
            {
              nativeBuildInputs = patchTools;
            }
            ''
              cp -R ${fetchPin pin} $out
              chmod -R u+w $out
              cd $out

              ${lib.concatStrings (
                lib.mapAttrsToList (path: sub: ''
                  rm -rf ${path}
                  mkdir -p ${builtins.dirOf path}
                  cp -R ${fetchPin sub} ${path}
                  chmod -R u+w ${path}
                '') submodules
              )}

              ${lib.optionalString pin.patches ''
                # as scripts/apply_extension_patches.py does
                for patch in ${duckdbSrc}/.github/patches/extensions/${name}/*.patch; do
                  echo "applying $patch"
                  patch -p1 --forward -i "$patch"
                done
              ''}

              ${postPatch}
            '';
      }
    )
    // {
      inherit (pin) owner repo rev;
      # in duckdb/community-extensions rather than in DuckDB's own configuration
      community = pin.community or null;
    };

  # an override is the attributes to replace, or a function from the definition to them
  overrideFor =
    name: args:
    let
      override = versionOverrides.${name} or { };
    in
    if lib.isFunction override then override args else override;

  # Every extension below is defined for every DuckDB version, but a version only
  # has the pins of the extensions it configures. The others say so when asked
  # for, instead of failing to evaluate.
  mkPinnedExtension =
    name: args:
    if pins ? ${name} then
      mkPinned name (args // overrideFor name args)
    else
      mkExtension {
        inherit name;
        src = null;
        version = "none";
        unsupported = "DuckDB ${duckdbVersion} has no pin for it: it is not part of that release, or not packaged for it yet";
      }
      // {
        owner = null;
        repo = null;
        rev = null;
        community = null;
      };
in
lib.mapAttrs mkPinnedExtension {
  avro = {
    buildInputs = [
      jansson
      snappy
      xz
      zlib
    ];
    postPatch = ''
      # avro-c's cmake runs version.sh, which expects /bin/bash
      patchShebangs third_party/avro-c/lang/c/version.sh

      # avro-c predates C23, which newer compilers default to
      substituteInPlace CMakeLists.txt \
        --replace-fail "# Add avro-c from submodule" "set(CMAKE_C_STANDARD 17)
      set(CMAKE_C_FLAGS \"\''${CMAKE_C_FLAGS} -Wno-incompatible-pointer-types\")
      # Add avro-c from submodule"
    '';
    smoke = "SELECT CASE WHEN count(*) >= 1 THEN 1 ELSE error('read_avro') END FROM duckdb_functions() WHERE function_name = 'read_avro'";
  };

  aws = {
    buildInputs = [
      awsSdk
      curl
      openssl
      zlib
    ];
    smoke = "SELECT CASE WHEN count(*) >= 1 THEN 1 ELSE error('load_aws_credentials') END FROM duckdb_functions() WHERE function_name = 'load_aws_credentials'";
  };

  azure = {
    unsupported = if azure-sdk-for-cpp == null then "this nixpkgs has no azure-sdk-for-cpp" else null;
    buildInputs = [
      azure-sdk-for-cpp.core
      azure-sdk-for-cpp.identity
      azure-sdk-for-cpp.storage-blobs
      azure-sdk-for-cpp.storage-common
      azure-sdk-for-cpp.storage-files-datalake
    ];
    # the secret type exists only with the extension, and az:// needs credentials
    smoke = {
      sql = "SELECT * FROM read_csv('az://container/x.csv')";
      expectError = "No valid Azure credentials found";
    };
  };

  delta = {
    rust = {
      package = deltaFfi;
      archive = "lib/libdelta_kernel_ffi.a";
      cmakeVariable = "DELTA_KERNEL_FFI_LIBRARY";
    };
    # the headers cbindgen generated stay in the package
    cmakeFlags = [ (lib.cmakeFeature "DELTA_KERNEL_FFI_DIR" "${deltaFfi}") ];
    postPatch = ''
      # Upstream clones delta-kernel-rs and runs cargo here. Use the library built
      # separately, and keep the `delta_kernel` target the extension depends on:
      # it now only post-processes the generated C++ header.
      sed -i '/^ExternalProject_Add(/,/^  LOG_OUTPUT_ON_FAILURE ON)/d' CMakeLists.txt
      cat > ffi.cmake <<'EOF'
      set(DELTA_KERNEL_LIBPATH "''${DELTA_KERNEL_FFI_LIBRARY}")
      add_custom_command(
        OUTPUT "''${DELTA_KERNEL_FFI_HEADER_PATCHED}"
        COMMAND sh ''${CMAKE_CURRENT_SOURCE_DIR}/scripts/ffi/generate_delta_kernel_ffi_header
                ''${CMAKE_CURRENT_SOURCE_DIR}/scripts/ffi
                ''${DELTA_KERNEL_FFI_DIR}/ffi-headers/delta_kernel_ffi.hpp
                ''${CMAKE_BINARY_DIR}/codegen/include
        VERBATIM)
      add_custom_target(''${KERNEL_NAME} DEPENDS "''${DELTA_KERNEL_FFI_HEADER_PATCHED}")
      EOF
      sed -i '/^# Add rust_example as a CMake target/r ffi.cmake' CMakeLists.txt
      rm ffi.cmake
      ! grep -q 'ExternalProject_Add' CMakeLists.txt
    '';
    # an attached Delta database is one table, named after the alias
    smoke = ''
      ATTACH 'smoke_delta' AS d (TYPE delta);
      CREATE TABLE d.d(i INTEGER, s VARCHAR);
      INSERT INTO d.d VALUES (1, 'a'), (2, 'b'), (3, 'c');
      SELECT CASE WHEN sum(i) = 6 THEN 1 ELSE error('delta round trip') END FROM delta_scan('smoke_delta');
    '';
  };

  ducklake = {
    buildInputs = [ croaring ];
    # a catalog and its data in local files
    smoke = ''
      ATTACH 'ducklake:ducklake_meta.db' AS dl (DATA_PATH 'ducklake_data/');
      CREATE TABLE dl.t(i INTEGER);
      INSERT INTO dl.t VALUES (1), (2), (3);
      SELECT CASE WHEN sum(i) = 6 THEN 1 ELSE error('ducklake') END FROM dl.t;
    '';
  };

  # a community extension: SQL/PGQ graph queries. It is a grammar, so it has to be
  # switched on (from DuckDB 2.0) before the syntax is understood.
  duckpgq.smoke.sql = [
    "SET active_grammar_extensions = ['duckpgq']"
    ''
      CREATE TABLE person AS SELECT * FROM (VALUES (1), (2), (3)) t(id);
      CREATE TABLE knows AS SELECT * FROM (VALUES (1, 2), (2, 3)) t(a, b);
      CREATE PROPERTY GRAPH g
        VERTEX TABLES (person)
        EDGE TABLES (knows SOURCE KEY (a) REFERENCES person (id) DESTINATION KEY (b) REFERENCES person (id) LABEL knows)
    ''
    ''
      SELECT CASE WHEN count(*) = 2 THEN 1 ELSE error('graph match') END
        FROM GRAPH_TABLE (g MATCH (x:person)-[k:knows]->(y:person) COLUMNS (x.id AS a, y.id AS b))
    ''
    ''
      SELECT CASE WHEN max(hops) = 2 THEN 1 ELSE error('shortest path') END
        FROM GRAPH_TABLE (g MATCH p = ANY SHORTEST (x:person)-[k:knows]->{1,3}(y:person) COLUMNS (x.id AS a, y.id AS b, path_length(p) AS hops))
    ''
  ];

  # shift_jis is not built into DuckDB, only provided by this extension
  encodings.smoke = {
    setup = ''printf '\x93\xfa\x96\x7b\n' > sjis.txt'';
    sql = "SELECT CASE WHEN c = '日本' THEN 1 ELSE error('shift_jis') END FROM read_csv('sjis.txt', encoding = 'shift_jis', header = false, columns = {'c': 'VARCHAR'})";
  };

  excel = {
    buildInputs = [
      expat
      minizip-ng
      zlib
      # what the minizip-ng package config looks for; before 4.2 it is not propagated
      bzip2
      openssl
      xz
      zstd
    ];
    smoke = "SELECT CASE WHEN excel_text(1234.5678, '0.00') = '1234.57' THEN 1 ELSE error('excel_text') END";
  };

  fts.smoke = ''
    CREATE TABLE docs(id INTEGER, body VARCHAR);
    INSERT INTO docs VALUES (1, 'the quick brown fox'), (2, 'a lazy dog');
    PRAGMA create_fts_index('docs', 'id', 'body');
    SELECT CASE WHEN count(*) = 1 THEN 1 ELSE error('fts match') END
    FROM (SELECT fts_main_docs.match_bm25(id, 'fox') AS score FROM docs) WHERE score IS NOT NULL;
  '';

  glue = {
    buildInputs = [
      awsSdk
      curl
      openssl
      zlib
    ];
    smoke = "SELECT CASE WHEN count(*) >= 1 THEN 1 ELSE error('glue_partitions') END FROM duckdb_functions() WHERE function_name = 'glue_partitions'";
  };

  httpfs = {
    buildInputs = [
      curl
      openssl
    ];
    # reading over HTTP has its own check, which needs a server
    smoke = "SELECT CASE WHEN count(*) = 1 THEN 1 ELSE error('httpfs settings') END FROM duckdb_settings() WHERE name = 'httpfs_client_implementation'";
  };

  iceberg = {
    dependencies = [
      "avro"
      "httpfs"
    ];
    # signs AWS requests itself, so it does not use the AWS SDK
    buildInputs = [
      croaring
      curl
      openssl
      zlib
    ];
    smoke = "SELECT CASE WHEN count(*) >= 1 THEN 1 ELSE error('iceberg_scan') END FROM duckdb_functions() WHERE function_name = 'iceberg_scan'";
  };

  inet.smoke = "SELECT CASE WHEN '192.168.1.5'::INET <<= '192.168.0.0/16'::INET AND NOT '10.0.0.1'::INET <<= '192.168.0.0/16'::INET THEN 1 ELSE error('inet') END";

  lance = {
    rust = {
      package = lanceFfi;
      archive = "lib/liblance_duckdb_ffi.a";
      cmakeVariable = "LANCE_FFI_LIBRARY";
    };
    smoke = ''
      COPY (SELECT i AS id, 'row ' || i AS label FROM range(1000) t(i)) TO 'smoke.lance' (FORMAT lance);
      SELECT CASE WHEN count(*) = 1000 AND sum(id) = 499500 THEN 1 ELSE error('lance round trip') END FROM 'smoke.lance';
    '';
    postPatch = ''
      # Upstream runs cargo from here. Use the library built separately, and keep
      # the target so the link lines that depend on it still work.
      sed -i -e '/^set(RUST_TARGET_DIR/,/^target_link_libraries(''${EXTENSION_NAME} debug/{/^target_link_libraries(''${EXTENSION_NAME} debug/!d}' CMakeLists.txt
      cat > ffi.cmake <<'EOF'
      set(RUST_DEBUG_LIB "''${LANCE_FFI_LIBRARY}")
      set(RUST_RELEASE_LIB "''${LANCE_FFI_LIBRARY}")
      add_custom_target(lance_duckdb_ffi_build)
      EOF
      sed -i '/^# Build and link Rust staticlib/r ffi.cmake' CMakeLists.txt
      rm ffi.cmake
      ! grep -q 'cargo build' CMakeLists.txt
    '';
  };

  legacy_parser.smoke = "SELECT CASE WHEN count(*) = 1 THEN 1 ELSE error('enable_legacy_parser') END FROM duckdb_settings() WHERE name = 'enable_legacy_parser'";

  mysql_scanner = {
    buildInputs = [
      mariadb-connector-c
      mariadb-connector-c.dev
    ];
    postPatch = ''
      # The extension expects vcpkg's libmariadb. The library is in a lib/mariadb
      # subdirectory, so link it by -L and -l: the compiler wrapper then adds
      # that directory to the RPATH, which a full path to the file would not.
      substituteInPlace CMakeLists.txt \
        --replace-fail "find_package(${mysqlPackage} REQUIRED)" "set(MYSQL_LIBRARIES -L${mariadb-connector-c}/lib/mariadb -lmariadb)"
      sed -i 's|[$]{CMAKE_BINARY_DIR}/vcpkg_installed/[$]{VCPKG_TARGET_TRIPLET}/include/mysql|${mariadb-connector-c.dev}/include/mysql|' CMakeLists.txt
      ! grep -q vcpkg_installed CMakeLists.txt

      # Upstream only builds the loadable extension. Linking it in needs the
      # static library the other extensions define, with the MariaDB library.
      cat >> CMakeLists.txt <<'EOF'

      add_library(''${EXTENSION_NAME} STATIC ''${ALL_OBJECT_FILES})
      target_link_libraries(''${EXTENSION_NAME} ''${MYSQL_LIBRARIES})
      install(
        TARGETS ''${EXTENSION_NAME}
        EXPORT "''${DUCKDB_EXPORT_SET}"
        LIBRARY DESTINATION "''${INSTALL_LIB_DIR}"
        ARCHIVE DESTINATION "''${INSTALL_LIB_DIR}")
      EOF
    '';
    # reaches the MariaDB client library, which fails to connect to nothing
    smoke = {
      sql = "ATTACH 'host=127.0.0.1 port=1 database=x' AS my (TYPE mysql)";
      expectError = "Failed to connect to MySQL database";
    };
  };

  # A C API extension with its own build, so it cannot be linked in.
  odbc_scanner = {
    linkable = false;
    buildInputs = [ unixodbc ];
  };

  postgres_scanner = {
    buildInputs = [
      libpq
      openssl
    ];
    testSkips = [
      {
        reason = "runs a LogicalPlanStatement, which cannot be copied, and the core copies a statement whenever a client state asks to be able to rebind, as this extension's does. They pass without postgres_scanner loaded. The only use of the statement outside tests is a developer tool";
        names = [
          "Table function registration retains canonical qualification"
          "Aliased table function overloads retain catalog identity"
          "Current list serialization preserves bound ordering across repeated copies"
          "Secure-view caller predicates retain source positions across pruning and serialization"
          "Nested function qualification survives plan copies"
          "Test executing an optimized plan with a flipped delim join"
          # test/sql_export: each builds its plan as a LogicalPlanStatement
          "Logical plan SQL export copies owned chunk data and selected columns"
          "Owned chunk export preserves observable execution groups"
          "Owned chunk SQL export retains delivered rows before conversion errors"
          "Owned chunk SQL export requires an explicit consumer evaluation contract"
          "Owned chunk SQL export accounts for intrinsic SINGLE join errors"
          "Owned chunk SQL export preserves selected rows after a cross product"
          "Logical plan SQL export preserves partial CTE streams and errors"
          "Logical plan SQL export rejects recursive wrappers when inlining is unavailable"
          "Logical plan SQL export preserves join output maps and empty sides"
          "Logical plan SQL export validates noncanonical PIVOT defaults and list sources"
          "Logical plan SQL export preserves empty filter projection maps"
          "Table row number SQL export guards filtered numbering"
          "Table SQL export distinguishes pruning hints from row filters"
          "Logical plan SQL export checks consumers of multirow VALUES"
          "Logical plan SQL export verifies unordered VALUES list canonicalizers"
          "Logical plan SQL export rejects a throwing later VALUES row below LIMIT"
        ];
      }
    ];
    postPatch = ''
      # Both helpers are only used in their own file. Upstream builds the
      # extension on its own, but linked in beside unity_catalog they collide.
      sed -i 's/^unique_ptr<SecretEntry> GetSecret(/static &/' src/storage/postgres_catalog.cpp
      sed -i 's/^bool CatalogTypeIsSupported(/static &/' src/storage/postgres_schema_entry.cpp
      grep -q '^static unique_ptr<SecretEntry> GetSecret(' src/storage/postgres_catalog.cpp
      grep -q '^static bool CatalogTypeIsSupported(' src/storage/postgres_schema_entry.cpp

      # upstream links the libraries into the loadable extension only
      cat >> CMakeLists.txt <<'EOF'

      target_link_libraries(''${EXTENSION_NAME} OpenSSL::SSL OpenSSL::Crypto PostgreSQL::PostgreSQL)
      EOF
    '';
    # reaches libpq, which fails to connect to nothing
    smoke = {
      sql = "ATTACH 'dbname=x host=127.0.0.1 port=1 connect_timeout=2' AS pg (TYPE postgres)";
      expectError = "Unable to connect to Postgres";
    };
  };

  # a community extension: a pipe syntax. Loading switches it on for the connections
  # of a program that links DuckDB; the shell sets its own list of grammars, so there
  # it is switched on with psql_enable(), in a command before the first that uses it.
  psql = {
    smoke.sql = [
      "CALL psql_enable()"
      "FROM range(10) |> WHERE range >= 5 |> SELECT CASE WHEN count(*) = 5 THEN 1 ELSE error('psql pipeline') END"
    ];
    testSkips = [
      {
        reason = "psql switches its grammar on in every connection a program makes, and these C++ tests assert that a new connection has the base grammar or count the grammars compiled, so with psql linked they find one more. Nothing the test configuration loads changes that: run apart with nothing loaded they fail the same way. They pass in every build without psql";
        names = [
          "Literal caches respect active grammar extensions"
          "The least recently used grammar for active grammar extensions is evicted"
          "Active grammar extensions are cached on their connection"
          "Grammar extensions that fail to compile do not evict cached grammars"
        ];
      }
    ];
  };

  quack = {
    dependencies = [ "httpfs" ];
    buildInputs = [
      curl
      openssl
    ];
    smoke = "SELECT CASE WHEN count(*) >= 1 THEN 1 ELSE error('quack_serve') END FROM duckdb_functions() WHERE function_name = 'quack_serve'";
    testRuns = [
      {
        reason = "quack_serve needs the crypto module of httpfs, and these tests require only quack; in the product httpfs is loaded at startup like the rest";
        loads = [ "httpfs" ];
        tests = [
          "test/sql/attach/external_resource_logging.test"
          "test/sql/attach/external_resource_lifecycle.test"
        ];
      }
      {
        reason = "it passes alone, and fails after test/sql/catalog/comment_on_column_remote_catalog.test in one process, which also uses quack and the same port, when any of lance, mysql_scanner, postgres_scanner, spatial, unity_catalog or vortex is linked; a separate process per test is how such tests run elsewhere";
        loads = [ ];
        tests = [ "test/sql/connect/connect_passthrough_quack.test" ];
      }
    ];
  };

  # a community extension
  sheetreader = {
    postPatch = ''
      # The extension carries a miniz of its own, and zipfs links another version of
      # it. A C library has no namespace, so both would define every mz_ function in
      # the one libduckdb. Rename this copy's.
      grep -rlE '\b(mz|tdefl|tinfl|miniz)_' src | xargs sed -i -E 's/\b(mz|tdefl|tinfl|miniz)_/sheetreader_\1_/g'
      ! grep -rqE '\b(mz|tdefl|tinfl)_' src
    '';
    # The workbook is written by the excel extension, which the check links with the
    # rest. Cells with strings are inline in it, which this extension does not read yet.
    smoke.sql = [
      "COPY (SELECT i AS a, i * 2 AS b FROM range(1, 4) t(i)) TO 'smoke.xlsx' (FORMAT xlsx, HEADER false)"
      "SELECT CASE WHEN count(*) = 3 AND sum(Numeric0) = 6 AND sum(Numeric1) = 12 THEN 1 ELSE error('sheetreader') END FROM sheetreader('smoke.xlsx')"
    ];
  };

  spatial = {
    # the sources use the file handle interface of GDAL 3.13
    unsupported =
      if lib.versionOlder gdal.version "3.13" then
        "its sources need GDAL 3.13 or newer, and this nixpkgs has ${gdal.version}"
      else
        null;
    testSkips = [
      {
        reason = "expects EPSG:4326 to be an unknown coordinate system, which spatial's coordinate system database makes known";
        names = [ "V2: GEOMETRY with an unknown coordinate system" ];
      }
    ];
    buildInputs = [
      curl
      expat
      gdal
      geos
      openssl
      proj
      sqlite
      zlib
    ];
    patchTools = [ python3 ];
    postPatch = ''
      substituteInPlace CMakeLists.txt \
        --replace-fail "set(ZLIB_USE_STATIC_LIBS ON)" "set(ZLIB_USE_STATIC_LIBS OFF)" \
        --replace-fail "set(OPENSSL_USE_STATIC_LIBS ON)" "set(OPENSSL_USE_STATIC_LIBS OFF)" \
        --replace-fail "find_package(unofficial-sqlite3 CONFIG REQUIRED)" "find_package(SQLite3 REQUIRED)" \
        --replace-fail "unofficial::sqlite3::sqlite3" "SQLite::SQLite3"

      substituteInPlace src/spatial/modules/gdal/gdal_module.cpp \
        --replace-fail "OGRRegisterAllInternal();" "GDALAllRegister();" \
        --replace-fail "VSIFileManager::InstallHandler(client_prefix, fs_handler.get());" "VSIFileManager::InstallHandler(client_prefix, std::shared_ptr<VSIFilesystemHandler>(fs_handler.get(), [](VSIFilesystemHandler *) {}));" \
        --replace-fail "size_t Read(void *buffer, size_t size, size_t count) override {" "size_t Read(void *buffer, size_t nBytes) override {
          return Read(buffer, 1, nBytes);
        }

        size_t Read(void *buffer, size_t size, size_t count) {" \
        --replace-fail "size_t Write(const void *buffer, size_t size, size_t count) override {" "size_t Write(const void *buffer, size_t nBytes) override {
          return Write(buffer, 1, nBytes);
        }

        size_t Write(const void *buffer, size_t size, size_t count) {"

      # nixpkgs sqlite is built without SQLITE_USE_URI, so the embedded proj.db URI needs the flag
      substituteInPlace src/spatial/modules/proj/proj_module.cpp \
        --replace-fail "SQLITE_OPEN_READONLY, \"memvfs\")" "SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, \"memvfs\")"

      # the bundled proj.db is from proj 9.1.1, embed the one matching the linked proj instead
      python3 - ${proj}/share/proj/proj.db src/spatial/modules/proj/proj_db.c <<'PY'
      import sys

      data = open(sys.argv[1], "rb").read()
      with open(sys.argv[2], "w") as out:
          out.write("unsigned char proj_db[] = {\n")
          for i in range(0, len(data), 12):
              out.write("  " + ", ".join(f"0x{b:02x}" for b in data[i : i + 12]) + ",\n")
          out.write(f"}};\nunsigned int proj_db_len = {len(data)};\n")
      PY

      substituteInPlace src/spatial/util/math.cpp \
        --replace-fail "#if SPATIAL_USE_GEOS" "#if 0"
    '';
    smoke = ''
      SELECT CASE WHEN ST_AsText(ST_Point(1, 2)) = 'POINT (1 2)' THEN 1 ELSE error('spatial') END;
      SELECT ST_AsText(ST_Transform(ST_Point(10, 50), 'EPSG:4326', 'EPSG:3857'));
    '';
  };

  sqlite_scanner = {
    smoke = ''
      ATTACH ':memory:' AS s (TYPE sqlite);
      CREATE TABLE s.t(i INTEGER);
      INSERT INTO s.t VALUES (41), (1);
      SELECT CASE WHEN (SELECT sum(i) FROM s.t) = 42 THEN 1 ELSE error('sqlite_scanner') END;
    '';
    testSkips = [
      {
        reason = "asserts that LOAD sqlite fails because the extension is absent, which cannot hold once it is linked in";
        paths = [ "test/extension/local_extension_coverage.test" ];
      }
    ];
  };

  sqlsmith.smoke = "SELECT CASE WHEN count(*) >= 1 THEN 1 ELSE error('sqlsmith') END FROM duckdb_functions() WHERE function_name = 'sqlsmith'";

  unity_catalog = {
    buildInputs = [ croaring ];
    # the secret type exists only with the extension
    smoke = ''
      CREATE SECRET uc (TYPE unity_catalog, TOKEN 'x', ENDPOINT 'http://127.0.0.1:1');
      SELECT CASE WHEN count(*) = 1 THEN 1 ELSE error('unity_catalog secret') END FROM duckdb_secrets() WHERE type = 'unity_catalog';
    '';
    postPatch = ''
      # Both helpers are only used in their own file. Upstream builds the
      # extension on its own, but linked in beside postgres_scanner they collide.
      sed -i 's/^unique_ptr<SecretEntry> GetSecret(/static &/' src/unity_catalog_extension.cpp
      sed -i 's/^bool CatalogTypeIsSupported(/static &/' src/storage/uc_schema_entry.cpp
      grep -q '^static unique_ptr<SecretEntry> GetSecret(' src/unity_catalog_extension.cpp
      grep -q '^static bool CatalogTypeIsSupported(' src/storage/uc_schema_entry.cpp
    '';
  };

  vortex = {
    rust = {
      package = vortexFfi;
      archive = "lib/libvortex_duckdb.a";
      cmakeVariable = "VORTEX_FFI_LIBRARY";
    };
    postPatch = ''
      # Upstream gets Corrosion from git, and has it run cargo, which fetches the
      # vortex repository. Use the library built separately, as the target the
      # extension links, and drop the version lookup that runs git against github.
      sed -i '/^include(FetchContent)/,/^FetchContent_MakeAvailable(Corrosion)/d' CMakeLists.txt
      sed -i '/^if(CMAKE_BUILD_TYPE STREQUAL "Release")/,/^include_directories(src\/include)/{/^include_directories(src\/include)/!d}' CMakeLists.txt
      cat > ffi.cmake <<'EOF2'
      add_library(''${VORTEX_LIB_NAME} STATIC IMPORTED GLOBAL)
      set_target_properties(''${VORTEX_LIB_NAME} PROPERTIES
        IMPORTED_LOCATION "''${VORTEX_FFI_LIBRARY}"
        INTERFACE_LINK_LIBRARIES "m;dl;pthread")

      EOF2
      sed -i '/^include_directories(src\/include)/e cat ffi.cmake' CMakeLists.txt
      rm ffi.cmake
      ! grep -q -E 'corrosion|cargo|ls-remote' CMakeLists.txt
    '';
    # a round trip crosses the Rust and C++ boundary, so it would show a vortex.h
    # that had fallen behind the Rust sources
    smoke = ''
      COPY (SELECT i AS id, 'row ' || i AS label FROM range(1000) t(i)) TO 'smoke.vortex' (FORMAT vortex);
      SELECT CASE WHEN count(*) = 1000 AND sum(id) = 499500 THEN 1 ELSE error('vortex round trip') END FROM read_vortex('smoke.vortex');
    '';
  };

  vss.smoke = ''
    CREATE TABLE v(e FLOAT[3]);
    INSERT INTO v VALUES ([1, 2, 3]::FLOAT[3]);
    CREATE INDEX idx ON v USING HNSW (e);
  '';

  # a community extension
  webbed = {
    buildInputs = [
      libxml2
      zlib
    ];
    smoke = ''
      SELECT CASE WHEN xml_extract_text('<book><title>Database Guide</title></book>', '//title') = ['Database Guide'] THEN 1 ELSE error('xml_extract_text') END;
      SELECT CASE WHEN html_extract_text('<html><body><h1>Welcome</h1></body></html>', '//h1') = ['Welcome'] THEN 1 ELSE error('html_extract_text') END;
    '';
  };

  # a community extension
  zipfs = {
    buildInputs = [
      libarchive
      miniz
    ];
    # a zip is read with miniz, other archives with libarchive
    smoke = {
      setup = ''
        printf 'a,b\n1,2\n3,4\n' > data.csv
        ${lib.getExe' libarchive "bsdtar"} -c --format zip -f smoke.zip data.csv
        ${lib.getExe' libarchive "bsdtar"} -c -z -f smoke.tar.gz data.csv
      '';
      sql = [
        "SELECT CASE WHEN sum(b) = 6 THEN 1 ELSE error('zip') END FROM 'zip://smoke.zip/data.csv'"
        "SET zipfs_split = '!!'"
        "SELECT CASE WHEN sum(b) = 6 THEN 1 ELSE error('tar.gz') END FROM 'archive://smoke.tar.gz!!data.csv'"
      ];
    };
  };
}
