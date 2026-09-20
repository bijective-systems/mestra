#include "h5.hpp"

#include <hdf5_hl.h>

#include <cstdio>
#include <cstring>
#include <stdexcept>

#include "mestra/io.hpp"
#include "names.hpp"

namespace mestra {
namespace internal {
namespace {

// HDF5 prints its own error stack on any failure; this library
// reports failures through mestra::Error instead.
struct SilenceHdf5 {
  SilenceHdf5() { H5Eset_auto2(H5E_DEFAULT, nullptr, nullptr); }
};
const SilenceHdf5 kSilence;

void need(bool ok, const std::string& message) {
  if (!ok) throw Error("", message);
}

std::string parent_of(const std::string& path) {
  const std::size_t at = path.find_last_of('/');
  if (at == std::string::npos || at == 0) return "/";
  return path.substr(0, at);
}

Id open_object(hid_t file, const std::string& path) {
  Id id(H5Oopen(file, path.c_str(), H5P_DEFAULT));
  need(id.valid(), "cannot open \"" + path + "\"");
  return id;
}

struct ScaleVisit {
  std::vector<std::string>* names;
  const File* file;
};

// An object's token as a printable key, which is how two identifiers
// are told to be the same object without asking the library for a
// path it would have to search for.
std::string token_key(hid_t where, const H5O_token_t& token) {
  char* text = nullptr;
  if (H5Otoken_to_str(where, &token, &text) < 0 || text == nullptr) {
    return std::string();
  }
  std::string out(text);
  H5free_memory(text);
  return out;
}

herr_t collect_scale(hid_t /*did*/, unsigned /*dim*/, hid_t dsid,
                     void* data) {
  ScaleVisit* visit = static_cast<ScaleVisit*>(data);
  // The dimension's name is the scale dataset's HDF5 link name and
  // never its NAME attribute (section 21).  It is looked up by object
  // token; see File::dataset_link_name for why not by H5Iget_name.
  visit->names->push_back(visit->file->dataset_link_name(dsid));
  return 0;
}

AttrType type_of(hid_t type_id, hid_t space_id) {
  AttrType t;
  t.klass = H5Tget_class(type_id);
  t.size = H5Tget_size(type_id);
  if (t.klass == H5T_STRING) {
    t.variable_length = H5Tis_variable_str(type_id) > 0;
    t.cset = H5Tget_cset(type_id);
    t.strpad = H5Tget_strpad(type_id);
  } else if (t.klass == H5T_INTEGER) {
    t.is_signed = H5Tget_sign(type_id) == H5T_SGN_2;
    t.order = H5Tget_order(type_id);
  } else if (t.klass == H5T_FLOAT) {
    t.order = H5Tget_order(type_id);
  }
  if (space_id >= 0) {
    t.scalar_dataspace = H5Sget_simple_extent_type(space_id) == H5S_SCALAR;
    const hssize_t points = H5Sget_simple_extent_npoints(space_id);
    t.points = points > 0 ? static_cast<std::size_t>(points) : 0;
  }
  return t;
}

}  // namespace

void Id::close() {
  if (id_ >= 0) {
    H5Idec_ref(id_);
    id_ = H5I_INVALID_HID;
  }
}

std::string scale_name_attribute(hsize_t length) {
  // Section 21 gives the C format "%s%10d".  The conversion is done as
  // a long long so that a dimension longer than INT_MAX is printed
  // rather than converted out of range; for every length "%10d" can
  // represent the two produce the same 63 characters.
  char buffer[128];
  std::snprintf(buffer, sizeof(buffer), "%s%10lld",
                "This is a netCDF dimension but not a netCDF variable.",
                static_cast<long long>(length));
  return std::string(buffer);
}

Id string_type(std::size_t size) {
  Id t(H5Tcopy(H5T_C_S1));
  need(t.valid(), "cannot make a string type");
  H5Tset_size(t.get(), size == 0 ? 1 : size);
  H5Tset_strpad(t.get(), H5T_STR_NULLPAD);
  H5Tset_cset(t.get(), H5T_CSET_UTF8);
  return t;
}

bool is_spec_string(const AttrType& t) {
  return t.klass == H5T_STRING && !t.variable_length &&
         t.cset == H5T_CSET_UTF8 && t.strpad == H5T_STR_NULLPAD &&
         t.scalar_dataspace;
}

bool is_spec_int64(const AttrType& t) {
  return t.klass == H5T_INTEGER && t.size == 8 && t.is_signed &&
         t.order == H5T_ORDER_LE && t.scalar_dataspace;
}

bool is_spec_float64(const AttrType& t) {
  return t.klass == H5T_FLOAT && t.size == 8 && t.order == H5T_ORDER_LE &&
         t.scalar_dataspace;
}

bool is_spec_bool(const AttrType& t) {
  return t.klass == H5T_INTEGER && t.size == 1 && t.is_signed &&
         t.scalar_dataspace;
}

bool dtype_of(const AttrType& t, DType* out) {
  if (t.klass == H5T_STRING) {
    if (t.variable_length) return false;
    *out = DType::String;
    return true;
  }
  if (t.klass == H5T_FLOAT) {
    if (t.size != 8 || t.order != H5T_ORDER_LE) return false;
    *out = DType::Float64;
    return true;
  }
  if (t.klass == H5T_INTEGER) {
    if (t.size == 1) {
      *out = t.is_signed ? DType::Bool : DType::UInt8;
      return true;
    }
    if (t.order != H5T_ORDER_LE || !t.is_signed) return false;
    if (t.size == 4) {
      *out = DType::Int32;
      return true;
    }
    if (t.size == 8) {
      *out = DType::Int64;
      return true;
    }
  }
  return false;
}

// --- File ------------------------------------------------------------

File File::open_read(const std::string& path) {
  File f;
  f.id_ = Id(H5Fopen(path.c_str(), H5F_ACC_RDONLY, H5P_DEFAULT));
  if (!f.id_.valid()) {
    throw Error("", "cannot open \"" + path + "\" as an HDF5 file");
  }
  return f;
}

File File::create(const std::string& path) {
  File f;
  f.id_ = Id(H5Fcreate(path.c_str(), H5F_ACC_TRUNC, H5P_DEFAULT,
                       H5P_DEFAULT));
  if (!f.id_.valid()) {
    throw Error("", "cannot create \"" + path + "\"");
  }
  return f;
}

const char* link_kind_name(LinkKind kind) {
  switch (kind) {
    case LinkKind::Missing: return "missing";
    case LinkKind::Hard: return "a hard link";
    case LinkKind::Soft: return "a soft link";
    case LinkKind::External: return "an external link";
    case LinkKind::Other: return "a link of a kind this reader does not "
                                 "know";
  }
  return "a link";
}

LinkKind File::link_kind(const std::string& path) const {
  if (path == "/") return LinkKind::Hard;
  // Component by component, so that the walk stops at the first link
  // that is not hard and never asks the library about anything below
  // it.  Asking about a path under an external link is what would
  // open another file on the machine.
  std::size_t at = 1;
  LinkKind last = LinkKind::Hard;
  while (at <= path.size()) {
    const std::size_t next = path.find('/', at);
    const std::string prefix =
        next == std::string::npos ? path : path.substr(0, next);
    H5L_info2_t info;
    if (H5Lget_info2(id_.get(), prefix.c_str(), &info, H5P_DEFAULT) < 0) {
      return LinkKind::Missing;
    }
    switch (info.type) {
      case H5L_TYPE_HARD: last = LinkKind::Hard; break;
      case H5L_TYPE_SOFT: last = LinkKind::Soft; break;
      case H5L_TYPE_EXTERNAL: last = LinkKind::External; break;
      default: last = LinkKind::Other; break;
    }
    if (next == std::string::npos) break;
    if (last != LinkKind::Hard) return last;
    at = next + 1;
  }
  return last;
}

bool File::exists(const std::string& path) const {
  return link_kind(path) != LinkKind::Missing;
}

bool File::is_group(const std::string& path) const {
  if (link_kind(path) != LinkKind::Hard) return false;
  H5O_info2_t info;
  if (H5Oget_info_by_name3(id_.get(), path.c_str(), &info, H5O_INFO_BASIC,
                           H5P_DEFAULT) < 0) {
    return false;
  }
  return info.type == H5O_TYPE_GROUP;
}

bool File::is_dataset(const std::string& path) const {
  if (link_kind(path) != LinkKind::Hard) return false;
  H5O_info2_t info;
  if (H5Oget_info_by_name3(id_.get(), path.c_str(), &info, H5O_INFO_BASIC,
                           H5P_DEFAULT) < 0) {
    return false;
  }
  return info.type == H5O_TYPE_DATASET;
}

std::vector<Member> File::members(const std::string& path) const {
  std::vector<Member> out;
  if (!is_group(path)) return out;
  Id group(H5Gopen2(id_.get(), path.c_str(), H5P_DEFAULT));
  need(group.valid(), "cannot open the group \"" + path + "\"");
  H5G_info_t info;
  if (H5Gget_info(group.get(), &info) < 0) return out;
  for (hsize_t i = 0; i < info.nlinks; ++i) {
    const ssize_t n = H5Lget_name_by_idx(group.get(), ".", H5_INDEX_NAME,
                                         H5_ITER_INC, i, nullptr, 0,
                                         H5P_DEFAULT);
    if (n <= 0) continue;
    std::string name(static_cast<std::size_t>(n) + 1, '\0');
    if (H5Lget_name_by_idx(group.get(), ".", H5_INDEX_NAME, H5_ITER_INC, i,
                           &name[0], name.size(), H5P_DEFAULT) < 0) {
      continue;
    }
    name.resize(static_cast<std::size_t>(n));
    Member m;
    m.name = name;
    // The link's own type first: a soft link is not resolved and an
    // external link is not opened, so neither can make this reader
    // touch anything the caller did not name.
    H5L_info2_t linfo;
    if (H5Lget_info_by_idx2(group.get(), ".", H5_INDEX_NAME, H5_ITER_INC, i,
                            &linfo, H5P_DEFAULT) < 0) {
      m.kind = LinkKind::Missing;
      out.push_back(m);
      continue;
    }
    switch (linfo.type) {
      case H5L_TYPE_HARD: m.kind = LinkKind::Hard; break;
      case H5L_TYPE_SOFT: m.kind = LinkKind::Soft; break;
      case H5L_TYPE_EXTERNAL: m.kind = LinkKind::External; break;
      default: m.kind = LinkKind::Other; break;
    }
    if (m.kind == LinkKind::Hard) {
      H5O_info2_t oinfo;
      if (H5Oget_info_by_name3(group.get(), m.name.c_str(), &oinfo,
                               H5O_INFO_BASIC, H5P_DEFAULT) >= 0) {
        m.is_group = oinfo.type == H5O_TYPE_GROUP;
        m.is_dataset = oinfo.type == H5O_TYPE_DATASET;
      }
    }
    out.push_back(m);
  }
  return out;
}

std::vector<RawAttr> File::attributes(const std::string& path) const {
  std::vector<RawAttr> out;
  if (link_kind(path) != LinkKind::Hard) return out;
  Id object = open_object(id_.get(), path);
  H5O_info2_t oinfo;
  if (H5Oget_info3(object.get(), &oinfo, H5O_INFO_NUM_ATTRS) < 0) return out;
  for (hsize_t i = 0; i < oinfo.num_attrs; ++i) {
    Id attr(H5Aopen_by_idx(object.get(), ".", H5_INDEX_NAME, H5_ITER_INC, i,
                           H5P_DEFAULT, H5P_DEFAULT));
    if (!attr.valid()) continue;
    const ssize_t len = H5Aget_name(attr.get(), 0, nullptr);
    if (len <= 0) continue;
    std::string attr_name(static_cast<std::size_t>(len) + 1, '\0');
    if (H5Aget_name(attr.get(), attr_name.size(), &attr_name[0]) < 0) {
      continue;
    }
    attr_name.resize(static_cast<std::size_t>(len));
    RawAttr a;
    a.name = attr_name;
    Id type(H5Aget_type(attr.get()));
    Id space(H5Aget_space(attr.get()));
    a.type = type_of(type.get(), space.get());

    // H5Aread fills as many elements as the attribute's dataspace
    // declares, and that count is in the file.  Every buffer below is
    // sized from it; nothing here reads into a single scalar slot on
    // the strength of the encoding section 18 asks for, because a
    // crafted file names an encoding and stores four thousand of them.
    const std::size_t points = a.type.points;
    const bool readable = points >= 1 && points <= kMaxAttributeElements;
    if (points > kMaxAttributeElements) {
      // Left unread and unvalued.  The validator reports the
      // dataspace (E19 for an attribute section 18 names) and a
      // reader carries nothing it could not read.
      a.too_large = true;
    }

    if (a.type.klass == H5T_STRING && readable) {
      if (a.type.variable_length) {
        std::vector<char*> values(points, nullptr);
        Id mem(H5Tcopy(H5T_C_S1));
        H5Tset_size(mem.get(), H5T_VARIABLE);
        H5Tset_cset(mem.get(), a.type.cset);
        if (H5Aread(attr.get(), mem.get(), values.data()) >= 0) {
          if (values[0] != nullptr) a.raw_bytes = values[0];
        }
        // Every element the library allocated is freed, not just the
        // one whose value is kept.
        for (char* p : values) {
          if (p != nullptr) H5free_memory(p);
        }
      } else {
        if (a.type.size > 0 && points > kMaxAttributeBytes / a.type.size) {
          a.too_large = true;
        } else {
          std::string bytes(a.type.size * points, '\0');
          if (!bytes.empty() &&
              H5Aread(attr.get(), type.get(), &bytes[0]) >= 0) {
            // Only the first element is a value this format has a
            // place for; the rest are read so that the library writes
            // inside the buffer and are then dropped.
            a.raw_bytes = bytes.substr(0, a.type.size);
          }
        }
      }
      a.value = AttrValue::raw_text(strip_nul(a.raw_bytes));
    } else if (a.type.klass == H5T_INTEGER && readable) {
      std::vector<std::int64_t> values(points, 0);
      if (H5Aread(attr.get(), H5T_NATIVE_INT64, values.data()) >= 0) {
        // Section 25: int8 means a boolean everywhere it appears, and
        // int64 means an integer.
        if (a.type.size == 1 && a.type.is_signed) {
          a.value = AttrValue::boolean(values[0] != 0);
          a.raw_bytes = std::string(1, static_cast<char>(values[0] & 0xff));
        } else {
          a.value = AttrValue::integer(values[0]);
        }
      }
    } else if (a.type.klass == H5T_FLOAT && readable) {
      std::vector<double> values(points, 0.0);
      if (H5Aread(attr.get(), H5T_NATIVE_DOUBLE, values.data()) >= 0) {
        a.value = AttrValue::real(values[0]);
      }
    }
    out.push_back(a);
  }
  return out;
}

DsetInfo File::dataset_info(const std::string& path) const {
  DsetInfo info;
  if (!is_dataset(path)) return info;
  info.is_dataset = true;
  Id dset(H5Dopen2(id_.get(), path.c_str(), H5P_DEFAULT));
  need(dset.valid(), "cannot open the dataset \"" + path + "\"");
  Id type(H5Dget_type(dset.get()));
  Id space(H5Dget_space(dset.get()));
  info.type = type_of(type.get(), space.get());
  const int rank = H5Sget_simple_extent_ndims(space.get());
  if (rank > 0) {
    info.shape.resize(static_cast<std::size_t>(rank));
    info.maxshape.resize(static_cast<std::size_t>(rank));
    H5Sget_simple_extent_dims(space.get(), info.shape.data(),
                              info.maxshape.data());
  }
  Id dcpl(H5Dget_create_plist(dset.get()));
  const H5D_layout_t layout = H5Pget_layout(dcpl.get());
  info.chunked = layout == H5D_CHUNKED;
  info.contiguous = layout == H5D_CONTIGUOUS;
  if (info.chunked && rank > 0) {
    info.chunk.resize(static_cast<std::size_t>(rank));
    H5Pget_chunk(dcpl.get(), rank, info.chunk.data());
  }
  const int filters = H5Pget_nfilters(dcpl.get());
  for (int i = 0; i < filters; ++i) {
    // cd_nelmts is in and out: on return it is the number of values
    // the filter defines, which may be more than the buffer held.
    // Asking with no buffer first is what keeps a file-chosen count
    // from sizing a read out of a fixed array.
    unsigned flags = 0;
    unsigned config = 0;
    std::size_t count = 0;
    if (H5Pget_filter2(dcpl.get(), static_cast<unsigned>(i), &flags, &count,
                       nullptr, 0, nullptr, &config) < 0) {
      continue;
    }
    if (count > kMaxFilterParameters) count = kMaxFilterParameters;
    std::vector<unsigned> params(count, 0u);
    std::size_t given = count;
    const H5Z_filter_t id = H5Pget_filter2(
        dcpl.get(), static_cast<unsigned>(i), &flags, &given,
        params.empty() ? nullptr : params.data(), 0, nullptr, &config);
    if (id < 0) continue;
    if (given < params.size()) params.resize(given);
    info.filters.emplace_back(static_cast<int>(id), params);
  }
  H5D_fill_value_t fill = H5D_FILL_VALUE_DEFAULT;
  if (H5Pfill_value_defined(dcpl.get(), &fill) >= 0) {
    info.has_fill_value_set = fill == H5D_FILL_VALUE_USER_DEFINED;
  }

  info.is_scale = H5DSis_scale(dset.get()) > 0;
  info.scales.resize(static_cast<std::size_t>(rank > 0 ? rank : 0));
  if (!info.is_scale) {
    for (int axis = 0; axis < rank; ++axis) {
      ScaleVisit visit{&info.scales[static_cast<std::size_t>(axis)], this};
      int index = 0;
      H5DSiterate_scales(dset.get(), static_cast<unsigned>(axis), &index,
                         collect_scale, &visit);
    }
  }
  return info;
}

namespace {

// The extents come out of the file, so the product is built with an
// overflow check at every step and refused past a stated maximum.
// Without it a crafted shape wraps to a small number and the buffer
// that follows is far too small for the read.
std::size_t checked_product(const std::string& path,
                            const std::vector<hsize_t>& shape,
                            std::size_t limit) {
  if (shape.empty()) return 1;
  std::size_t n = 1;
  for (const hsize_t raw : shape) {
    const std::size_t e = static_cast<std::size_t>(raw);
    if (e != 0 && n > limit / e) {
      throw Error("", "\"" + path + "\" declares more elements than this "
                                     "reader will read");
    }
    n *= e;
  }
  if (n > limit) {
    throw Error("", "\"" + path + "\" declares more elements than this "
                                   "reader will read");
  }
  return n;
}

}  // namespace

std::vector<double> File::read_f64(const std::string& path) const {
  const DsetInfo info = dataset_info(path);
  std::vector<double> out(
      checked_product(path, info.shape, kMaxDatasetElements));
  if (out.empty()) return out;
  Id dset(H5Dopen2(id_.get(), path.c_str(), H5P_DEFAULT));
  need(dset.valid(), "cannot open \"" + path + "\"");
  need(H5Dread(dset.get(), H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT,
               out.data()) >= 0,
       "cannot read \"" + path + "\"");
  return out;
}

std::vector<std::int64_t> File::read_i64(const std::string& path) const {
  const DsetInfo info = dataset_info(path);
  std::vector<std::int64_t> out(
      checked_product(path, info.shape, kMaxDatasetElements));
  if (out.empty()) return out;
  Id dset(H5Dopen2(id_.get(), path.c_str(), H5P_DEFAULT));
  need(dset.valid(), "cannot open \"" + path + "\"");
  need(H5Dread(dset.get(), H5T_NATIVE_INT64, H5S_ALL, H5S_ALL, H5P_DEFAULT,
               out.data()) >= 0,
       "cannot read \"" + path + "\"");
  return out;
}

std::vector<std::string> File::read_strings_raw(
    const std::string& path) const {
  const DsetInfo info = dataset_info(path);
  const std::size_t count =
      checked_product(path, info.shape, kMaxDatasetElements);
  std::vector<std::string> out;
  if (count == 0) return out;
  Id dset(H5Dopen2(id_.get(), path.c_str(), H5P_DEFAULT));
  need(dset.valid(), "cannot open \"" + path + "\"");
  Id type(H5Dget_type(dset.get()));
  if (info.type.variable_length) {
    std::vector<char*> raw(count, nullptr);
    Id mem(H5Tcopy(H5T_C_S1));
    H5Tset_size(mem.get(), H5T_VARIABLE);
    H5Tset_cset(mem.get(), info.type.cset);
    need(H5Dread(dset.get(), mem.get(), H5S_ALL, H5S_ALL, H5P_DEFAULT,
                 raw.data()) >= 0,
         "cannot read \"" + path + "\"");
    for (char* p : raw) {
      out.push_back(p ? std::string(p) : std::string());
      if (p) H5free_memory(p);
    }
    return out;
  }
  const std::size_t item = info.type.size;
  // Both factors come out of the file, so the product is checked
  // before it sizes the buffer the library then writes into.
  if (item != 0 && count > kMaxDatasetBytes / item) {
    throw Error("", "\"" + path + "\" declares more bytes than this reader "
                                   "will read");
  }
  std::string buffer(item * count, '\0');
  need(H5Dread(dset.get(), type.get(), H5S_ALL, H5S_ALL, H5P_DEFAULT,
               &buffer[0]) >= 0,
       "cannot read \"" + path + "\"");
  for (std::size_t i = 0; i < count; ++i) {
    out.push_back(buffer.substr(i * item, item));
  }
  return out;
}

std::vector<std::string> File::read_strings(const std::string& path) const {
  std::vector<std::string> out = read_strings_raw(path);
  for (std::string& s : out) s = strip_nul(s);
  return out;
}

namespace {

void select_rows(hid_t space, const std::vector<hsize_t>& shape,
                 std::size_t begin, std::size_t end,
                 std::vector<hsize_t>* count) {
  std::vector<hsize_t> start(shape.size(), 0);
  *count = shape;
  start[0] = begin;
  (*count)[0] = static_cast<hsize_t>(end - begin);
  H5Sselect_hyperslab(space, H5S_SELECT_SET, start.data(), nullptr,
                      count->data(), nullptr);
}

}  // namespace

std::vector<double> File::read_f64_rows(const std::string& path,
                                        std::size_t begin,
                                        std::size_t end) const {
  const DsetInfo info = dataset_info(path);
  need(info.is_dataset && !info.shape.empty(),
       "\"" + path + "\" has no rows to read");
  if (end > static_cast<std::size_t>(info.shape[0])) {
    throw Error("", "row range outside \"" + path + "\"");
  }
  if (end <= begin) return {};
  Id dset(H5Dopen2(id_.get(), path.c_str(), H5P_DEFAULT));
  Id space(H5Dget_space(dset.get()));
  std::vector<hsize_t> count;
  select_rows(space.get(), info.shape, begin, end, &count);
  Id mem(H5Screate_simple(static_cast<int>(count.size()), count.data(),
                          nullptr));
  std::vector<double> out(
      checked_product(path, count, kMaxDatasetElements));
  need(H5Dread(dset.get(), H5T_NATIVE_DOUBLE, mem.get(), space.get(),
               H5P_DEFAULT, out.data()) >= 0,
       "cannot read rows of \"" + path + "\"");
  return out;
}

std::vector<std::int64_t> File::read_i64_rows(const std::string& path,
                                              std::size_t begin,
                                              std::size_t end) const {
  const DsetInfo info = dataset_info(path);
  need(info.is_dataset && !info.shape.empty(),
       "\"" + path + "\" has no rows to read");
  if (end > static_cast<std::size_t>(info.shape[0])) {
    throw Error("", "row range outside \"" + path + "\"");
  }
  if (end <= begin) return {};
  Id dset(H5Dopen2(id_.get(), path.c_str(), H5P_DEFAULT));
  Id space(H5Dget_space(dset.get()));
  std::vector<hsize_t> count;
  select_rows(space.get(), info.shape, begin, end, &count);
  Id mem(H5Screate_simple(static_cast<int>(count.size()), count.data(),
                          nullptr));
  std::vector<std::int64_t> out(
      checked_product(path, count, kMaxDatasetElements));
  need(H5Dread(dset.get(), H5T_NATIVE_INT64, mem.get(), space.get(),
               H5P_DEFAULT, out.data()) >= 0,
       "cannot read rows of \"" + path + "\"");
  return out;
}

// --- writing ---------------------------------------------------------

void File::make_group(const std::string& path) {
  if (path == "/" || exists(path)) return;
  make_group(parent_of(path));
  Id group(H5Gcreate2(id_.get(), path.c_str(), H5P_DEFAULT, H5P_DEFAULT,
                      H5P_DEFAULT));
  need(group.valid(), "cannot create the group \"" + path + "\"");
}

void File::write_raw_string_attr(const std::string& path,
                                 const std::string& name,
                                 const std::string& bytes) {
  Id object = open_object(id_.get(), path);
  const std::size_t size = bytes.empty() ? 1 : bytes.size();
  Id type = string_type(size);
  Id space(H5Screate(H5S_SCALAR));
  Id attr(H5Acreate2(object.get(), name.c_str(), type.get(), space.get(),
                     H5P_DEFAULT, H5P_DEFAULT));
  need(attr.valid(), "cannot create the attribute \"" + name + "\"");
  std::string padded = bytes;
  padded.resize(size, '\0');
  need(H5Awrite(attr.get(), type.get(), padded.data()) >= 0,
       "cannot write the attribute \"" + name + "\"");
}

void File::write_attr(const std::string& path, const std::string& name,
                      const AttrValue& value) {
  switch (value.kind()) {
    case AttrValue::Kind::Str:
      write_raw_string_attr(path, name, value.as_text());
      return;
    case AttrValue::Kind::Bool: {
      Id object = open_object(id_.get(), path);
      Id space(H5Screate(H5S_SCALAR));
      Id attr(H5Acreate2(object.get(), name.c_str(), H5T_STD_I8LE,
                         space.get(), H5P_DEFAULT, H5P_DEFAULT));
      need(attr.valid(), "cannot create the attribute \"" + name + "\"");
      const signed char v = value.as_bool() ? 1 : 0;
      H5Awrite(attr.get(), H5T_NATIVE_SCHAR, &v);
      return;
    }
    case AttrValue::Kind::Int: {
      Id object = open_object(id_.get(), path);
      Id space(H5Screate(H5S_SCALAR));
      Id attr(H5Acreate2(object.get(), name.c_str(), H5T_STD_I64LE,
                         space.get(), H5P_DEFAULT, H5P_DEFAULT));
      need(attr.valid(), "cannot create the attribute \"" + name + "\"");
      const std::int64_t v = value.as_int();
      H5Awrite(attr.get(), H5T_NATIVE_INT64, &v);
      return;
    }
    case AttrValue::Kind::Float: {
      Id object = open_object(id_.get(), path);
      Id space(H5Screate(H5S_SCALAR));
      Id attr(H5Acreate2(object.get(), name.c_str(), H5T_IEEE_F64LE,
                         space.get(), H5P_DEFAULT, H5P_DEFAULT));
      need(attr.valid(), "cannot create the attribute \"" + name + "\"");
      const double v = value.as_float();
      H5Awrite(attr.get(), H5T_NATIVE_DOUBLE, &v);
      return;
    }
  }
}

namespace {

Id make_dcpl(const std::vector<hsize_t>& chunk) {
  Id dcpl(H5Pcreate(H5P_DATASET_CREATE));
  // Section 30: object time tracking off, so that two runs of a writer
  // produce identical bytes.
  H5Pset_obj_track_times(dcpl.get(), 0);
  if (!chunk.empty()) {
    H5Pset_chunk(dcpl.get(), static_cast<int>(chunk.size()), chunk.data());
    // Section 23 forbids setting a fill value and this sets none.  The
    // fill *time* is a different property, which the format does not
    // mention; ALLOC on a chunked dataset and the library default on a
    // contiguous one is what the HDF5 wrappers this format
    // interoperates with write, so two writers agree byte for byte and
    // not only structurally.
    H5Pset_fill_time(dcpl.get(), H5D_FILL_TIME_ALLOC);
  }
  return dcpl;
}

// H5Dwrite reads as many elements as the dataspace declares, so a
// caller that hands over fewer than the shape says would have it read
// past the end of the vector.  Every write goes through here first.
void need_elements(const std::string& path,
                   const std::vector<hsize_t>& shape, std::size_t given) {
  const std::size_t want =
      checked_product(path, shape, kMaxDatasetElements);
  if (given != want) {
    throw Error("", "\"" + path + "\" declares " + std::to_string(want) +
                        " elements and was given " + std::to_string(given));
  }
}

Id make_space(const std::vector<hsize_t>& shape,
              const std::vector<hsize_t>& maxshape) {
  if (shape.empty()) return Id(H5Screate(H5S_SCALAR));
  const hsize_t* max = maxshape.empty() ? nullptr : maxshape.data();
  return Id(H5Screate_simple(static_cast<int>(shape.size()), shape.data(),
                             max));
}

}  // namespace

void File::write_f64(const std::string& path,
                     const std::vector<hsize_t>& shape,
                     const std::vector<hsize_t>& maxshape,
                     const std::vector<hsize_t>& chunk,
                     const std::vector<double>& data) {
  need_elements(path, shape, data.size());
  make_group(parent_of(path));
  Id space = make_space(shape, maxshape);
  Id dcpl = make_dcpl(chunk);
  Id dset(H5Dcreate2(id_.get(), path.c_str(), H5T_IEEE_F64LE, space.get(),
                     H5P_DEFAULT, dcpl.get(), H5P_DEFAULT));
  need(dset.valid(), "cannot create the dataset \"" + path + "\"");
  if (!data.empty()) {
    need(H5Dwrite(dset.get(), H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL,
                  H5P_DEFAULT, data.data()) >= 0,
         "cannot write \"" + path + "\"");
  }
}

void File::write_ints(const std::string& path, DType dtype,
                      const std::vector<hsize_t>& shape,
                      const std::vector<hsize_t>& maxshape,
                      const std::vector<hsize_t>& chunk,
                      const std::vector<std::int64_t>& data) {
  need_elements(path, shape, data.size());
  make_group(parent_of(path));
  hid_t file_type = H5T_STD_I64LE;
  switch (dtype) {
    case DType::Bool: file_type = H5T_STD_I8LE; break;
    case DType::UInt8: file_type = H5T_STD_U8LE; break;
    case DType::Int32: file_type = H5T_STD_I32LE; break;
    default: file_type = H5T_STD_I64LE; break;
  }
  Id space = make_space(shape, maxshape);
  Id dcpl = make_dcpl(chunk);
  Id dset(H5Dcreate2(id_.get(), path.c_str(), file_type, space.get(),
                     H5P_DEFAULT, dcpl.get(), H5P_DEFAULT));
  need(dset.valid(), "cannot create the dataset \"" + path + "\"");
  if (!data.empty()) {
    need(H5Dwrite(dset.get(), H5T_NATIVE_INT64, H5S_ALL, H5S_ALL,
                  H5P_DEFAULT, data.data()) >= 0,
         "cannot write \"" + path + "\"");
  }
}

void File::write_strings(const std::string& path, std::size_t item_size,
                         const std::vector<hsize_t>& shape,
                         const std::vector<hsize_t>& maxshape,
                         const std::vector<hsize_t>& chunk,
                         const std::vector<std::string>& data) {
  need_elements(path, shape, data.size());
  make_group(parent_of(path));
  const std::size_t item = item_size == 0 ? 1 : item_size;
  Id type = string_type(item);
  Id space = make_space(shape, maxshape);
  Id dcpl = make_dcpl(chunk);
  Id dset(H5Dcreate2(id_.get(), path.c_str(), type.get(), space.get(),
                     H5P_DEFAULT, dcpl.get(), H5P_DEFAULT));
  need(dset.valid(), "cannot create the dataset \"" + path + "\"");
  if (!data.empty()) {
    std::string buffer(item * data.size(), '\0');
    for (std::size_t i = 0; i < data.size(); ++i) {
      const std::size_t n = data[i].size() < item ? data[i].size() : item;
      std::memcpy(&buffer[i * item], data[i].data(), n);
    }
    need(H5Dwrite(dset.get(), type.get(), H5S_ALL, H5S_ALL, H5P_DEFAULT,
                  buffer.data()) >= 0,
         "cannot write \"" + path + "\"");
  }
}

void File::build_object_index() const {
  object_index_built_ = true;
  // One walk, bounded in depth and in count, recording every dataset's
  // token against its link name.  Iterative, so a file that nests
  // groups deeply costs stack here as well as inside the library.
  std::vector<std::pair<std::string, int>> todo;
  todo.emplace_back("/", 0);
  while (!todo.empty()) {
    const std::pair<std::string, int> here = todo.back();
    todo.pop_back();
    if (here.second > kMaxGroupDepth) continue;
    if (object_names_.size() >= kMaxIndexedObjects) return;
    for (const Member& m : members(here.first)) {
      if (m.kind != LinkKind::Hard) continue;
      const std::string child =
          (here.first == "/" ? std::string("/") : here.first + "/") + m.name;
      if (m.is_group) {
        todo.emplace_back(child, here.second + 1);
        continue;
      }
      if (!m.is_dataset) continue;
      H5O_info2_t info;
      if (H5Oget_info_by_name3(id_.get(), child.c_str(), &info,
                               H5O_INFO_BASIC, H5P_DEFAULT) < 0) {
        continue;
      }
      const std::string key = token_key(id_.get(), info.token);
      if (!key.empty()) object_names_[key] = m.name;
      if (object_names_.size() >= kMaxIndexedObjects) return;
    }
  }
}

std::string File::dataset_link_name(hid_t object) const {
  if (!object_index_built_) build_object_index();
  H5O_info2_t info;
  if (H5Oget_info3(object, &info, H5O_INFO_BASIC) < 0) return std::string();
  const std::string key = token_key(id_.get(), info.token);
  if (key.empty()) return std::string();
  const auto it = object_names_.find(key);
  return it == object_names_.end() ? std::string() : it->second;
}

void File::make_scale(const std::string& path, hsize_t length,
                      bool unlimited, const std::vector<hsize_t>& chunk) {
  make_group(parent_of(path));
  // Section 21: one-dimensional H5T_IEEE_F32BE, no value ever written,
  // chunked with chunk length 1 when unlimited and contiguous
  // otherwise.
  const hsize_t max = unlimited ? H5S_UNLIMITED : length;
  Id space(H5Screate_simple(1, &length, &max));
  Id dcpl(H5Pcreate(H5P_DATASET_CREATE));
  H5Pset_obj_track_times(dcpl.get(), 0);
  if (!chunk.empty()) {
    H5Pset_chunk(dcpl.get(), 1, chunk.data());
    H5Pset_fill_time(dcpl.get(), H5D_FILL_TIME_ALLOC);
  } else if (unlimited) {
    const hsize_t one = 1;
    H5Pset_chunk(dcpl.get(), 1, &one);
    H5Pset_fill_time(dcpl.get(), H5D_FILL_TIME_ALLOC);
  }
  Id dset(H5Dcreate2(id_.get(), path.c_str(), H5T_IEEE_F32BE, space.get(),
                     H5P_DEFAULT, dcpl.get(), H5P_DEFAULT));
  need(dset.valid(), "cannot create the dimension scale \"" + path + "\"");
  const std::string name = scale_name_attribute(length);
  need(H5DSset_scale(dset.get(), name.c_str()) >= 0,
       "cannot mark \"" + path + "\" as a dimension scale");
}

void File::attach_scale(const std::string& dataset, const std::string& scale,
                        unsigned axis) {
  Id d(H5Dopen2(id_.get(), dataset.c_str(), H5P_DEFAULT));
  need(d.valid(), "cannot open \"" + dataset + "\"");
  Id s(H5Dopen2(id_.get(), scale.c_str(), H5P_DEFAULT));
  need(s.valid(), "cannot open the dimension scale \"" + scale + "\"");
  need(H5DSattach_scale(d.get(), s.get(), axis) >= 0,
       "cannot attach \"" + scale + "\" to \"" + dataset + "\"");
}

}  // namespace internal
}  // namespace mestra
