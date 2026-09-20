cmake_minimum_required(VERSION 3.16)
project(mestra_cpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

option(MESTRA_BUILD_TESTS "Build the mestra test suite" ON)

find_package(HDF5 REQUIRED COMPONENTS C HL)

add_library(mestra
  src/sha256.cpp
  src/units.cpp
  src/names.cpp
  src/value.cpp
  src/dataset.cpp
  src/h5.cpp
  src/layout.cpp
  src/codec.cpp
  src/read.cpp
  src/write.cpp
  src/validate.cpp
  src/callable.cpp
  src/affine.cpp
  src/evaluate.cpp
)

target_include_directories(mestra
  PUBLIC  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)

if(TARGET HDF5::HDF5)
  target_link_libraries(mestra PUBLIC HDF5::HDF5)
else()
  target_include_directories(mestra PUBLIC ${HDF5_INCLUDE_DIRS})
  target_link_libraries(mestra PUBLIC ${HDF5_LIBRARIES})
endif()
if(HDF5_HL_LIBRARIES)
  target_link_libraries(mestra PUBLIC ${HDF5_HL_LIBRARIES})
elseif(TARGET HDF5::HDF5_HL)
  target_link_libraries(mestra PUBLIC HDF5::HDF5_HL)
endif()

# -ffp-contract=off: section 27 fixes the summation order of the affine
# callable and the corpus compares float64 results bit for bit, so no
# multiply and add may be fused into a single rounding step.
target_compile_options(mestra PRIVATE
  -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion
  -ffp-contract=off)

add_executable(mestra-cli tools/mestra_cli.cpp)
target_link_libraries(mestra-cli PRIVATE mestra)
target_compile_options(mestra-cli PRIVATE
  -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion
  -ffp-contract=off)

if(MESTRA_BUILD_TESTS)
  enable_testing()

  add_executable(mestra-unit tests/unit_tests.cpp)
  target_link_libraries(mestra-unit PRIVATE mestra)
  target_include_directories(mestra-unit PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_compile_options(mestra-unit PRIVATE
    -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion
    -ffp-contract=off)
  add_test(NAME unit COMMAND mestra-unit)

  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_Interpreter_FOUND)
    add_test(NAME corpus COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_corpus.py
      --cli $<TARGET_FILE:mestra-cli>
      --vectors ${CMAKE_CURRENT_SOURCE_DIR}/../vectors)
  endif()
endif()

install(TARGETS mestra mestra-cli
        RUNTIME DESTINATION bin
        LIBRARY DESTINATION lib
        ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)
