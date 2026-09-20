cmake_minimum_required(VERSION 3.16)
project(mestra_cpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

option(MESTRA_BUILD_TESTS "Build the mestra test suite" ON)
# A file is untrusted input, so the suite is meant to be run under the
# sanitizers from time to time as well as plain.
option(MESTRA_SANITIZE "Build with the address and undefined sanitizers" OFF)

set(MESTRA_WARNINGS -Wall -Wextra -Wpedantic -Wshadow -Wconversion
                    -Wsign-conversion)
set(MESTRA_SANITIZER_FLAGS "")
if(MESTRA_SANITIZE)
  set(MESTRA_SANITIZER_FLAGS
      -fsanitize=address,undefined -fno-omit-frame-pointer
      -fno-sanitize-recover=undefined)
  add_link_options(-fsanitize=address,undefined)
endif()

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
  src/weights.cpp
  src/post.cpp
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
  ${MESTRA_WARNINGS} -ffp-contract=off ${MESTRA_SANITIZER_FLAGS})

add_executable(mestra-cli tools/mestra_cli.cpp)
target_link_libraries(mestra-cli PRIVATE mestra)
target_compile_options(mestra-cli PRIVATE
  ${MESTRA_WARNINGS} -ffp-contract=off ${MESTRA_SANITIZER_FLAGS})

if(MESTRA_BUILD_TESTS)
  enable_testing()

  add_executable(mestra-unit tests/unit_tests.cpp)
  target_link_libraries(mestra-unit PRIVATE mestra)
  target_include_directories(mestra-unit PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_compile_options(mestra-unit PRIVATE
    ${MESTRA_WARNINGS} -ffp-contract=off ${MESTRA_SANITIZER_FLAGS})
  add_test(NAME unit COMMAND mestra-unit)

  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_Interpreter_FOUND)
    add_test(NAME corpus COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_corpus.py
      --cli $<TARGET_FILE:mestra-cli>
      --vectors ${CMAKE_CURRENT_SOURCE_DIR}/../vectors)
    # Files that are legal HDF5 and are not this format.  They say
    # nothing about what a conforming file means; they say that a
    # reader answers for a file it did not write.
    # The corpus's own hostile subset, whose contract section 30
    # gives: the required identifiers must appear, more are allowed,
    # and validate, info and read must all refuse inside the timeout.
    # Two of its files are generated rather than committed; see
    # tests/run_shared_hostile.py.
    add_test(NAME shared_hostile COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_shared_hostile.py
      --cli $<TARGET_FILE:mestra-cli>
      --vectors ${CMAKE_CURRENT_SOURCE_DIR}/../vectors)
    set_tests_properties(shared_hostile PROPERTIES TIMEOUT 900)

    add_test(NAME hostile COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_hostile.py
      --cli $<TARGET_FILE:mestra-cli>
      --dir ${CMAKE_CURRENT_SOURCE_DIR}/tests/hostile)
    set_tests_properties(hostile PROPERTIES TIMEOUT 600)
  endif()
endif()

install(TARGETS mestra mestra-cli
        RUNTIME DESTINATION bin
        LIBRARY DESTINATION lib
        ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)
