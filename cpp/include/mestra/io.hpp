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

// Reads a whole file.  Throws Error("E01", ...) for a major version
// this reader does not accept, and Error with the rule identifier for
// the layout faults it cannot read past.  It does not validate: run
// `mestra::validate` for that.
Dataset read(const std::string& path);

// Opens a file and reports what section 29 asks for without reading an
// array: the row count, the keys with their roles and bounds, the
// supports with their ids, and every slot with its attributes.  Array
// data is left empty.
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

// Writes a conforming file.  Existing content at `path` is replaced.
void write(const Dataset& d, const std::string& path);

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
