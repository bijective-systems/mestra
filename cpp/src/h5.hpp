// A thin RAII layer over the HDF5 C API and hdf5_hl, so that the
// reader, the writer and the validator all see the file the same way.
// Internal; not installed.
#ifndef MESTRA_SRC_H5_HPP
#define MESTRA_SRC_H5_HPP

#include <hdf5.h>

#include <cstdint>
#include <string>
#include <vector>

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
  bool is_scale = false;                   // CLASS = DIMENSION_SCALE
  // For each axis, the link names of the dimension scales attached.
  std::vector<std::vector<std::string>> scales;
  bool has_fill_value_set = false;
};

// A member of a group.
struct Member {
  std::string name;
  bool is_group = false;
  bool is_dataset = false;
};

// One open file.
class File {
 public:
  static File open_read(const std::string& path);
  static File create(const std::string& path);

  hid_t get() const { return id_.get(); }

  bool exists(const std::string& path) const;
  bool is_group(const std::string& path) const;
  bool is_dataset(const std::string& path) const;
  std::vector<Member> members(const std::string& path) const;

  std::vector<RawAttr> attributes(const std::string& path) const;
  DsetInfo dataset_info(const std::string& path) const;

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
  // off (section 30).
  void write_f64(const std::string& path,
                 const std::vector<hsize_t>& shape,
                 const std::vector<hsize_t>& maxshape,
                 const std::vector<hsize_t>& chunk,
                 const std::vector<double>& data);
  void write_ints(const std::string& path, DType dtype,
                  const std::vector<hsize_t>& shape,
                  const std::vector<hsize_t>& maxshape,
                  const std::vector<hsize_t>& chunk,
                  const std::vector<std::int64_t>& data);
  void write_strings(const std::string& path, std::size_t item_size,
                     const std::vector<hsize_t>& shape,
                     const std::vector<hsize_t>& maxshape,
                     const std::vector<hsize_t>& chunk,
                     const std::vector<std::string>& data);

  // A dimension scale written as netCDF-C writes one (section 21).
  // `chunk` empty means the rule of sections 21 and 23: chunk length 1
  // when the scale is unlimited and contiguous when it is not.  A
  // reader that found something else passes it here so that a round
  // trip reproduces the file.
  void make_scale(const std::string& path, hsize_t length, bool unlimited,
                  const std::vector<hsize_t>& chunk = {});
  void attach_scale(const std::string& dataset, const std::string& scale,
                    unsigned axis);

 private:
  Id id_;
};

// The 53-character sentence of section 21, followed by the length in
// ten columns.
std::string scale_name_attribute(hsize_t length);

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
