cmake_minimum_required(VERSION 3.5)

# The name of the extension, which is also the one in src/hello_extension.cpp
# and in extension.nix
set(TARGET_NAME hello)

set(EXTENSION_NAME ${TARGET_NAME}_extension)
set(LOADABLE_EXTENSION_NAME ${TARGET_NAME}_loadable_extension)

project(${TARGET_NAME})

include_directories(src/include)

set(EXTENSION_SOURCES src/hello_extension.cpp)

# build_static_extension and build_loadable_extension come from DuckDB's CMake.
# DuckDB links the static library in, the loadable one is for DuckDB's own
# extension repository.
build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

install(
  TARGETS ${EXTENSION_NAME}
  EXPORT "${DUCKDB_EXPORT_SET}"
  LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
  ARCHIVE DESTINATION "${INSTALL_LIB_DIR}")
