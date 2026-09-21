# The seven worked examples of docs/examples, built as programs so
# that they cannot rot.  The sources stay beside the README that gives
# their data and their expected output, one directory per concept, and
# only the target lives here.  Each binary is named after its
# directory and lands in build/examples, which is where
# tests/run_examples.py looks for it.
set(MESTRA_EXAMPLES
  a-support-and-a-field
  callables-and-evaluation
  groups-and-splits
  reading-someone-elses-file
  rows-and-roles
  uncertainty-as-draws
  validating
)

foreach(example IN LISTS MESTRA_EXAMPLES)
  add_executable(mestra-example-${example}
    ${CMAKE_CURRENT_SOURCE_DIR}/../../docs/examples/${example}/cpp.cpp)
  target_link_libraries(mestra-example-${example} PRIVATE mestra)
  target_compile_options(mestra-example-${example} PRIVATE
    ${MESTRA_WARNINGS} ${MESTRA_FP_FLAGS} ${MESTRA_SANITIZER_FLAGS})
  set_target_properties(mestra-example-${example} PROPERTIES
    OUTPUT_NAME ${example}
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/examples)
endforeach()
