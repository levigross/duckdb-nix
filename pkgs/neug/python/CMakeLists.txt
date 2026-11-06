# The Python binding of NeuG (tools/python_bind of its sources), built against an INSTALLED
# NeuG instead of inside its build: the five files of the binding include only headers that
# the installation has, and link the library. What the CMake of NeuG would do for it, and how:
#  - the definitions that the headers branch on come with the CMake package of NeuG
#  - the symbols of protobuf and abseil are kept out of the module, as in cmake/neug_exports.ld
#    of NeuG, so that they do not meet the copies in pyarrow
#
# The sources are in src/ and the linker's version script in neug_exports.ld, both copied from
# NeuG by pkgs/neug/python.nix, which patches the sources for the pybind11 that is used.
cmake_minimum_required(VERSION 3.16)
project(neug_py_bind LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# pybind11 would turn on link-time optimization, which the CMake of NeuG switches off for this
# module (an internal error of GCC 13 with the static libraries linked into it)
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION FALSE)

find_package(neug REQUIRED)
find_package(pybind11 CONFIG REQUIRED)

file(GLOB _sources "${CMAKE_SOURCE_DIR}/src/*.cc")
pybind11_add_module(neug_py_bind MODULE ${_sources})

target_include_directories(neug_py_bind PRIVATE
  "${CMAKE_SOURCE_DIR}/src"
  # the headers of the compiler of NeuG are included as "common/..." by one another
  "${NEUG_INCLUDE_DIR}/neug/compiler")

# the binding serves a database over HTTP when asked to, as the library was built to
target_compile_definitions(neug_py_bind PRIVATE BUILD_HTTP_SERVER ENABLE_HTTP_PROTOCOL)

# libneug, with the glog, protobuf and abseil that it carries, which its CMake package knows
target_link_libraries(neug_py_bind PRIVATE ${NEUG_LIBRARIES})

target_link_options(neug_py_bind PRIVATE
  "LINKER:--version-script,${CMAKE_SOURCE_DIR}/neug_exports.ld"
  "LINKER:--exclude-libs,libprotobuf.a"
  "LINKER:--exclude-libs,libprotobuf-lite.a"
  "LINKER:--exclude-libs,libprotoc.a"
  "LINKER:--exclude-libs,libutf8_range.a"
  "LINKER:--exclude-libs,libutf8_validity.a")

install(TARGETS neug_py_bind LIBRARY DESTINATION lib)
