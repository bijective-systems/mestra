// The validator of SPEC.md section 14.  Every finding carries the rule
// identifier and nothing else identifies it: the identifiers are
// stable within a major version, a rule is never renumbered, and a
// retired identifier (E07, W09) is never emitted.
#ifndef MESTRA_VALIDATE_HPP
#define MESTRA_VALIDATE_HPP

#include <string>
#include <vector>

namespace mestra {

// One rule broken, at one place.
struct Finding {
  std::string id;       // "E16", "W08", ...
  std::string where;    // the HDF5 path the finding is about
  std::string message;  // one line, plain language
};

struct Report {
  std::vector<Finding> errors;
  std::vector<Finding> warnings;

  bool ok() const { return errors.empty(); }
  // The identifiers, sorted and without duplicates, which is the form
  // the conformance corpus compares (section 30).
  std::vector<std::string> error_ids() const;
  std::vector<std::string> warning_ids() const;
};

// Validates a file.  Never throws for a fault in the file: a file this
// reader cannot open at all comes back as E01 or E17 with a message.
Report validate(const std::string& path);

// The units parser W10 is driven by: true when the string is in the
// UDUNITS grammar this version accepts.  It covers what the format
// needs -- identifiers with exponents, products, quotients and
// parentheses -- and is deliberately not a units database.
bool units_parse(const std::string& units);

}  // namespace mestra

#endif  // MESTRA_VALIDATE_HPP
