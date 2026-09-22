// Growing a file by rows: `append_rows` of io.hpp.
//
// The original is never written to.  It is copied to a name beside
// it, the copy is grown -- every row-dimensioned dataset extended and
// the new rows written into it, the row scale lengthened, the key
// bounds widened, the notes replaced -- then validated, and only then
// moved over the original, so that a failure of any kind leaves the
// original as it was.  What may be appended is decided before the copy
// is made: a dataset of the file's structure, compared attribute by
// attribute against a header read of the file and value by value
// against every array that does not vary by row, so that the grown
// file is what one write of all the rows would have produced.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <map>
#include <optional>
#include <set>

#include "h5.hpp"
#include "layout.hpp"
#include "mestra/io.hpp"
#include "mestra/validate.hpp"
#include "names.hpp"

namespace mestra {
namespace {

using internal::File;

[[noreturn]] void refuse(const std::string& path, const std::string& why) {
  throw Error("", "mestra::append_rows refused \"" + path + "\": " + why);
}

std::string quoted(const std::string& s) { return "\"" + s + "\""; }

std::string text_or(const std::optional<std::string>& v) {
  return v.has_value() ? quoted(*v) : std::string("none");
}

std::string real_or(const std::optional<double>& v) {
  return v.has_value() ? internal::format_f64(*v) : std::string("none");
}

std::string bool_or(const std::optional<bool>& v) {
  return v.has_value() ? (*v ? "true" : "false") : std::string("none");
}


template <typename T>
std::string names_text(const std::vector<T>& v) {
  std::string out;
  for (const T& x : v) {
    if (!out.empty()) out += ", ";
    out += x.name;
  }
  return out.empty() ? std::string("(none)") : out;
}

// The number of elements one row of an array holds.
std::size_t stride_of(const Array& a) {
  std::size_t n = 1;
  for (std::size_t i = 1; i < a.shape.size(); ++i) n *= a.shape[i];
  return n;
}

bool varies_by_row(const ArraySlot& a) { return a.varies == "row"; }

// Which of the file's category ids each id of the appended dataset's
// tables means, by the entry's name: a table built from the appended
// rows alone maps onto the file's table whatever its order.
class CategoryMap {
 public:
  void learn(const std::string& file_path, const Dataset& file,
             const Dataset& rows) {
    for (const CategoryTable& t : rows.categories) {
      if (file.category(t.name) == nullptr) {
        refuse(file_path, "the rows carry a category table " +
                              quoted(t.name) + " the file does not");
      }
      const Array stored = read_slot(file_path, "/categories/" + t.name);
      std::map<std::string, std::int64_t> position;
      for (std::size_t i = 0; i < stored.str.size(); ++i) {
        position.emplace(stored.str[i], static_cast<std::int64_t>(i));
      }
      std::vector<std::int64_t> map;
      for (const std::string& entry : t.entries) {
        const auto it = position.find(entry);
        if (it == position.end()) {
          refuse(file_path, "the category table " + quoted(t.name) +
                                " in the file has no entry " +
                                quoted(entry) +
                                "; a table grows only by writing the file "
                                "again");
        }
        map.push_back(it->second);
      }
      maps_.emplace(t.name, std::move(map));
    }
    for (const CategoryTable& t : file.categories) {
      if (rows.category(t.name) == nullptr) {
        refuse(file_path, "the file carries a category table " +
                              quoted(t.name) + " the rows do not");
      }
    }
  }

  std::int64_t mapped(const std::string& file_path, const std::string& table,
                      const std::string& where, std::int64_t id) const {
    const auto it = maps_.find(table);
    if (it == maps_.end()) {
      refuse(file_path, where + " names a category table " + quoted(table) +
                            " the rows do not carry");
    }
    if (id < 0 || id >= static_cast<std::int64_t>(it->second.size())) {
      refuse(file_path, where + " holds the category id " +
                            internal::format_i64(id) +
                            ", which its table does not have");
    }
    return it->second[static_cast<std::size_t>(id)];
  }

  std::vector<std::int64_t> mapped(const std::string& file_path,
                                   const std::string& table,
                                   const std::string& where,
                                   const std::vector<std::int64_t>& ids) const {
    std::vector<std::int64_t> out;
    out.reserve(ids.size());
    for (const std::int64_t id : ids) out.push_back(mapped(file_path, table, where, id));
    return out;
  }

 private:
  std::map<std::string, std::vector<std::int64_t>> maps_;
};

// --- the structural comparison ----------------------------------------

void compare_keys(const std::string& path, const Dataset& file,
                  const Dataset& rows) {
  if (file.key_order() != rows.key_order()) {
    refuse(path, "the keys differ: the file has " + names_text(file.keys) +
                     " and the rows have " + names_text(rows.keys));
  }
  for (const Key& f : file.keys) {
    const Key& r = *rows.key(f.name);
    const std::string where = "/keys/" + f.name;
    auto differ = [&](const std::string& what, const std::string& have,
                      const std::string& want) {
      refuse(path, where + ": " + what + " is " + have + " in the file and " +
                       want + " in the rows");
    };
    if (f.role != r.role) differ("role", quoted(f.role), quoted(r.role));
    if (f.units != r.units) differ("units", text_or(f.units), text_or(r.units));
    if (f.category != r.category) {
      differ("category", text_or(f.category), text_or(r.category));
    }
    if (f.trajectory_group != r.trajectory_group) {
      differ("trajectory_group", text_or(f.trajectory_group),
             text_or(r.trajectory_group));
    }
    if (f.parent != r.parent) differ("parent", text_or(f.parent), text_or(r.parent));
    if (f.dtype != r.dtype) differ("dtype", dtype_name(f.dtype), dtype_name(r.dtype));
    if (static_cast<std::int64_t>(r.rows()) != rows.n_rows) {
      refuse(path, where + " holds " + internal::format_i64(
                                            static_cast<std::int64_t>(r.rows())) +
                       " values for " + internal::format_i64(rows.n_rows) +
                       " rows");
    }
    if (f.dtype == DType::String) {
      const std::size_t size = f.string_size.value_or(0);
      for (const std::string& s : r.str) {
        if (s.size() > size) {
          refuse(path, where + " holds strings of " +
                           internal::format_i64(static_cast<std::int64_t>(size)) +
                           " bytes and " + quoted(s) +
                           " is longer; a string column grows only by "
                           "writing the file again");
        }
      }
    }
  }
}

void compare_scalars(const std::string& path, const Dataset& file,
                     const Dataset& rows) {
  std::vector<std::string> a;
  std::vector<std::string> b;
  for (const Scalar& s : file.scalars) a.push_back(s.name);
  for (const Scalar& s : rows.scalars) b.push_back(s.name);
  std::sort(a.begin(), a.end(), bytes_less);
  std::sort(b.begin(), b.end(), bytes_less);
  if (a != b) {
    refuse(path, "the scalars differ: the file has " +
                     names_text(file.scalars) + " and the rows have " +
                     names_text(rows.scalars));
  }
  for (const Scalar& f : file.scalars) {
    const Scalar& r = *rows.scalar(f.name);
    const std::string where = "/scalars/" + f.name;
    auto differ = [&](const std::string& what, const std::string& have,
                      const std::string& want) {
      refuse(path, where + ": " + what + " is " + have + " in the file and " +
                       want + " in the rows");
    };
    if (f.units != r.units) differ("units", quoted(f.units), quoted(r.units));
    if (f.source != r.source) differ("source", quoted(f.source), quoted(r.source));
    if (f.output != r.output) differ("output", text_or(f.output), text_or(r.output));
    if (f.statistic != r.statistic) {
      differ("statistic", text_or(f.statistic), text_or(r.statistic));
    }
    if (f.of != r.of) differ("of", text_or(f.of), text_or(r.of));
    if (f.quantile != r.quantile) differ("quantile", real_or(f.quantile), real_or(r.quantile));
    if (f.level != r.level) differ("level", real_or(f.level), real_or(r.level));
    if (f.method != r.method) differ("method", text_or(f.method), text_or(r.method));
    if (!r.is_callable() &&
        static_cast<std::int64_t>(r.values.size()) != rows.n_rows) {
      refuse(path, where + " holds " +
                       internal::format_i64(
                           static_cast<std::int64_t>(r.values.size())) +
                       " values for " + internal::format_i64(rows.n_rows) +
                       " rows");
    }
  }
}

// One slot against the file's, attributes first and then, for a slot
// that does not vary by row, its stored values.
void compare_slot(const std::string& path, const std::string& where,
                  const ArraySlot& f, const ArraySlot& r,
                  const CategoryMap& categories) {
  auto differ = [&](const std::string& what, const std::string& have,
                    const std::string& want) {
    refuse(path, where + ": " + what + " is " + have + " in the file and " +
                     want + " in the rows");
  };
  if (f.role != r.role) differ("role", quoted(f.role), quoted(r.role));
  if (f.varies != r.varies) differ("varies", quoted(f.varies), quoted(r.varies));
  if (f.units != r.units) differ("units", text_or(f.units), text_or(r.units));
  if (f.components != r.components) {
    differ("components", internal::format_i64(f.components),
           internal::format_i64(r.components));
  }
  if (f.source != r.source) differ("source", quoted(f.source), quoted(r.source));
  if (f.output != r.output) differ("output", text_or(f.output), text_or(r.output));
  if (f.statistic != r.statistic) differ("statistic", text_or(f.statistic), text_or(r.statistic));
  if (f.of != r.of) differ("of", text_or(f.of), text_or(r.of));
  if (f.quantile != r.quantile) differ("quantile", real_or(f.quantile), real_or(r.quantile));
  if (f.level != r.level) differ("level", real_or(f.level), real_or(r.level));
  if (f.method != r.method) differ("method", text_or(f.method), text_or(r.method));
  if (f.category != r.category) differ("category", text_or(f.category), text_or(r.category));
  if (f.recomputed != r.recomputed) differ("recomputed", bool_or(f.recomputed), bool_or(r.recomputed));
  if (f.derived_from != r.derived_from) differ("derived_from", text_or(f.derived_from), text_or(r.derived_from));
  if (f.recipe != r.recipe) differ("recipe", text_or(f.recipe), text_or(r.recipe));
  if (f.reference != r.reference) differ("reference", text_or(f.reference), text_or(r.reference));
  if (f.location != r.location) differ("location", f.location == Location::Node ? "node" : "cell", r.location == Location::Node ? "node" : "cell");
  if (r.is_callable()) return;
  if (f.data.dtype != r.data.dtype) {
    differ("dtype", dtype_name(f.data.dtype), dtype_name(r.data.dtype));
  }
  if (f.data.shape.size() != r.data.shape.size()) {
    differ("rank", internal::format_i64(static_cast<std::int64_t>(f.data.shape.size())),
           internal::format_i64(static_cast<std::int64_t>(r.data.shape.size())));
  }
  const std::size_t first = varies_by_row(r) ? 1 : 0;
  for (std::size_t i = first; i < f.data.shape.size(); ++i) {
    if (f.data.shape[i] != r.data.shape[i]) {
      differ("the extent of axis " + internal::format_i64(static_cast<std::int64_t>(i)),
             internal::format_i64(static_cast<std::int64_t>(f.data.shape[i])),
             internal::format_i64(static_cast<std::int64_t>(r.data.shape[i])));
    }
  }
  if (varies_by_row(r)) return;
  // An array that does not vary by row is the same in the grown file
  // as in the rows, or the two are not one dataset.
  const Array stored = read_slot(path, where);
  bool same = stored.dtype == r.data.dtype && stored.shape == r.data.shape;
  if (same) {
    switch (r.data.dtype) {
      case DType::Float64:
        same = stored.f64 == r.data.f64;
        break;
      case DType::String:
        same = stored.str == r.data.str;
        break;
      default:
        if (r.category.has_value()) {
          same = stored.i64 == categories.mapped(path, *r.category, where, r.data.i64);
        } else {
          same = stored.i64 == r.data.i64;
        }
        break;
    }
  }
  if (!same) {
    refuse(path, where + " does not vary by row and its values differ "
                         "between the file and the rows");
  }
}

void compare_supports(const std::string& path, const Dataset& file,
                      const Dataset& rows, const CategoryMap& categories) {
  std::vector<std::string> a;
  std::vector<std::string> b;
  for (const Support& s : file.supports) a.push_back(s.name);
  for (const Support& s : rows.supports) b.push_back(s.name);
  if (a != b) {
    refuse(path, "the supports differ: the file has " +
                     names_text(file.supports) + " and the rows have " +
                     names_text(rows.supports));
  }
  for (const Support& f : file.supports) {
    const Support& r = *rows.support(f.name);
    const std::string sp = "/supports/" + f.name;
    auto differ = [&](const std::string& what, const std::string& have,
                      const std::string& want) {
      refuse(path, sp + ": " + what + " is " + have + " in the file and " +
                       want + " in the rows");
    };
    if (f.kind != r.kind) differ("kind", quoted(f.kind), quoted(r.kind));
    if (f.n_nodes != r.n_nodes) differ("n_nodes", internal::format_i64(f.n_nodes), internal::format_i64(r.n_nodes));
    if (f.n_cells != r.n_cells) differ("n_cells", internal::format_i64(f.n_cells), internal::format_i64(r.n_cells));
    if (f.support_id != r.support_id) {
      refuse(path, sp + ": the support id differs, so the rows sit on "
                        "another mesh than the file's");
    }
    if (f.coordinates.has_value() != r.coordinates.has_value()) {
      refuse(path, sp + ": one side has coordinates and the other has none");
    }
    if (f.coordinates.has_value()) {
      compare_slot(path, sp + "/coordinates", *f.coordinates, *r.coordinates,
                   categories);
    }
    for (int which = 0; which < 2; ++which) {
      const std::vector<ArraySlot>& fs = which == 0 ? f.node_arrays : f.cell_arrays;
      const std::vector<ArraySlot>& rs = which == 0 ? r.node_arrays : r.cell_arrays;
      const std::string group = which == 0 ? "/node_arrays/" : "/cell_arrays/";
      std::vector<std::string> fn;
      std::vector<std::string> rn;
      for (const ArraySlot& x : fs) fn.push_back(x.name);
      for (const ArraySlot& x : rs) rn.push_back(x.name);
      std::sort(fn.begin(), fn.end(), bytes_less);
      std::sort(rn.begin(), rn.end(), bytes_less);
      if (fn != rn) {
        refuse(path, sp + group + ": the arrays differ: the file has " +
                         names_text(fs) + " and the rows have " +
                         names_text(rs));
      }
      for (const ArraySlot& x : fs) {
        const ArraySlot* y = which == 0 ? r.node_array(x.name) : r.cell_array(x.name);
        compare_slot(path, sp + group + x.name, x, *y, categories);
      }
    }
  }
}

void compare_structure(const std::string& path, const Dataset& file,
                       const Dataset& rows, const CategoryMap& categories) {
  if (rows.format != file.format) {
    refuse(path, "the rows are " + quoted(rows.format) + " and the file is " +
                     quoted(file.format));
  }
  if (!file.aligned || file.row_support.has_value() || file.supports.size() > 1) {
    refuse(path, "the file is not aligned (section 22), which this version "
                 "does not grow by rows");
  }
  if (!rows.aligned || rows.row_support.has_value()) {
    refuse(path, "the rows are not aligned and the file is");
  }
  if (file.generalisation_group != rows.generalisation_group) {
    refuse(path, "the unit of generalisation is " +
                     text_or(file.generalisation_group) + " in the file and " +
                     text_or(rows.generalisation_group) + " in the rows");
  }
  compare_keys(path, file, rows);
  compare_scalars(path, file, rows);
  compare_supports(path, file, rows, categories);
  std::vector<std::string> a;
  std::vector<std::string> b;
  for (const StoredCallable& c : file.callables) a.push_back(c.id + ":" + c.type);
  for (const StoredCallable& c : rows.callables) b.push_back(c.id + ":" + c.type);
  std::sort(a.begin(), a.end(), bytes_less);
  std::sort(b.begin(), b.end(), bytes_less);
  if (a != b) {
    refuse(path, "the callables differ between the file and the rows");
  }
  // A slot that varies by row holds one row's worth per row.
  for (const Support& s : rows.supports) {
    std::vector<const ArraySlot*> slots;
    if (s.coordinates.has_value()) slots.push_back(&*s.coordinates);
    for (const ArraySlot& x : s.node_arrays) slots.push_back(&x);
    for (const ArraySlot& x : s.cell_arrays) slots.push_back(&x);
    for (const ArraySlot* x : slots) {
      if (x->is_callable() || !varies_by_row(*x)) continue;
      if (x->data.shape.empty() ||
          static_cast<std::int64_t>(x->data.shape[0]) != rows.n_rows) {
        refuse(path, "/supports/" + s.name + ": " + x->name + " holds " +
                         internal::format_i64(x->data.shape.empty() ? 0 : static_cast<std::int64_t>(x->data.shape[0])) +
                         " rows for " + internal::format_i64(rows.n_rows));
      }
    }
  }
}

// Where each appended row lands: over the row that shares its id when
// `replace_by` names one, else after the last row.
std::vector<std::size_t> row_targets(const std::string& path,
                                     const Dataset& file, const Dataset& rows,
                                     const AppendOptions& options,
                                     std::size_t* appended) {
  const std::size_t k = static_cast<std::size_t>(rows.n_rows);
  const std::size_t n = static_cast<std::size_t>(file.n_rows);
  std::vector<std::size_t> targets(k, n);
  std::vector<bool> placed(k, false);
  if (!options.replace_by.empty()) {
    const Key* fk = file.key(options.replace_by);
    const Key* rk = rows.key(options.replace_by);
    if (fk == nullptr || rk == nullptr) {
      refuse(path, "replace_by names " + quoted(options.replace_by) +
                       ", which is not a key of both the file and the rows");
    }
    if (fk->role != "id") {
      refuse(path, "replace_by names " + quoted(options.replace_by) +
                       ", whose role is " + quoted(fk->role) + " and not id");
    }
    const Array column = read_slot(path, "/keys/" + options.replace_by);
    std::map<std::string, std::size_t> by_text;
    std::map<std::int64_t, std::size_t> by_int;
    for (std::size_t i = 0; i < column.str.size(); ++i) by_text.emplace(column.str[i], i);
    for (std::size_t i = 0; i < column.i64.size(); ++i) by_int.emplace(column.i64[i], i);
    std::set<std::string> seen_text;
    std::set<std::int64_t> seen_int;
    for (std::size_t i = 0; i < k; ++i) {
      if (rk->dtype == DType::String) {
        const std::string& id = rk->str.at(i);
        if (!seen_text.insert(id).second) {
          refuse(path, "two of the rows share the id " + quoted(id));
        }
        const auto it = by_text.find(id);
        if (it != by_text.end()) {
          targets[i] = it->second;
          placed[i] = true;
        }
      } else {
        const std::int64_t id = rk->i64.at(i);
        if (!seen_int.insert(id).second) {
          refuse(path, "two of the rows share the id " + internal::format_i64(id));
        }
        const auto it = by_int.find(id);
        if (it != by_int.end()) {
          targets[i] = it->second;
          placed[i] = true;
        }
      }
    }
  }
  *appended = 0;
  for (std::size_t i = 0; i < k; ++i) {
    if (placed[i]) continue;
    targets[i] = n + *appended;
    ++*appended;
  }
  return targets;
}

// The row-dimensioned datasets of the file, by path, with the slot each
// belongs to.
struct RowDataset {
  std::string path;
  const Key* key = nullptr;
  const Scalar* scalar = nullptr;
  const ArraySlot* slot = nullptr;
};

std::vector<RowDataset> row_datasets(const Dataset& rows) {
  std::vector<RowDataset> out;
  for (const Key& k : rows.keys) {
    RowDataset d;
    d.path = "/keys/" + k.name;
    d.key = &k;
    out.push_back(d);
  }
  for (const Scalar& s : rows.scalars) {
    if (s.is_callable()) continue;
    RowDataset d;
    d.path = "/scalars/" + s.name;
    d.scalar = &s;
    out.push_back(d);
  }
  for (const Support& s : rows.supports) {
    const std::string sp = "/supports/" + s.name;
    if (s.coordinates.has_value() && !s.coordinates->is_callable() &&
        varies_by_row(*s.coordinates)) {
      RowDataset d;
      d.path = sp + "/coordinates";
      d.slot = &*s.coordinates;
      out.push_back(d);
    }
    for (const ArraySlot& a : s.node_arrays) {
      if (a.is_callable() || !varies_by_row(a)) continue;
      RowDataset d;
      d.path = sp + "/node_arrays/" + a.name;
      d.slot = &a;
      out.push_back(d);
    }
    for (const ArraySlot& a : s.cell_arrays) {
      if (a.is_callable() || !varies_by_row(a)) continue;
      RowDataset d;
      d.path = sp + "/cell_arrays/" + a.name;
      d.slot = &a;
      out.push_back(d);
    }
  }
  return out;
}

void write_row(File& f, const std::string& file_path, const RowDataset& d,
               std::size_t source, std::size_t target,
               const CategoryMap& categories) {
  if (d.key != nullptr) {
    const Key& k = *d.key;
    switch (k.dtype) {
      case DType::Float64:
        f.write_f64_rows(d.path, target, {k.f64.at(source)});
        return;
      case DType::String:
        f.write_string_rows(d.path, target, {k.str.at(source)});
        return;
      default: {
        std::int64_t v = k.i64.at(source);
        if (k.category.has_value()) {
          v = categories.mapped(file_path, *k.category, d.path, v);
        }
        f.write_i64_rows(d.path, target, {v});
        return;
      }
    }
  }
  if (d.scalar != nullptr) {
    f.write_f64_rows(d.path, target, {d.scalar->values.at(source)});
    return;
  }
  const Array& a = d.slot->data;
  const std::size_t stride = stride_of(a);
  const std::size_t begin = source * stride;
  switch (a.dtype) {
    case DType::Float64:
      f.write_f64_rows(d.path, target,
                       std::vector<double>(a.f64.begin() + static_cast<std::ptrdiff_t>(begin),
                                           a.f64.begin() + static_cast<std::ptrdiff_t>(begin + stride)));
      return;
    case DType::String:
      f.write_string_rows(d.path, target,
                          std::vector<std::string>(a.str.begin() + static_cast<std::ptrdiff_t>(begin),
                                                   a.str.begin() + static_cast<std::ptrdiff_t>(begin + stride)));
      return;
    default: {
      std::vector<std::int64_t> values(a.i64.begin() + static_cast<std::ptrdiff_t>(begin),
                                       a.i64.begin() + static_cast<std::ptrdiff_t>(begin + stride));
      if (d.slot->category.has_value()) {
        values = categories.mapped(file_path, *d.slot->category, d.path, values);
      }
      f.write_i64_rows(d.path, target, values);
      return;
    }
  }
}

// The key bounds of the grown file cover the new values (W04).
void widen_bounds(File& f, const Dataset& file, const Dataset& rows) {
  for (const Key& fk : file.keys) {
    if (fk.dtype != DType::Float64) continue;
    const Key& rk = *rows.key(fk.name);
    bool any = false;
    double lo = 0.0;
    double hi = 0.0;
    for (const double v : rk.f64) {
      if (!std::isfinite(v)) continue;
      if (!any) {
        lo = v;
        hi = v;
        any = true;
      } else {
        lo = std::min(lo, v);
        hi = std::max(hi, v);
      }
    }
    if (!any) continue;
    const std::string p = "/keys/" + fk.name;
    if (fk.lower.has_value() && lo < *fk.lower) {
      f.replace_attr(p, "lower", AttrValue::real(lo));
    }
    if (fk.upper.has_value() && hi > *fk.upper) {
      f.replace_attr(p, "upper", AttrValue::real(hi));
    }
  }
}

std::string findings_text(const std::string& path, const Report& r) {
  std::string out = "mestra::append_rows refused \"" + path + "\": the grown file has " +
                    internal::format_i64(
                        static_cast<std::int64_t>(r.errors.size())) +
                    " error(s)";
  for (const Finding& f : r.errors) {
    out += "\n  " + (f.id.empty() ? std::string("!") : f.id) + " " +
           f.where + ": " + f.message;
  }
  return out;
}

}  // namespace

std::int64_t append_rows(const Dataset& rows, const std::string& path,
                         const AppendOptions& options) {
  internal::check_dataset_names(rows);
  internal::check_dataset_shapes(rows);
  if (rows.n_rows < 0) refuse(path, "a negative row count");

  // What the file is, without reading a row of it; this refuses a
  // file the reader would refuse, with the same identifiers.
  const Dataset file = read_header(path);
  CategoryMap categories;
  categories.learn(path, file, rows);
  compare_structure(path, file, rows, categories);
  if (rows.n_rows == 0) return file.n_rows;

  std::size_t appended = 0;
  const std::vector<std::size_t> targets =
      row_targets(path, file, rows, options, &appended);
  const std::size_t n = static_cast<std::size_t>(file.n_rows);
  const std::size_t count = n + appended;
  const std::vector<RowDataset> datasets = row_datasets(rows);

  // Grown beside the original and moved into place once it validates.
  const std::string beside = path + ".mestra-appending";
  std::error_code ec;
  std::filesystem::remove(beside, ec);
  if (!std::filesystem::copy_file(path, beside,
                                  std::filesystem::copy_options::overwrite_existing,
                                  ec)) {
    throw Error("", "cannot copy \"" + path + "\" beside itself to grow it: " +
                        ec.message());
  }
  try {
    {
      File f = File::open_write(beside);
      if (appended > 0) {
        f.set_scale_length("/row", static_cast<hsize_t>(count));
        for (const RowDataset& d : datasets) {
          f.extend_rows(d.path, static_cast<hsize_t>(count));
        }
      }
      for (std::size_t i = 0; i < static_cast<std::size_t>(rows.n_rows); ++i) {
        for (const RowDataset& d : datasets) {
          write_row(f, path, d, i, targets[i], categories);
        }
      }
      widen_bounds(f, file, rows);
      if (rows.has_notes) {
        f.make_group("/notes");
        f.remove_attributes("/notes");
        for (const auto& entry : rows.notes) {
          f.write_attr("/notes", entry.first, entry.second);
        }
      }
    }
    if (options.check) {
      const Report r = validate(beside);
      if (!r.ok()) {
        std::filesystem::remove(beside, ec);
        throw Error(r.errors.front().id, findings_text(path, r));
      }
    }
  } catch (...) {
    std::filesystem::remove(beside, ec);
    throw;
  }
  std::filesystem::rename(beside, path, ec);
  if (ec) {
    std::filesystem::remove(beside, ec);
    throw Error("", "cannot move the grown file into place at \"" + path +
                        "\"");
  }
  return static_cast<std::int64_t>(count);
}

}  // namespace mestra
