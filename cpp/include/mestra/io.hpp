// Reading and writing `.mes` files, and the lazy access SPEC.md
// section 29 requires of a reader.
#ifndef MESTRA_IO_HPP
#define MESTRA_IO_HPP

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "mestra/dataset.hpp"

namespace mestra {

// Every failure this library raises.  `rule` carries the identifier of
// section 14 when one applies, so that a caller can say which rule was
// broken and not only that something went wrong; it is empty when no
// rule covers the failure (a missing file, for example).
class Error : public std::runtime_error {
 public:
  Error(std::string rule, const std::string& message);
  const std::string& rule() const { return rule_; }

 private:
  std::string rule_;
};

// What `read` is allowed to accept.
struct ReadOptions {
  // Strict, which is the default, refuses a file that breaks a
  // structural rule -- E01, E16, E19, E25, E26, E29, E30, E40, E41 --
  // and a fault no rule of section 14 covers.  A semantic fault (a
  // missing unit, a split that straddles a generalisation unit) never
  // stops a read, so that `info` and a reader still work on the files
  // a user most needs to look at.
  //
  // `strict = false` reads what it can and lists what it refused in
  // `Dataset::not_read`.
  bool strict = true;
};

// Reads a whole file.  Throws Error carrying the first rule
// identifier, and every structural finding in its message, when a
// strict read meets one; and Error with the rule identifier for the
// layout faults it cannot read past whatever the options say.
//
// A read costs one validation pass over the file.  `read_header`,
// `read_slot` and `read_slot_rows` are the cheap paths and do not
// validate.
Dataset read(const std::string& path,
             const ReadOptions& options = ReadOptions());

// Opens a file and reports what section 29 asks for without reading an
// array: the row count, the keys with their roles and bounds, the
// supports with their ids, and every slot with its attributes and its
// shape, having read attributes and dataspaces only.  Nothing that is
// stored in a dataset comes back: array values, category table
// entries, cell arrays, /row_support and a callable's dictionary are
// all empty, and `Support::computed_support_id` is meaningless on the
// result.  Use `read` for a whole file.
Dataset read_header(const std::string& path);

// Lazy access.  Reads one slot for the half-open row range
// [row_begin, row_end) without reading any other slot and without
// reading the rows outside the range.  `slot` is the HDF5 path, for
// example "/supports/s0/node_arrays/pressure".  The array comes back
// with its dimension names, its leading axis cut to the range.
Array read_slot_rows(const std::string& path, const std::string& slot,
                     std::size_t row_begin, std::size_t row_end);

// Reads one whole dataset by its HDF5 path, with its dimension names.
// Works on a file that does not validate, which is what the
// conformance corpus needs.
Array read_slot(const std::string& path, const std::string& slot);

// What `write` is allowed to do.
struct WriteOptions {
  // Validate before leaving a file behind.  A dataset that breaks a
  // rule of section 14 is refused, with the findings, and `path` is
  // not touched: the file is built beside it and only moved into
  // place once it validates.  `check = false` writes it anyway, for
  // the one caller who wants a file the validator rejects -- a test
  // of a validator, mostly.  The shape checks a builder makes are not
  // part of this and are not skipped: `varies` disagreeing with the
  // shape a slot was built with is refused either way, because such a
  // file is not something a caller can have meant.
  bool check = true;
};

// Writes a conforming file.  Existing content at `path` is replaced.
// Throws Error carrying the first rule identifier, and every finding
// in its message, when the dataset does not validate.
void write(const Dataset& d, const std::string& path,
           const WriteOptions& options = WriteOptions());

// The digest of section 24 for one support of a file, computed from
// the stored arrays rather than read from the `support_id` attribute.
std::string support_id_of(const std::string& path,
                          const std::string& support);

// Reads one callable's dictionary.  Works without a registered type.
Dict read_dict(const std::string& path, const std::string& callable_id);

// Writes a dictionary into a file as the only callable, for a codec
// round trip.  The file is a minimal valid container.
void write_dict(const Dict& d, const std::string& type,
                const std::string& callable_id, const std::string& path);

}  // namespace mestra

#endif  // MESTRA_IO_HPP
