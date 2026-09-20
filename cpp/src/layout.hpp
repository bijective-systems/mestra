// Facts about the layout that the reader, the writer and the validator
// must agree on: the names dimensions have on disk, which attributes
// each object may carry, and which container groups exist.  Internal.
#ifndef MESTRA_SRC_LAYOUT_HPP
#define MESTRA_SRC_LAYOUT_HPP

#include <cstddef>
#include <string>
#include <vector>

#include "mestra/dataset.hpp"

namespace mestra {
namespace internal {

// Section 21, "logical name to name on disk", read backwards: the
// logical dimension name of a scale whose link name is `disk`.
std::string logical_dim(const std::string& disk);

// The number of rows that reference support `index`, in an unaligned
// file.  In an aligned file this is the file's row count.
std::size_t rows_on_support(const Dataset& d, std::size_t index);

// True when the support needs a support-local `row` dimension scale:
// the file is unaligned and the support carries an array with
// `varies = row` (section 21).
bool needs_local_row(const Dataset& d, const Support& s);

// The distinct component-axis lengths, draw-axis lengths and group
// keys a file's root dimension scales must cover.
std::vector<std::size_t> component_lengths(const Dataset& d);
std::vector<std::size_t> draw_lengths(const Dataset& d);

// The attributes each kind of object may carry.  Anything else is a
// thing this version does not know: ignored and reported (W11).
bool known_root_attribute(const std::string& name);
bool known_key_attribute(const std::string& name);
bool known_scalar_attribute(const std::string& name);
bool known_support_attribute(const std::string& name);
bool known_array_attribute(const std::string& name);
bool known_callable_attribute(const std::string& name);

// The groups a version 0 reader knows at the root and inside a
// support.
bool known_root_group(const std::string& name);
bool known_support_group(const std::string& name);

// True when a root-level dataset name is one of the dimension scales
// section 21 puts there.
bool root_scale_name(const std::string& name);

}  // namespace internal
}  // namespace mestra

#endif  // MESTRA_SRC_LAYOUT_HPP
