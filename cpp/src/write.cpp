#include <algorithm>
#include <map>
#include <set>

#include "codec.hpp"
#include "h5.hpp"
#include "layout.hpp"
#include "mestra/io.hpp"
#include "mestra/mestra.hpp"
#include "names.hpp"

namespace mestra {
namespace {

using internal::File;

// The order in which links, attributes and scale attachments are
// created is fixed here and nowhere else, because HDF5 stores the
// links of a small group in creation order and section 30 asks a
// writer to be byte reproducible.  Reordering the statements below
// changes the bytes of every file this writer produces.
class Writer {
 public:
  Writer(const Dataset& d, File& f) : d_(d), f_(f) {}

  void run() {
    root_attributes();
    root_scales();
    categories();
    keys();
    scalars();
    row_support();
    supports();
    callables();
    trailing_groups();
  }

 private:
  // --- helpers ------------------------------------------------------

  std::size_t rows() const { return static_cast<std::size_t>(d_.n_rows); }

  void put(const std::string& path, const std::string& name,
           const std::string& value) {
    f_.write_attr(path, name, AttrValue::text(value));
  }
  void put_int(const std::string& path, const std::string& name,
               std::int64_t value) {
    f_.write_attr(path, name, AttrValue::integer(value));
  }
  void put_real(const std::string& path, const std::string& name,
                double value) {
    f_.write_attr(path, name, AttrValue::real(value));
  }
  void put_bool(const std::string& path, const std::string& name,
                bool value) {
    f_.write_attr(path, name, AttrValue::boolean(value));
  }
  void put_extra(const std::string& path, const AttrMap& extra) {
    for (const auto& entry : extra) {
      f_.write_attr(path, entry.first, entry.second);
    }
  }

  // The scale a logical dimension name refers to, for a dataset that
  // sits in `support` (empty for a root-level dataset).
  std::string scale_path(const std::string& logical, std::size_t length,
                         const Support* support, bool local_row) const {
    if (logical == "row") {
      if (local_row && support != nullptr) {
        return "/supports/" + support->name + "/row";
      }
      return "/row";
    }
    if (logical == "component") {
      return "/component_" + internal::format_i64(
                                 static_cast<std::int64_t>(length));
    }
    if (logical == "draw") {
      return "/draw_" +
             internal::format_i64(static_cast<std::int64_t>(length));
    }
    if (logical.compare(0, 6, "group:") == 0) {
      return "/group_" + logical.substr(6);
    }
    if (support != nullptr) return "/supports/" + support->name + "/" +
                                   logical;
    return "/" + logical;
  }

  std::vector<std::size_t> chunk_for(const std::string& path,
                                     std::size_t item,
                                     const std::vector<std::size_t>& shape,
                                     std::size_t row_count) const {
    const auto it = d_.chunk_overrides.find(path);
    if (it != d_.chunk_overrides.end()) return it->second;
    std::vector<std::size_t> rest(shape.begin() + 1, shape.end());
    std::vector<std::size_t> chunk;
    chunk.push_back(default_chunk_rows(item, rest, row_count));
    for (const std::size_t e : rest) chunk.push_back(e);
    return chunk;
  }

  static std::vector<hsize_t> to_h(const std::vector<std::size_t>& v) {
    return std::vector<hsize_t>(v.begin(), v.end());
  }

  // A dimension scale, with whatever storage the dataset it came from
  // had when a reader recorded one (sections 21 and 23 otherwise).
  void scale(const std::string& path, std::size_t length, bool unlimited) {
    const auto it = d_.chunk_overrides.find(path);
    f_.make_scale(path, static_cast<hsize_t>(length), unlimited,
                  it == d_.chunk_overrides.end()
                      ? std::vector<hsize_t>()
                      : to_h(it->second));
  }

  static std::size_t bytes_of(DType t, std::size_t string_size) {
    switch (t) {
      case DType::Bool:
      case DType::UInt8: return 1;
      case DType::Int32: return 4;
      case DType::String: return string_size == 0 ? 1 : string_size;
      default: return 8;
    }
  }

  // Writes one dataset over the row dimension and attaches its scales.
  void write_row_dataset(const std::string& path, DType dtype,
                         const std::vector<std::size_t>& shape,
                         const std::vector<std::string>& dims,
                         const std::vector<double>& f64,
                         const std::vector<std::int64_t>& i64,
                         const std::vector<std::string>& str,
                         std::size_t string_size, std::size_t row_count,
                         const Support* support, bool local_row) {
    const std::size_t item = bytes_of(dtype, string_size);
    const std::vector<std::size_t> chunk =
        chunk_for(path, item, shape, row_count);
    std::vector<hsize_t> maxshape = to_h(shape);
    maxshape[0] = H5S_UNLIMITED;
    write_any(path, dtype, shape, maxshape, chunk, f64, i64, str,
              string_size);
    attach(path, shape, dims, support, local_row);
  }

  void write_fixed_dataset(const std::string& path, DType dtype,
                           const std::vector<std::size_t>& shape,
                           const std::vector<std::string>& dims,
                           const std::vector<double>& f64,
                           const std::vector<std::int64_t>& i64,
                           const std::vector<std::string>& str,
                           std::size_t string_size,
                           const Support* support) {
    write_any(path, dtype, shape, {}, {}, f64, i64, str, string_size);
    attach(path, shape, dims, support, false);
  }

  void write_any(const std::string& path, DType dtype,
                 const std::vector<std::size_t>& shape,
                 const std::vector<hsize_t>& maxshape,
                 const std::vector<std::size_t>& chunk,
                 const std::vector<double>& f64,
                 const std::vector<std::int64_t>& i64,
                 const std::vector<std::string>& str,
                 std::size_t string_size) {
    const std::vector<hsize_t> h_shape = to_h(shape);
    const std::vector<hsize_t> h_chunk = to_h(chunk);
    switch (dtype) {
      case DType::Float64:
        f_.write_f64(path, h_shape, maxshape, h_chunk, f64);
        return;
      case DType::String: {
        std::size_t item = string_size;
        if (item == 0) {
          for (const std::string& s : str) item = std::max(item, s.size());
        }
        f_.write_strings(path, item == 0 ? 1 : item, h_shape, maxshape,
                         h_chunk, str);
        return;
      }
      default:
        f_.write_ints(path, dtype, h_shape, maxshape, h_chunk, i64);
        return;
    }
  }

  void attach(const std::string& path,
              const std::vector<std::size_t>& shape,
              const std::vector<std::string>& dims, const Support* support,
              bool local_row) {
    for (std::size_t axis = 0; axis < shape.size(); ++axis) {
      const std::string logical =
          axis < dims.size() ? dims[axis] : std::string();
      if (logical.empty()) continue;
      const std::string s =
          scale_path(logical, shape[axis], support, local_row);
      f_.attach_scale(path, s, static_cast<unsigned>(axis));
    }
  }

  // --- the file, in order -------------------------------------------

  void root_attributes() {
    put("/", "created", d_.created);
    put("/", "format", d_.format);
    put("/", "writer", d_.writer);
    put_bool("/", "aligned", d_.aligned);
    if (d_.generalisation_group.has_value()) {
      put("/", "generalisation_group", *d_.generalisation_group);
    }
    put_extra("/", d_.root_extra);
  }

  void root_scales() {
    scale("/row", static_cast<std::size_t>(d_.n_rows), true);
    for (const std::size_t n : internal::component_lengths(d_)) {
      scale("/component_" +
                internal::format_i64(static_cast<std::int64_t>(n)),
            n, false);
    }
    for (const std::size_t n : internal::draw_lengths(d_)) {
      scale("/draw_" + internal::format_i64(static_cast<std::int64_t>(n)),
            n, false);
    }
    for (const Key& k : d_.keys) {
      if (k.role != "group") continue;
      std::size_t length = 0;
      if (k.category.has_value()) {
        const CategoryTable* t = d_.category(*k.category);
        if (t != nullptr) length = t->entries.size();
      }
      scale("/group_" + k.name, length, false);
    }
    for (const CategoryTable& t : d_.categories) {
      scale("/category_" + t.name, t.entries.size(), false);
    }
  }

  void categories() {
    if (d_.categories.empty() &&
        d_.container_groups.count("/categories") == 0) {
      return;
    }
    f_.make_group("/categories");
    for (const CategoryTable& t : d_.categories) {
      const std::string p = "/categories/" + t.name;
      std::size_t item = t.string_size.value_or(0);
      if (item == 0) {
        for (const std::string& s : t.entries) item = std::max(item, s.size());
      }
      const std::vector<std::size_t> shape{t.entries.size()};
      f_.write_strings(p, item == 0 ? 1 : item, to_h(shape), {}, {},
                       t.entries);
      f_.attach_scale(p, "/category_" + t.name, 0);
    }
  }

  void keys() {
    if (d_.keys.empty() && d_.container_groups.count("/keys") == 0) return;
    f_.make_group("/keys");
    for (const Key& k : d_.keys) {
      const std::string p = "/keys/" + k.name;
      const std::vector<std::size_t> shape{rows()};
      write_row_dataset(p, k.dtype, shape, {"row"}, k.f64, k.i64, k.str,
                        k.string_size.value_or(0), rows(), nullptr, false);
      put(p, "role", k.role);
      if (k.units.has_value()) put(p, "units", *k.units);
      if (k.lower.has_value()) put_real(p, "lower", *k.lower);
      if (k.upper.has_value()) put_real(p, "upper", *k.upper);
      if (k.category.has_value()) put(p, "category", *k.category);
      if (k.trajectory_group.has_value()) {
        put(p, "trajectory_group", *k.trajectory_group);
      }
      if (k.parent.has_value()) put(p, "parent", *k.parent);
      put_extra(p, k.extra);
    }
  }

  void scalars() {
    if (d_.scalars.empty() && d_.container_groups.count("/scalars") == 0) {
      return;
    }
    f_.make_group("/scalars");
    for (const Scalar& s : d_.scalars) {
      const std::string p = "/scalars/" + s.name;
      if (s.is_callable()) {
        f_.make_group(p);
      } else {
        const std::vector<std::size_t> shape{rows()};
        write_row_dataset(p, DType::Float64, shape, {"row"}, s.values, {},
                          {}, 0, rows(), nullptr, false);
      }
      put(p, "units", s.units);
      put(p, "source", s.source);
      if (s.output.has_value()) put(p, "output", *s.output);
      if (s.statistic.has_value()) put(p, "statistic", *s.statistic);
      if (s.of.has_value()) put(p, "of", *s.of);
      if (s.quantile.has_value()) put_real(p, "quantile", *s.quantile);
      put_extra(p, s.extra);
    }
  }

  void row_support() {
    if (!d_.row_support.has_value()) return;
    std::vector<std::int64_t> values(d_.row_support->begin(),
                                     d_.row_support->end());
    const std::vector<std::size_t> shape{values.size()};
    write_row_dataset("/row_support", DType::Int32, shape, {"row"}, {},
                      values, {}, 0, rows(), nullptr, false);
  }

  void supports() {
    if (d_.supports.empty() &&
        d_.container_groups.count("/supports") == 0) {
      return;
    }
    f_.make_group("/supports");
    for (std::size_t i = 0; i < d_.supports.size(); ++i) {
      write_support(d_.supports[i], i);
    }
  }

  void write_support(const Support& s, std::size_t index) {
    const std::string sp = "/supports/" + s.name;
    f_.make_group(sp);
    // Section 20: a support of kind `none` carries no `node` scale,
    // because a zero-length fixed dimension is not legal.
    if (s.kind != "none") {
      scale(sp + "/node", static_cast<std::size_t>(s.n_nodes), false);
    }
    const bool has_cells = !s.cell_types.empty() || s.n_cells > 0;
    if (has_cells) {
      scale(sp + "/cell", s.cell_types.size(), false);
      scale(sp + "/cell_plus_one", s.cell_offsets.size(), false);
      scale(sp + "/index", s.cell_connectivity.size(), false);
      std::vector<std::int64_t> types(s.cell_types.begin(),
                                      s.cell_types.end());
      write_fixed_dataset(sp + "/cell_types", DType::UInt8,
                          {s.cell_types.size()}, {"cell"}, {}, types, {}, 0,
                          &s);
      write_fixed_dataset(sp + "/cell_offsets", DType::Int64,
                          {s.cell_offsets.size()}, {"cell_plus_one"}, {},
                          s.cell_offsets, {}, 0, &s);
      write_fixed_dataset(sp + "/cell_connectivity", DType::Int64,
                          {s.cell_connectivity.size()}, {"index"}, {},
                          s.cell_connectivity, {}, 0, &s);
    }
    put(sp, "kind", s.kind);
    put_int(sp, "n_nodes", s.n_nodes);
    put_int(sp, "n_cells", s.n_cells);
    put(sp, "support_id", s.support_id);
    put_extra(sp, s.extra);

    const bool local_row = internal::needs_local_row(d_, s);
    const std::size_t support_rows = internal::rows_on_support(d_, index);
    if (local_row) {
      scale(sp + "/row", support_rows, true);
    }

    if (s.coordinates.has_value()) {
      write_slot(sp + "/coordinates", *s.coordinates, &s, local_row,
                 support_rows);
    }
    if (!s.node_arrays.empty()) {
      f_.make_group(sp + "/node_arrays");
      for (const ArraySlot& a : s.node_arrays) {
        write_slot(sp + "/node_arrays/" + a.name, a, &s, local_row,
                   support_rows);
      }
    }
    if (!s.cell_arrays.empty()) {
      f_.make_group(sp + "/cell_arrays");
      for (const ArraySlot& a : s.cell_arrays) {
        write_slot(sp + "/cell_arrays/" + a.name, a, &s, local_row,
                   support_rows);
      }
    }
  }

  void write_slot(const std::string& p, const ArraySlot& a,
                  const Support* s, bool local_row,
                  std::size_t support_rows) {
    if (a.is_callable()) {
      // Section 19: a slot served by a callable is an empty group
      // carrying the slot's attributes and no data.
      f_.make_group(p);
    } else if (a.varies == "row") {
      write_row_dataset(p, a.data.dtype, a.data.shape, a.data.dims,
                        a.data.f64, a.data.i64, a.data.str, 0,
                        local_row ? support_rows : rows(), s, local_row);
    } else {
      write_fixed_dataset(p, a.data.dtype, a.data.shape, a.data.dims,
                          a.data.f64, a.data.i64, a.data.str, 0, s);
    }
    put(p, "role", a.role);
    put(p, "varies", a.varies);
    if (a.units.has_value()) put(p, "units", *a.units);
    put_int(p, "components", a.components);
    put(p, "source", a.source);
    if (a.output.has_value()) put(p, "output", *a.output);
    if (a.statistic.has_value()) put(p, "statistic", *a.statistic);
    if (a.of.has_value()) put(p, "of", *a.of);
    if (a.quantile.has_value()) put_real(p, "quantile", *a.quantile);
    if (a.category.has_value()) put(p, "category", *a.category);
    if (a.recomputed.has_value()) put_bool(p, "recomputed", *a.recomputed);
    if (a.derived_from.has_value()) put(p, "derived_from", *a.derived_from);
    if (a.recipe.has_value()) put(p, "recipe", *a.recipe);
    if (a.reference.has_value()) put(p, "reference", *a.reference);
    put_extra(p, a.extra);
  }

  void callables() {
    if (d_.callables.empty() &&
        d_.container_groups.count("/callables") == 0) {
      return;
    }
    f_.make_group("/callables");
    for (const StoredCallable& c : d_.callables) {
      const std::string p = "/callables/" + c.id;
      f_.make_group(p);
      put(p, "type", c.type);
      if (c.repr.has_value()) put(p, "repr", *c.repr);
      internal::write_dict_group(f_, p, c.dict, &d_.chunk_overrides);
    }
  }

  void trailing_groups() {
    if (d_.has_notes) {
      f_.make_group("/notes");
      put_extra("/notes", d_.notes);
    }
    for (const std::string& name : d_.unknown_root_groups) {
      f_.make_group("/" + name);
    }
  }

  const Dataset& d_;
  File& f_;
};

void check_names(const Dataset& d) {
  auto check = [](const std::string& name) {
    if (!internal::legal_netcdf_name(name)) {
      throw Error("E33", "\"" + name + "\" is not a legal netCDF-4 name");
    }
    if (internal::reserved_name(name)) {
      throw Error("E33", "\"" + name +
                             "\" begins with the reserved prefix mestra_");
    }
  };
  for (const Key& k : d.keys) check(k.name);
  for (const Scalar& s : d.scalars) check(s.name);
  for (const CategoryTable& t : d.categories) check(t.name);
  for (const StoredCallable& c : d.callables) check(c.id);
  for (const Support& s : d.supports) {
    check(s.name);
    for (const ArraySlot& a : s.node_arrays) check(a.name);
    for (const ArraySlot& a : s.cell_arrays) check(a.name);
  }
}

}  // namespace

void write(const Dataset& d, const std::string& path) {
  check_names(d);
  File f = File::create(path);
  Writer w(d, f);
  w.run();
}

void write_dict(const Dict& dict, const std::string& type,
                const std::string& callable_id, const std::string& path) {
  Dataset d;
  d.writer = library_version();
  d.created = "1970-01-01T00:00:00Z";
  d.aligned = true;
  d.n_rows = 0;
  d.container_groups.insert("/keys");
  d.add_callable(callable_id, type, dict);
  write(d, path);
}

}  // namespace mestra
