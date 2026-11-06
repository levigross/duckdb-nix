cmake_minimum_required(VERSION 3.16)
project(neug_c VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Found the way any program finds an installed NeuG. The CMake package of NeuG gives the
# definitions the headers branch on (NEUG_WITH_MIMALLOC and the others), the include
# directory, and the libraries it needs (abseil, protobuf, glog, OpenSSL).
find_package(neug REQUIRED)

add_library(neug_c SHARED neug_c.cc)
target_include_directories(neug_c PRIVATE ${NEUG_INCLUDE_DIRS})
target_compile_options(neug_c PRIVATE
  -fvisibility=hidden -fvisibility-inlines-hidden -Wall -Wextra)
target_link_libraries(neug_c PRIVATE ${NEUG_LIBRARIES})

# Only the functions of neug_c.h leave the library. The protobuf, abseil and glog that the
# headers of NeuG need are linked into it as static archives, and stay inside.
target_link_options(neug_c PRIVATE
  LINKER:--no-undefined
  LINKER:--version-script,${CMAKE_CURRENT_SOURCE_DIR}/neug_c.map
  LINKER:--exclude-libs,ALL)

install(TARGETS neug_c LIBRARY DESTINATION lib)
install(FILES neug_c.h DESTINATION include)

configure_file(neug_c.pc.in ${CMAKE_CURRENT_BINARY_DIR}/neug_c.pc @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/neug_c.pc DESTINATION lib/pkgconfig)
