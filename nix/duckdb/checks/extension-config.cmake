# Reads one of DuckDB's extension configs. They are CMake, so run it: duckdb_extension_load
# records what it is given, and the conditions around it are decided the way DuckDB decides them.
#
#   cmake -DCONFIG=<file> -DOUT=<file to append to> -P extension-config.cmake
set(BUILD_COMPLETE_EXTENSION_SET ON)
set(WASM_ENABLED OFF)
set(MUSL_ENABLED OFF)
get_filename_component(EXTENSION_CONFIG_BASE_DIR "${CONFIG}" DIRECTORY)

function(duckdb_extension_load name)
  cmake_parse_arguments(PARSE_ARGV 1 ext "" "GIT_URL;GIT_TAG" "")
  if(ext_GIT_URL)
    file(APPEND "${OUT}" "{\"${name}\": {\"url\": \"${ext_GIT_URL}\", \"rev\": \"${ext_GIT_TAG}\"}}\n")
  endif()
endfunction()

include("${CONFIG}")
