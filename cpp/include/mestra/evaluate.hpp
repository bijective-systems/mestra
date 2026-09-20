// Evaluating a file that holds callables (SPEC.md sections 10 and 22).
#ifndef MESTRA_EVALUATE_HPP
#define MESTRA_EVALUATE_HPP

#include "mestra/callable.hpp"
#include "mestra/dataset.hpp"

namespace mestra {

// Evaluates every callable slot of `d` on `keys` and returns a dataset
// with the same slots, now holding data: the row count becomes the
// number of table rows, the key columns hold the table, and every slot
// whose `source` was "callable:<id>" becomes stored data with
// `source` = "data".  Slots that already held data are carried over
// unchanged when the row count matches and dropped otherwise, which
// the caller is told about through Error.
//
// Throws Error("E14", ...) when a slot names a callable the file does
// not hold, and Error without a rule when no factory is registered for
// a callable's type.
Dataset evaluate(const Dataset& d, const KeysTable& keys);

// The keys table a file declares, with no rows: the key names in the
// file's key order (section 26) and empty columns, ready to be filled.
KeysTable empty_keys_table(const Dataset& d);

// Reads a keys table from a comma-separated file whose first line is
// the column names.  Used by `mestra-cli evaluate`; a column whose key
// has role `id` is read as text and every other column as float64.
KeysTable read_keys_csv(const Dataset& d, const std::string& path);

}  // namespace mestra

#endif  // MESTRA_EVALUATE_HPP
