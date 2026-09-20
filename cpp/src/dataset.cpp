#include "mestra/dataset.hpp"

#include <algorithm>
#include <cstring>

#include "mestra/io.hpp"
#include "mestra/sha256.hpp"
#include "names.hpp"

namespace mestra {
namespace {

void put_i64_le(Sha256& h, std::int64_t v) {
  unsigned char bytes[8];
  std::uint64_t u = static_cast<std::uint64_t>(v);
  for (int i = 0; i < 8; ++i) {
    bytes[i] = static_cast<unsigned char>((u >> (8 * i)) & 0xffu);
  }
  h.update(bytes, 8);
}

void put_f64_le(Sha256& h, double v) {
  // IEEE 754 float64, little-endian, which is what every platform this
  // builds on stores natively; the bytes are taken through memcpy so
  // that no strict-aliasing rule is bent.
  unsigned char bytes[8];
  std::memcpy(bytes, &v, 8);
  h.update(bytes, 8);
}

}  // namespace

// --- small value types ----------------------------------------------

std::size_t Key::rows() const {
  switch (dtype) {
    case DType::Float64: return f64.size();
    case DType::String: return str.size();
    default: return i64.size();
  }
}

bool Scalar::is_callable() const {
  return !internal::callable_of_source(source).empty();
}

std::string Scalar::callable_id() const {
  return internal::callable_of_source(source);
}

bool ArraySlot::is_callable() const {
  return !internal::callable_of_source(source).empty();
}

std::string ArraySlot::callable_id() const {
  return internal::callable_of_source(source);
}

int CategoryTable::index_of(const std::string& entry) const {
  for (std::size_t i = 0; i < entries.size(); ++i) {
    if (entries[i] == entry) return static_cast<int>(i);
  }
  return -1;
}

// --- support_id ------------------------------------------------------

std::string support_id_digest(
    std::int64_t n_nodes, const std::vector<std::uint8_t>& cell_types,
    const std::vector<std::int64_t>& cell_offsets,
    const std::vector<std::int64_t>& connectivity,
    const std::vector<double>* axis_coordinates) {
  Sha256 h;
  put_i64_le(h, n_nodes);
  if (!cell_types.empty()) h.update(cell_types.data(), cell_types.size());
  for (const std::int64_t v : cell_offsets) put_i64_le(h, v);
  for (const std::int64_t v : connectivity) put_i64_le(h, v);
  if (axis_coordinates != nullptr) {
    for (const double v : *axis_coordinates) put_f64_le(h, v);
  }
  return h.hex();
}

std::string Support::computed_support_id() const {
  // Section 24: "a support of kind `axis` or `none` has no cell
  // arrays, so steps 2 to 4 contribute no bytes at all for it".  The
  // kind decides, not what the file happens to carry, so a file that
  // wrongly puts cell arrays on an axis support breaks E38 and not
  // E08 as well.
  static const std::vector<std::uint8_t> kNoTypes;
  static const std::vector<std::int64_t> kNoInts;
  const bool has_cells = kind != "axis" && kind != "none";
  if (kind == "axis" && coordinates.has_value()) {
    return support_id_digest(n_nodes, kNoTypes, kNoInts, kNoInts,
                             &coordinates->data.f64);
  }
  if (!has_cells) {
    return support_id_digest(n_nodes, kNoTypes, kNoInts, kNoInts, nullptr);
  }
  return support_id_digest(n_nodes, cell_types, cell_offsets,
                           cell_connectivity, nullptr);
}

int cell_type_nodes(std::uint8_t code) {
  switch (code) {
    case 1: return 1;    // vertex
    case 3: return 2;    // line
    case 5: return 3;    // triangle
    case 7: return 0;    // polygon: three or more
    case 9: return 4;    // quadrilateral
    case 10: return 4;   // tetrahedron
    case 12: return 8;   // hexahedron
    case 13: return 6;   // wedge
    case 14: return 5;   // pyramid
    case 21: return 3;   // quadratic line
    case 22: return 6;   // quadratic triangle
    case 23: return 8;   // quadratic quadrilateral
    case 24: return 10;  // quadratic tetrahedron
    case 25: return 20;  // quadratic hexahedron
    case 26: return 15;  // quadratic wedge
    case 27: return 13;  // quadratic pyramid
    default: return -1;
  }
}

std::size_t default_chunk_rows(std::size_t item_bytes,
                               const std::vector<std::size_t>& other_extents,
                               std::size_t row_count) {
  if (row_count == 0) return 1;
  std::size_t b = item_bytes;
  for (const std::size_t e : other_extents) b *= (e == 0 ? 1 : e);
  if (b == 0) b = 1;
  std::size_t c = 1048576 / b;
  if (c < 1) c = 1;
  if (c > row_count) c = row_count;
  return c;
}

// --- Dataset lookup --------------------------------------------------

const Key* Dataset::key(const std::string& name) const {
  for (const Key& k : keys) {
    if (k.name == name) return &k;
  }
  return nullptr;
}

const Scalar* Dataset::scalar(const std::string& name) const {
  for (const Scalar& s : scalars) {
    if (s.name == name) return &s;
  }
  return nullptr;
}

const Support* Dataset::support(const std::string& name) const {
  for (const Support& s : supports) {
    if (s.name == name) return &s;
  }
  return nullptr;
}

Key* Dataset::key(const std::string& name) {
  return const_cast<Key*>(static_cast<const Dataset*>(this)->key(name));
}

Scalar* Dataset::scalar(const std::string& name) {
  return const_cast<Scalar*>(static_cast<const Dataset*>(this)->scalar(name));
}

Support* Dataset::support(const std::string& name) {
  return const_cast<Support*>(
      static_cast<const Dataset*>(this)->support(name));
}

const CategoryTable* Dataset::category(const std::string& name) const {
  for (const CategoryTable& c : categories) {
    if (c.name == name) return &c;
  }
  return nullptr;
}

const StoredCallable* Dataset::callable(const std::string& id) const {
  for (const StoredCallable& c : callables) {
    if (c.id == id) return &c;
  }
  return nullptr;
}

const Support* Dataset::support_of_row(std::size_t row) const {
  if (supports.empty()) return nullptr;
  if (!row_support.has_value()) return &supports.front();
  if (row >= row_support->size()) return nullptr;
  const std::int32_t at = (*row_support)[row];
  if (at < 0 || static_cast<std::size_t>(at) >= supports.size()) {
    return nullptr;
  }
  return &supports[static_cast<std::size_t>(at)];
}

std::vector<std::string> Dataset::key_order() const {
  std::vector<std::string> names;
  names.reserve(keys.size());
  for (const Key& k : keys) names.push_back(k.name);
  std::sort(names.begin(), names.end(), bytes_less);
  return names;
}

// --- Dataset building ------------------------------------------------

namespace {

template <typename T>
T& insert_sorted(std::vector<T>& into, T value) {
  auto at = std::lower_bound(
      into.begin(), into.end(), value,
      [](const T& a, const T& b) { return bytes_less(a.name, b.name); });
  return *into.insert(at, std::move(value));
}

}  // namespace

Key& Dataset::add_key(const std::string& name, const std::string& role,
                      std::vector<double> values,
                      const std::string& units) {
  Key k;
  k.name = name;
  k.role = role;
  k.units = units;
  k.dtype = DType::Float64;
  k.f64 = std::move(values);
  if (n_rows == 0) n_rows = static_cast<std::int64_t>(k.f64.size());
  container_groups.insert("/keys");
  return insert_sorted(keys, std::move(k));
}

Key& Dataset::add_category_key(const std::string& name,
                               const std::string& role,
                               std::vector<std::int64_t> ids,
                               const std::string& category_table,
                               DType dtype) {
  Key k;
  k.name = name;
  k.role = role;
  k.category = category_table;
  k.dtype = dtype;
  k.i64 = std::move(ids);
  if (n_rows == 0) n_rows = static_cast<std::int64_t>(k.i64.size());
  container_groups.insert("/keys");
  return insert_sorted(keys, std::move(k));
}

Scalar& Dataset::add_scalar(const std::string& name,
                            const std::string& units,
                            std::vector<double> values) {
  Scalar s;
  s.name = name;
  s.units = units;
  s.source = "data";
  s.values = std::move(values);
  if (n_rows == 0) n_rows = static_cast<std::int64_t>(s.values.size());
  container_groups.insert("/scalars");
  return insert_sorted(scalars, std::move(s));
}

CategoryTable& Dataset::add_categories(const std::string& name,
                                       std::vector<std::string> entries) {
  CategoryTable c;
  c.name = name;
  c.entries = std::move(entries);
  container_groups.insert("/categories");
  return insert_sorted(categories, std::move(c));
}

Support& Dataset::add_mesh_support(
    const std::string& name, std::int64_t n_nodes,
    std::vector<std::uint8_t> cell_types,
    std::vector<std::int64_t> cell_offsets,
    std::vector<std::int64_t> connectivity) {
  Support s;
  s.name = name;
  s.kind = "mesh";
  s.n_nodes = n_nodes;
  s.n_cells = static_cast<std::int64_t>(cell_types.size());
  s.cell_types = std::move(cell_types);
  s.cell_offsets = std::move(cell_offsets);
  s.cell_connectivity = std::move(connectivity);
  s.support_id = s.computed_support_id();
  container_groups.insert("/supports");
  Support& ref = insert_sorted(supports, std::move(s));
  aligned = supports.size() <= 1;
  return ref;
}

Support& Dataset::add_axis_support(const std::string& name,
                                   const std::vector<double>& coordinates,
                                   const std::string& units) {
  Support s;
  s.name = name;
  s.kind = "axis";
  s.n_nodes = static_cast<std::int64_t>(coordinates.size());
  s.n_cells = 0;
  container_groups.insert("/supports");
  Support& ref = insert_sorted(supports, std::move(s));
  set_coordinates(ref, coordinates, 1, units, "none");
  ref.support_id = ref.computed_support_id();
  aligned = supports.size() <= 1;
  return ref;
}

Support& Dataset::add_none_support(const std::string& name) {
  Support s;
  s.name = name;
  s.kind = "none";
  s.n_nodes = 0;
  s.n_cells = 0;
  s.support_id = s.computed_support_id();
  container_groups.insert("/supports");
  Support& ref = insert_sorted(supports, std::move(s));
  aligned = supports.size() <= 1;
  return ref;
}

StoredCallable& Dataset::add_callable(const std::string& id,
                                      const std::string& type, Dict dict) {
  StoredCallable c;
  c.id = id;
  c.type = type;
  c.dict = std::move(dict);
  container_groups.insert("/callables");
  auto at = std::lower_bound(callables.begin(), callables.end(), c,
                             [](const StoredCallable& a,
                                const StoredCallable& b) {
                               return bytes_less(a.id, b.id);
                             });
  return *callables.insert(at, std::move(c));
}

// --- support helpers -------------------------------------------------

namespace {

// The dimension names of an array slot, in stored order.
std::vector<std::string> slot_dims(const std::string& varies,
                                   bool has_draw, Location where) {
  std::vector<std::string> dims;
  if (varies == "row") {
    dims.push_back("row");
  } else if (varies.compare(0, 6, "group:") == 0) {
    dims.push_back(varies);
  }
  if (has_draw) dims.push_back("draw");
  dims.push_back(where == Location::Node ? "node" : "cell");
  dims.push_back("component");
  return dims;
}

// How many instances the leading dimension holds, from the length of
// the values the caller handed over.  Deriving it rather than asking
// for it is what keeps a builder from writing a shape the validator
// then rejects (E04, E16, E34).
std::size_t leading_extent(std::size_t values, std::size_t per_instance) {
  if (per_instance == 0) return 0;
  return values / per_instance;
}

ArraySlot& add_slot(Support& s, Location where, ArraySlot slot) {
  std::vector<ArraySlot>& into =
      where == Location::Node ? s.node_arrays : s.cell_arrays;
  auto at = std::lower_bound(
      into.begin(), into.end(), slot,
      [](const ArraySlot& a, const ArraySlot& b) {
        return bytes_less(a.name, b.name);
      });
  return *into.insert(at, std::move(slot));
}

}  // namespace

void set_coordinates(Support& s, const std::vector<double>& values,
                     std::int64_t components, const std::string& units,
                     const std::string& varies) {
  ArraySlot c;
  c.name = "coordinates";
  c.role = "coordinates";
  c.varies = varies;
  c.units = units;
  c.components = components;
  c.source = "data";
  c.location = Location::Node;
  c.data.dtype = DType::Float64;
  c.data.dims = slot_dims(varies, false, Location::Node);
  if (varies != "none") {
    c.data.shape.push_back(leading_extent(
        values.size(), static_cast<std::size_t>(s.n_nodes * components)));
  }
  c.data.shape.push_back(static_cast<std::size_t>(s.n_nodes));
  c.data.shape.push_back(static_cast<std::size_t>(components));
  c.data.f64 = values;
  s.coordinates = std::move(c);
}

ArraySlot& add_field(Support& s, Location where, const std::string& name,
                     const std::string& units,
                     const std::vector<double>& values,
                     std::int64_t components, const std::string& varies) {
  ArraySlot a;
  a.name = name;
  a.role = "field";
  a.varies = varies;
  a.units = units;
  a.components = components;
  a.source = "data";
  a.location = where;
  a.data.dtype = DType::Float64;
  const std::int64_t extent =
      where == Location::Node ? s.n_nodes : s.n_cells;
  a.data.dims = slot_dims(varies, false, where);
  if (varies != "none") {
    a.data.shape.push_back(leading_extent(
        values.size(), static_cast<std::size_t>(extent * components)));
  }
  a.data.shape.push_back(static_cast<std::size_t>(extent));
  a.data.shape.push_back(static_cast<std::size_t>(components));
  a.data.f64 = values;
  return add_slot(s, where, std::move(a));
}

ArraySlot& add_label(Support& s, Location where, const std::string& name,
                     const std::vector<std::int64_t>& values,
                     std::optional<std::string> category, DType dtype,
                     const std::string& varies) {
  ArraySlot a;
  a.name = name;
  a.role = "label";
  a.varies = varies;
  a.components = 1;
  a.source = "data";
  a.category = std::move(category);
  a.location = where;
  a.data.dtype = dtype;
  const std::int64_t extent =
      where == Location::Node ? s.n_nodes : s.n_cells;
  a.data.dims = slot_dims(varies, false, where);
  if (varies != "none") {
    a.data.shape.push_back(
        leading_extent(values.size(), static_cast<std::size_t>(extent)));
  }
  a.data.shape.push_back(static_cast<std::size_t>(extent));
  a.data.shape.push_back(1);
  a.data.i64 = values;
  return add_slot(s, where, std::move(a));
}

ArraySlot& add_callable_field(Support& s, Location where,
                              const std::string& name,
                              const std::string& units,
                              std::int64_t components,
                              const std::string& callable_id,
                              const std::string& output,
                              const std::string& varies) {
  ArraySlot a;
  a.name = name;
  a.role = "field";
  a.varies = varies;
  a.units = units;
  a.components = components;
  a.source = "callable:" + callable_id;
  a.output = output;
  a.location = where;
  return add_slot(s, where, std::move(a));
}

Scalar& add_callable_scalar(Dataset& d, const std::string& name,
                            const std::string& units,
                            const std::string& callable_id,
                            const std::string& output) {
  Scalar s;
  s.name = name;
  s.units = units;
  s.source = "callable:" + callable_id;
  s.output = output;
  d.container_groups.insert("/scalars");
  auto at = std::lower_bound(
      d.scalars.begin(), d.scalars.end(), s,
      [](const Scalar& a, const Scalar& b) {
        return bytes_less(a.name, b.name);
      });
  return *d.scalars.insert(at, std::move(s));
}

}  // namespace mestra
