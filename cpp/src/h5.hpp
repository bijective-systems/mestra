// A thin RAII layer over the HDF5 C API and hdf5_hl, so that the
// reader, the writer and the validator all see the file the same way.
// Internal; not installed.
#ifndef MESTRA_SRC_H5_HPP
#define MESTRA_SRC_H5_HPP

#include <hdf5.h>

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "mestra/dataset.hpp"
#include "mestra/value.hpp"

namespace mestra {
namespace internal {

// An HDF5 identifier that closes itself.
class Id {
 public:
  Id() : id_(H5I_INVALID_HID) {}
  explicit Id(hid_t id) : id_(id) {}
  Id(const Id&) = delete;
  Id& operator=(const Id&) = delete;
  Id(Id&& o) noexcept : id_(o.id_) { o.id_ = H5I_INVALID_HID; }
  Id& operator=(Id&& o) noexcept {
    if (this != &o) {
      close();
      id_ = o.id_;
      o.id_ = H5I_INVALID_HID;
    }
    return *this;
  }
  ~Id() { close(); }

  hid_t get() const { return id_; }
  bool valid() const { return id_ >= 0; }
  void close();
  hid_t release() {
    const hid_t id = id_;
    id_ = H5I_INVALID_HID;
    return id;
  }

 private:
  hid_t id_;
};

// Every count and length below comes out of the file, so each one is
// checked against a limit before it sizes a buffer.  These are far
// past anything this format needs and far short of anything that
// would exhaust memory on a machine that can open the file at all.
const std::size_t kMaxAttributeElements = 1u << 20;     // 1,048,576
const std::size_t kMaxAttributeBytes = std::size_t(1) << 30;   // 1 GiB
// Section 29: an eager read refuses a dataset whose
// declared element count is above a stated maximum, and 2^31 is the
// default to state.  A lazy read and a row-range read are not subject
// to it, because they never materialise the whole dataset.
const std::size_t kMaxDatasetElements = std::size_t(1) << 31;
const std::size_t kMaxFilterParameters = 1024;
// How many objects the dimension-scale index below will hold.
const std::size_t kMaxIndexedObjects = 1u << 20;
// An opaque group (section 12's /private) is copied whole, so what it
// costs is what it holds.  Both are stated here rather than left to
// whatever the machine allows.
const std::size_t kMaxOpaqueObjects = 1u << 16;                // 65,536
const std::size_t kMaxOpaqueBytes = std::size_t(1) << 30;      // 1 GiB
const std::size_t kMaxDatasetBytes = std::size_t(1) << 33;     // 8 GiB
// How deep any walk of the file's own group tree goes before it stops
// and says so.  A stack overflow cannot be caught, so every recursive
// walk over file-controlled structure is bounded first.
const int kMaxGroupDepth = 64;

// What the file says an attribute's HDF5 type is, before this format
// decides whether that is the encoding section 18 requires.
struct AttrType {
  H5T_class_t klass = H5T_NO_CLASS;
  std::size_t size = 0;          // bytes
  bool variable_length = false;  // a variable-length string
  H5T_cset_t cset = H5T_CSET_ASCII;
  H5T_str_t strpad = H5T_STR_NULLPAD;
  bool is_signed = true;
  H5T_order_t order = H5T_ORDER_LE;
  bool scalar_dataspace = true;
  std::size_t points = 1;
};

// One attribute exactly as stored.
struct RawAttr {
  std::string name;
  AttrType type;
  AttrValue value;        // the decoded value, best effort
  std::string raw_bytes;  // a string attribute's stored bytes
  // True when the attribute declares more elements than this build
  // will read.  Nothing was read and `value` is meaningless; the
  // validator reports it and a reader carries nothing.
  bool too_large = false;
};

// The stored shape of a dataset, without reading any element.
struct DsetInfo {
  bool is_dataset = false;
  AttrType type;
  std::vector<hsize_t> shape;
  std::vector<hsize_t> maxshape;
  bool chunked = false;
  std::vector<hsize_t> chunk;
  bool contiguous = false;
  // Filters, as (id, parameters).  gzip is H5Z_FILTER_DEFLATE and
  // shuffle is H5Z_FILTER_SHUFFLE.
  std::vector<std::pair<int, std::vector<unsigned>>> filters;
  // The creation-order properties of section 21, read back off the
  // dataset creation property list.  A dimension scale must have both
  // (E42); no other object in this format says anything about them.
  bool attr_order_tracked = false;
  bool attr_order_indexed = false;
  bool is_scale = false;                   // CLASS = DIMENSION_SCALE
  // For each axis, the link names of the dimension scales attached.
  std::vector<std::vector<std::string>> scales;
  // The same attachments by path, which is what an opaque copy needs
  // to remake them in another file; `scales` is what a dimension name
  // comes from (section 21).
  std::vector<std::vector<std::string>> scale_paths;
  bool has_fill_value_set = false;
};

// How a name is linked to what it names.  The format says nothing
// about links, and a file is untrusted input, so this library follows
// a hard link and nothing else: a soft link is not resolved and an
// external link is never opened, because opening one would make a
// crafted file read another file on the machine.
enum class LinkKind { Missing, Hard, Soft, External, Other };

const char* link_kind_name(LinkKind kind);

// A member of a group.  `kind` is read from the link itself, without
// resolving it; `is_group` and `is_dataset` are false for anything
// but a hard link.
struct Member {
  std::string name;
  LinkKind kind = LinkKind::Missing;
  bool is_group = false;
  bool is_dataset = false;
};

// One open file.
class File {
 public:
  static File open_read(const std::string& path);
  static File create(const std::string& path);

  hid_t get() const { return id_.get(); }

  // The link kind of the last component of `path`, without following
  // anything: the walk stops at the first component that is not a
  // hard link and returns that kind, so nothing below a soft or
  // external link is ever asked about.
  LinkKind link_kind(const std::string& path) const;

  bool exists(const std::string& path) const;
  bool is_group(const std::string& path) const;
  bool is_dataset(const std::string& path) const;
  std::vector<Member> members(const std::string& path) const;

  std::vector<RawAttr> attributes(const std::string& path) const;
  DsetInfo dataset_info(const std::string& path) const;

  // The element count the file declares for a dataset, refused with
  // E41 when it is past the maximum an eager read of this reader
  // takes.  It reads the dataspace and no element, so a metadata open
  // decides that refusal the same way a read does (section 29).
  std::size_t eager_element_count(const std::string& path) const;

  // Whole-dataset reads, converted to the vector the caller asks for.
  std::vector<double> read_f64(const std::string& path) const;
  std::vector<std::int64_t> read_i64(const std::string& path) const;
  // Fixed-length strings, with the trailing NUL padding stripped.
  std::vector<std::string> read_strings(const std::string& path) const;
  // The same, with the stored bytes kept, padding and all.
  std::vector<std::string> read_strings_raw(const std::string& path) const;

  // A hyperslab along the leading axis: rows [begin, end).
  std::vector<double> read_f64_rows(const std::string& path,
                                    std::size_t begin,
                                    std::size_t end) const;
  std::vector<std::int64_t> read_i64_rows(const std::string& path,
                                          std::size_t begin,
                                          std::size_t end) const;

  // --- writing -------------------------------------------------------
  void make_group(const std::string& path);
  void write_attr(const std::string& path, const std::string& name,
                  const AttrValue& value);
  // A string attribute written from raw bytes, for the null sentinel.
  void write_raw_string_attr(const std::string& path,
                             const std::string& name,
                             const std::string& bytes);

  // `maxshape` empty means the same as `shape`; `chunk` empty means
  // contiguous.  Every dataset is written with object time tracking
  // off (section 30).  `filters` is the pipeline of section 23, in
  // order; empty is no compression.  HDF5 filters a chunked dataset
  // only, so a caller that asks for one gives a chunk as well.
  void write_f64(const std::string& path,
                 const std::vector<hsize_t>& shape,
                 const std::vector<hsize_t>& maxshape,
                 const std::vector<hsize_t>& chunk,
                 const std::vector<double>& data,
                 const FilterPipeline& filters = {});
  void write_ints(const std::string& path, DType dtype,
                  const std::vector<hsize_t>& shape,
                  const std::vector<hsize_t>& maxshape,
                  const std::vector<hsize_t>& chunk,
                  const std::vector<std::int64_t>& data,
                  const FilterPipeline& filters = {});
  void write_strings(const std::string& path, std::size_t item_size,
                     const std::vector<hsize_t>& shape,
                     const std::vector<hsize_t>& maxshape,
                     const std::vector<hsize_t>& chunk,
                     const std::vector<std::string>& data,
                     const FilterPipeline& filters = {});

  // A dimension scale written as netCDF-C writes one (section 21).
  // `chunk` empty means the rule of sections 21 and 23: chunk length 1
  // when the scale is unlimited and contiguous when it is not.  A
  // reader that found something else passes it here so that a round
  // trip reproduces the file.
  void make_scale(const std::string& path, hsize_t length, bool unlimited,
                  const std::vector<hsize_t>& chunk = {});

  // The link name of the dataset an open identifier refers to, from an
  // index this file builds once.
  //
  // H5Iget_name would answer the same question, but an object the
  // library opened by dereferencing a reference -- which is how the
  // dimension-scale machinery hands a scale to a visitor -- has no
  // path recorded, so H5Iget_name makes HDF5 search the group tree for
  // it, recursively and over the whole file.  On a file that nests
  // groups deeply that search overflows the stack inside the library,
  // where nothing this code does can catch it.  The index is built by
  // one walk, bounded in depth and in count, and answers by object
  // token instead.
  std::string dataset_link_name(hid_t object) const;
  // The same index, answering with the whole path rather than the last
  // component, which is what remaking an attachment in another file
  // needs.
  std::string dataset_path(hid_t object) const;
  void attach_scale(const std::string& dataset, const std::string& scale,
                    unsigned axis);

 private:
  void build_object_index() const;

  Id id_;
  // Object token to the object's path, built by one bounded walk.
  mutable std::map<std::string, std::string> object_paths_;
  mutable bool object_index_built_ = false;
};

// Copies `path` and everything under it out of `f` without looking
// into any of it: the result carries an HDF5 file image made by the
// library's own object copy, and the dimension-scale attachments that
// copy does not reproduce.  Throws E41 when the group is deeper, has
// more objects, or holds more bytes than the stated maxima above.
OpaqueGroup capture_group(const File& f, const std::string& path);

// Puts one back at `path` in a file being written, and remakes every
// attachment whose dataset and scale both landed in the new file.
void restore_group(File& f, const std::string& path, const OpaqueGroup& g);

// The 53-character sentence of section 21, followed by the length in
// ten columns.
std::string scale_name_attribute(hsize_t length);

// The filters of section 23 a dataset carries, in pipeline order.  A
// filter this format does not allow is left out rather than carried:
// the validator reports it (E29), a strict read refuses the file, and
// a writer never puts one back.
FilterPipeline pipeline_of(const DsetInfo& info);

// A fixed-length UTF-8 NUL-padded string type of `size` bytes.
Id string_type(std::size_t size);

// True when the type is the encoding section 18 requires.
bool is_spec_string(const AttrType& t);
bool is_spec_int64(const AttrType& t);
bool is_spec_float64(const AttrType& t);
bool is_spec_bool(const AttrType& t);

// The dtype of a dataset, mapped onto this format's DType.  Returns
// false when the stored type is not one the format allows anywhere.
bool dtype_of(const AttrType& t, DType* out);

}  // namespace internal
}  // namespace mestra

#endif  // MESTRA_SRC_H5_HPP
