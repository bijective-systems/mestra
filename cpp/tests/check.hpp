// A check harness small enough to read in one sitting.  There is no
// test framework here on purpose: the library's only dependency is
// HDF5 and its tests should not add one.
#ifndef MESTRA_TESTS_CHECK_HPP
#define MESTRA_TESTS_CHECK_HPP

#include <iostream>
#include <string>

namespace check {

inline int& failures() {
  static int n = 0;
  return n;
}

inline int& checks() {
  static int n = 0;
  return n;
}

inline void report(bool ok, const std::string& what, const std::string& got,
                   const std::string& want) {
  ++checks();
  if (ok) return;
  ++failures();
  std::cout << "FAIL " << what << "\n     got  " << got << "\n     want "
            << want << "\n";
}

template <typename A, typename B>
void equal(const std::string& what, const A& got, const B& want) {
  std::string got_text;
  std::string want_text;
  {
    std::ostringstream a;
    a << got;
    got_text = a.str();
    std::ostringstream b;
    b << want;
    want_text = b.str();
  }
  report(got_text == want_text, what, got_text, want_text);
}

inline void is_true(const std::string& what, bool ok) {
  report(ok, what, ok ? "true" : "false", "true");
}

inline int finish(const char* suite) {
  std::cout << suite << ": " << (checks() - failures()) << " of "
            << checks() << " checks passed\n";
  return failures() == 0 ? 0 : 1;
}

}  // namespace check

#endif  // MESTRA_TESTS_CHECK_HPP
