// The dictionary codec of SPEC.md sections 17 and 25, on disk.
// Internal; the public entry points are in mestra/io.hpp.
#ifndef MESTRA_SRC_CODEC_HPP
#define MESTRA_SRC_CODEC_HPP

#include <map>
#include <string>
#include <vector>

#include "h5.hpp"
#include "mestra/value.hpp"

namespace mestra {
namespace internal {

// The attributes the HDF5 dimension scale machinery and netCDF-C write,
// which section 18 says a reader must ignore wherever they appear.
bool machinery_attribute(const std::string& name);

// Reads the dictionary stored on the group `path`.  At the top level
// `type` and `repr` are the container's attributes and not dictionary
// entries, so they are skipped; nested dictionaries may use both names
// freely.
Dict read_dict_group(const File& f, const std::string& path,
                     bool top_level);

// The storage a reader found for a dataset or a dimension scale, by
// HDF5 path, so that a round trip reproduces the file it came from.
using ChunkOverrides = std::map<std::string, std::vector<std::size_t>>;

// Writes `d` into the group `path`, which must already exist.  Keys are
// visited in ascending order of their UTF-8 bytes (section 25).
void write_dict_group(File& f, const std::string& path, const Dict& d,
                      const ChunkOverrides* chunks = nullptr);

}  // namespace internal
}  // namespace mestra

#endif  // MESTRA_SRC_CODEC_HPP
