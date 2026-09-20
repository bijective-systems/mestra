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
};

herr_t collect_scale(hid_t /*did*/, unsigned /*dim*/, hid_t dsid,
                     void* data) {
  ScaleVisit* visit = static_cast<ScaleVisit*>(data);
  char buffer[1024];
  const ssize_t n = H5Iget_name(dsid, buffer, sizeof(buffer));
  if (n > 0) {
    // The dimension's name is the scale dataset's HDF5 link name and
    // never its NAME attribute (section 21).
    visit->names->push_back(basename(std::string(buffer,
                                                 static_cast<std::size_t>(n))));
  } else {
    visit->names->push_back(std::string());
  }
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
  char buffer[128];
  std::snprintf(buffer, sizeof(buffer), "%s%10d",
                "This is a netCDF dimension but not a netCDF variable.",
                static_cast<int>(length));
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

bool File::exists(const std::string& path) const {
  if (path == "/") return true;
  // Every component must exist before H5Lexists may be asked about the
  // next one.
  std::size_t at = 1;
  while (at <= path.size()) {
    const std::size_t next = path.find('/', at);
    const std::string prefix =
        next == std::string::npos ? path : path.substr(0, next);
    if (H5Lexists(id_.get(), prefix.c_str(), H5P_DEFAULT) <= 0) return false;
    if (next == std::string::npos) break;
    at = next + 1;
  }
  return true;
}

bool File::is_group(const std::string& path) const {
  if (!exists(path)) return false;
  H5O_info2_t info;
  if (H5Oget_info_by_name3(id_.get(), path.c_str(), &info, H5O_INFO_BASIC,
                           H5P_DEFAULT) < 0) {
    return false;
  }
  return info.type == H5O_TYPE_GROUP;
}

bool File::is_dataset(const std::string& path) const {
  if (!exists(path)) return false;
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
    char buffer[1024];
    const ssize_t n = H5Lget_name_by_idx(group.get(), ".", H5_INDEX_NAME,
                                         H5_ITER_INC, i, buffer,
                                         sizeof(buffer), H5P_DEFAULT);
    if (n <= 0) continue;
    Member m;
    m.name = std::string(buffer, static_cast<std::size_t>(n));
    H5O_info2_t oinfo;
    if (H5Oget_info_by_name3(group.get(), m.name.c_str(), &oinfo,
                             H5O_INFO_BASIC, H5P_DEFAULT) >= 0) {
      m.is_group = oinfo.type == H5O_TYPE_GROUP;
      m.is_dataset = oinfo.type == H5O_TYPE_DATASET;
    }
    out.push_back(m);
  }
  return out;
}

std::vector<RawAttr> File::attributes(const std::string& path) const {
  std::vector<RawAttr> out;
  if (!exists(path)) return out;
  Id object = open_object(id_.get(), path);
  H5O_info2_t oinfo;
  if (H5Oget_info3(object.get(), &oinfo, H5O_INFO_NUM_ATTRS) < 0) return out;
  for (hsize_t i = 0; i < oinfo.num_attrs; ++i) {
    Id attr(H5Aopen_by_idx(object.get(), ".", H5_INDEX_NAME, H5_ITER_INC, i,
                           H5P_DEFAULT, H5P_DEFAULT));
    if (!attr.valid()) continue;
    char buffer[1024];
    const ssize_t len = H5Aget_name(attr.get(), sizeof(buffer), buffer);
    if (len <= 0) continue;
    RawAttr a;
    a.name = std::string(buffer, static_cast<std::size_t>(len));
    Id type(H5Aget_type(attr.get()));
    Id space(H5Aget_space(attr.get()));
    a.type = type_of(type.get(), space.get());

    if (a.type.klass == H5T_STRING) {
      if (a.type.variable_length) {
        char* value = nullptr;
        Id mem(H5Tcopy(H5T_C_S1));
        H5Tset_size(mem.get(), H5T_VARIABLE);
        H5Tset_cset(mem.get(), a.type.cset);
        if (H5Aread(attr.get(), mem.get(), &value) >= 0 && value) {
          a.raw_bytes = value;
          H5free_memory(value);
        }
      } else {
        std::string bytes(a.type.size * (a.type.points ? a.type.points : 1),
                          '\0');
        if (H5Aread(attr.get(), type.get(), &bytes[0]) >= 0) {
          a.raw_bytes = bytes;
        }
      }
      a.value = AttrValue::raw_text(strip_nul(a.raw_bytes));
    } else if (a.type.klass == H5T_INTEGER) {
      std::int64_t value = 0;
      if (H5Aread(attr.get(), H5T_NATIVE_INT64, &value) >= 0) {
        // Section 25: int8 means a boolean everywhere it appears, and
        // int64 means an integer.
        if (a.type.size == 1 && a.type.is_signed) {
          a.value = AttrValue::boolean(value != 0);
          a.raw_bytes = std::string(1, static_cast<char>(value & 0xff));
        } else {
          a.value = AttrValue::integer(value);
        }
      }
    } else if (a.type.klass == H5T_FLOAT) {
      double value = 0.0;
      if (H5Aread(attr.get(), H5T_NATIVE_DOUBLE, &value) >= 0) {
        a.value = AttrValue::real(value);
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
    unsigned flags = 0;
    std::size_t nelmts = 8;
    unsigned values[8];
    char name[256];
    unsigned config = 0;
    const H5Z_filter_t id =
        H5Pget_filter2(dcpl.get(), static_cast<unsigned>(i), &flags, &nelmts,
                       values, sizeof(name), name, &config);
    std::vector<unsigned> params(values, values + nelmts);
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
      ScaleVisit visit{&info.scales[static_cast<std::size_t>(axis)]};
      int index = 0;
      H5DSiterate_scales(dset.get(), static_cast<unsigned>(axis), &index,
                         collect_scale, &visit);
    }
  }
  return info;
}

namespace {

std::size_t product(const std::vector<hsize_t>& shape) {
  std::size_t n = 1;
  for (const hsize_t e : shape) n *= static_cast<std::size_t>(e);
  return shape.empty() ? 1 : n;
}

}  // namespace

std::vector<double> File::read_f64(const std::string& path) const {
  const DsetInfo info = dataset_info(path);
  std::vector<double> out(product(info.shape));
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
  std::vector<std::int64_t> out(product(info.shape));
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
  const std::size_t count = product(info.shape);
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
  std::vector<double> out(product(count));
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
  std::vector<std::int64_t> out(product(count));
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
