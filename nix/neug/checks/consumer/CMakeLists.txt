cmake_minimum_required(VERSION 3.16)
project(neug_consumer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# found the way a user's project finds an installed NeuG
find_package(neug REQUIRED)

add_executable(consumer consumer.cc)
target_include_directories(consumer PRIVATE ${NEUG_INCLUDE_DIRS})
target_link_libraries(consumer PRIVATE ${NEUG_LIBRARIES})
