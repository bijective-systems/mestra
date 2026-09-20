// The two post-processing helpers this implementation carries
// (docs/api-conventions.md sections 3 and 4).  They are here because
// both of them are about things the format decides -- the weight array
// a support carries, and the label a support's values are grouped by --
// and not because this is an analysis library.  `time_series` and
// `grouped_split` are not provided in C++; cpp/README.md says so and
// says why.
#ifndef MESTRA_POST_HPP
#define MESTRA_POST_HPP

#include <cstddef>
#include <string>
#include <vector>

#include "mestra/dataset.hpp"

namespace mestra {

// What `integrate` may be told.
struct IntegrateOptions {
  // The weight array to use, by name.  Left empty, the rule of
  // conventions section 3 applies: the array of role `weight` at the
  // slot's location on its support, and failing that one computed on
  // the fly, which the result says it did.
  std::string weight;
};

// The integral of one slot over its support: the sum over nodes or
// cells of the value times the weight, one result per row and
// component.
struct Integral {
  std::vector<double> values;           // in the order `dims` names
  std::vector<std::string> dims;        // {"row", "component"}, or
                                        // {"component"} for a slot that
                                        // varies along nothing
  std::vector<std::size_t> shape;
  std::string units;                    // the slot's times the weight's
  std::string weight;                   // the array that was used
  // True when the file carried no weight array and one was computed
  // for this call.  The conventions ask the helper to say so; this is
  // how it says so, and `mestra-cli integrate` prints it.
  bool weight_recomputed = false;

  double at(std::size_t row, std::size_t component = 0) const;
  std::size_t rows() const;
  std::size_t components() const;
};

// Integrates `slot` over its support.  `slot` is the array's name, or
// its full path when two supports carry the same name; a name that
// two slots answer to is refused rather than guessed at.  A slot
// served by a callable is refused: evaluate the file first.
Integral integrate(const Dataset& d, const std::string& slot,
                   const IntegrateOptions& options = IntegrateOptions());

// Summary statistics of one slot, over every value it holds, either
// as a whole or grouped by a label array on the same support and at
// the same location.
//
// `by` is the label's name, and it is also what names the grouping
// column of the result: `group_by` carries that name and `groups`
// carries one entry per row of the table, which is the category
// table's entry when the label names one and the integer itself when
// it does not.  There is no grouping column at all when `by` is not
// given, which is the convention's "never a fixed word".
//
// A non-finite value is not a value: it is this format's spelling of
// missing floating-point data (W03), so it is counted in `missing`
// and left out of the rest.
struct FieldStatistics {
  std::string group_by;                 // the label's name; "" when none
  std::vector<std::string> groups;      // empty when not grouped
  std::vector<std::size_t> count;
  std::vector<std::size_t> missing;
  std::vector<double> minimum;
  std::vector<double> mean;
  std::vector<double> maximum;
  // The population standard deviation, over the `count` finite values
  // of the group.
  std::vector<double> deviation;
  std::string units;

  std::size_t size() const { return count.size(); }
};

FieldStatistics field_statistics(const Dataset& d, const std::string& slot,
                                 const std::string& by = std::string());

}  // namespace mestra

#endif  // MESTRA_POST_HPP
