# The seven worked examples of docs/examples, built as programs so
# that they cannot rot.  The sources stay beside the README that gives
# their data and their expected output, one directory per concept, and
# only the target lives here.  Each binary is named after its
# directory and lands under build/examples; tests/run_examples.py is
# handed each one by path, through MESTRA_EXAMPLE_BINARIES, because a
# multi-configuration generator adds a directory of its own below
# that and the test must not have to know which.
set(MESTRA_EXAMPLES
  a-support-and-a-field
  callables-and-evaluation
  groups-and-splits
  reading-someone-elses-file
  rows-and-roles
  uncertainty-as-draws
  validating
)

set(MESTRA_EXAMPLE_BINARIES "")
foreach(example IN LISTS MESTRA_EXAMPLES)
  add_executable(mestra-example-${example}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../docs/examples/${example}/cpp.cpp)
  target_link_libraries(mestra-example-${example} PRIVATE mestra)
  target_compile_options(mestra-example-${example} PRIVATE
    ${MESTRA_WARNINGS} ${MESTRA_FP_FLAGS} ${MESTRA_SANITIZER_FLAGS})
  set_target_properties(mestra-example-${example} PROPERTIES
    OUTPUT_NAME ${example}
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/examples)
  list(APPEND MESTRA_EXAMPLE_BINARIES
       $<TARGET_FILE:mestra-example-${example}>)
endforeach()
set(MESTRA_EXAMPLE_BINARIES "${MESTRA_EXAMPLE_BINARIES}" PARENT_SCOPE)
