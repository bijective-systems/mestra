// The validator of SPEC.md section 14.  It reads the file through the
// low-level layer rather than through mestra::read, because most of
// what it has to catch is a file a reader cannot parse.
#include "mestra/validate.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "codec.hpp"
#include "h5.hpp"
#include "layout.hpp"
#include "mestra/dataset.hpp"
#include "mestra/io.hpp"
#include "names.hpp"

namespace mestra {
namespace {

using internal::AttrType;
using internal::DsetInfo;
using internal::File;
using internal::Member;
using internal::RawAttr;

// Passed as the chunk row count when W12 does not apply.
const std::size_t kNoChunkCheck = std::numeric_limits<std::size_t>::max();

const RawAttr* find(const std::vector<RawAttr>& attrs,
                    const std::string& name) {
  for (const RawAttr& a : attrs) {
    if (a.name == name) return &a;
  }
  return nullptr;
}

std::string text_of(const std::vector<RawAttr>& attrs,
                    const std::string& name, bool* present = nullptr) {
  const RawAttr* a = find(attrs, name);
  if (present != nullptr) *present = a != nullptr;
  if (a == nullptr || a->value.kind() != AttrValue::Kind::Str) return "";
  return a->value.as_text();
}

// The expected encoding of every attribute this specification names
// (section 18).
enum class Enc { None, Text, Integer, Real, Boolean };

Enc expected_encoding(const std::string& name) {
  if (name == "aligned" || name == "recomputed") return Enc::Boolean;
  if (name == "n_nodes" || name == "n_cells" || name == "components") {
    return Enc::Integer;
  }
  if (name == "lower" || name == "upper" || name == "quantile") {
    return Enc::Real;
  }
  if (name == "format" || name == "writer" || name == "created" ||
      name == "generalisation_group" || name == "role" || name == "units" ||
      name == "category" || name == "trajectory_group" || name == "parent" ||
      name == "source" || name == "output" || name == "statistic" ||
      name == "of" || name == "kind" || name == "support_id" ||
      name == "varies" || name == "derived_from" || name == "recipe" ||
      name == "reference" || name == "type" || name == "repr") {
    return Enc::Text;
  }
  return Enc::None;
}

bool is_null_sentinel_bytes(const std::string& raw) {
  return raw.size() == 5 && raw[0] == '\0' && raw.compare(1, 4, "null") == 0;
}

// What a slot's axes look like, taken from the dimension scales.
struct Axes {
  std::vector<std::string> logical;   // one per axis, "" when unknown
  std::vector<std::size_t> extent;
  int index_of(const std::string& name) const {
    for (std::size_t i = 0; i < logical.size(); ++i) {
      if (logical[i] == name) return static_cast<int>(i);
    }
    return -1;
  }
};

class Validator {
 public:
  Validator(File& f, Report* r) : f_(f), r_(r) {}

  void run();

 private:
  void error(const std::string& id, const std::string& where,
             const std::string& message) {
    r_->errors.push_back({id, where, message});
  }
  void warn(const std::string& id, const std::string& where,
            const std::string& message) {
    r_->warnings.push_back({id, where, message});
  }

  File& f_;
  Report* r_;
  std::int64_t n_rows_ = 0;
  bool aligned_ = true;
  std::vector<std::string> support_names_;
  std::map<std::string, std::vector<std::string>> category_tables_;
  std::set<std::string> callable_ids_;
  std::vector<std::int64_t> row_support_;
  bool has_row_support_ = false;
  bool has_group_key_ = false;

  // The validator reports a fault rather than failing on one, so a
  // read that the library refuses -- a dtype the rule above has
  // already reported, a dataset HDF5 will not convert -- comes back
  // empty and the walk goes on.
  std::vector<double> reals(const std::string& path) {
    try {
      return f_.read_f64(path);
    } catch (const std::exception&) {
      return {};
    }
  }
  std::vector<std::int64_t> integers(const std::string& path) {
    try {
      return f_.read_i64(path);
    } catch (const std::exception&) {
      return {};
    }
  }
  std::vector<std::string> texts(const std::string& path) {
    try {
      return f_.read_strings(path);
    } catch (const std::exception&) {
      return {};
    }
  }
  std::vector<std::string> raw_texts(const std::string& path) {
    try {
      return f_.read_strings_raw(path);
    } catch (const std::exception&) {
      return {};
    }
  }

  Axes axes_of(const std::string& path, const DsetInfo& info,
               bool report_e25);
  void check_attribute_encodings(const std::string& path,
                                 const std::vector<RawAttr>& attrs);
  void check_string_dataset(const std::string& path, const DsetInfo& info,
                            bool warn_oversize);
  void check_dataset_storage(const std::string& path, const DsetInfo& info,
                             bool is_row_dataset, std::size_t chunk_rows);

  void root();
  void categories();
  void keys();
  void scalars();
  void row_support_dataset();
  void supports();
  void callables();
  void check_dict(const std::string& path, bool top_level);
  void slot(const std::string& path, const std::string& support_kind,
            std::int64_t n_nodes, std::int64_t n_cells,
            std::size_t support_index, bool is_coordinates);
};

// --- helpers ----------------------------------------------------------

Axes Validator::axes_of(const std::string& path, const DsetInfo& info,
                        bool report_e25) {
  Axes a;
  for (std::size_t i = 0; i < info.shape.size(); ++i) {
    a.extent.push_back(static_cast<std::size_t>(info.shape[i]));
    const std::vector<std::string>& attached = info.scales[i];
    if (attached.size() != 1) {
      if (report_e25) {
        const std::string axis =
            internal::format_i64(static_cast<std::int64_t>(i));
        error("E25", path,
              attached.empty()
                  ? "axis " + axis + " has no dimension scale attached"
                  : "axis " + axis +
                        " has more than one dimension scale attached");
      }
      a.logical.push_back(std::string());
    } else {
      a.logical.push_back(internal::logical_dim(attached.front()));
    }
  }
  return a;
}

void Validator::check_attribute_encodings(
    const std::string& path, const std::vector<RawAttr>& attrs) {
  for (const RawAttr& a : attrs) {
    if (internal::machinery_attribute(a.name)) continue;
    if (!internal::legal_netcdf_name(a.name)) {
      error("E33", path,
            "the attribute name \"" + a.name +
                "\" is not a legal netCDF-4 name");
    }
    if (a.type.klass == H5T_STRING) {
      if (a.type.variable_length) {
        error("E19", path,
              "the attribute \"" + a.name +
                  "\" is a variable-length string, which section 18 forbids "
                  "anywhere in the file");
        continue;
      }
      if (!is_null_sentinel_bytes(a.raw_bytes)) {
        if (internal::embedded_nul(a.raw_bytes)) {
          error("E26", path,
                "the attribute \"" + a.name +
                    "\" holds a NUL byte outside its trailing padding");
        } else if (!internal::valid_utf8(internal::strip_nul(a.raw_bytes))) {
          error("E26", path,
                "the attribute \"" + a.name + "\" is not valid UTF-8");
        }
      }
    }
    const Enc want = expected_encoding(a.name);
    if (want == Enc::None) continue;
    bool ok = true;
    switch (want) {
      case Enc::Text: ok = internal::is_spec_string(a.type); break;
      case Enc::Integer: ok = internal::is_spec_int64(a.type); break;
      case Enc::Real: ok = internal::is_spec_float64(a.type); break;
      case Enc::Boolean:
        ok = internal::is_spec_bool(a.type);
        if (ok && !a.raw_bytes.empty()) {
          const unsigned char v =
              static_cast<unsigned char>(a.raw_bytes[0]);
          ok = v == 0 || v == 1;
        }
        break;
      case Enc::None: break;
    }
    if (!ok) {
      error("E19", path,
            "the attribute \"" + a.name +
                "\" is not stored in the encoding section 18 requires");
    }
  }
}

void Validator::check_string_dataset(const std::string& path,
                                     const DsetInfo& info,
                                     bool warn_oversize) {
  if (info.type.klass != H5T_STRING) return;
  if (info.type.variable_length) {
    error("E19", path,
          "a variable-length string dataset, which section 18 forbids");
    return;
  }
  const std::vector<std::string> raw = raw_texts(path);
  std::size_t longest = 0;
  for (const std::string& s : raw) {
    if (internal::embedded_nul(s)) {
      error("E26", path,
            "an element holds a NUL byte outside its trailing padding");
    } else if (!internal::valid_utf8(internal::strip_nul(s))) {
      error("E26", path, "an element is not valid UTF-8");
    }
    longest = std::max(longest, internal::strip_nul(s).size());
  }
  if (longest == 0) longest = 1;
  if (warn_oversize && !raw.empty() && info.type.size > longest) {
    warn("W13", path,
         "the fixed-length string size is larger than the longest element "
         "needs");
  }
}

void Validator::check_dataset_storage(const std::string& path,
                                      const DsetInfo& info,
                                      bool is_row_dataset,
                                      std::size_t chunk_rows) {
  for (const auto& filter : info.filters) {
    const int id = filter.first;
    if (id == H5Z_FILTER_SHUFFLE) continue;
    if (id == H5Z_FILTER_DEFLATE) {
      const unsigned level = filter.second.empty() ? 0 : filter.second[0];
      if (level >= 1 && level <= 9) continue;
    }
    error("E29", path,
          "a filter other than gzip at level 1 to 9 and shuffle");
  }
  if (is_row_dataset && !info.chunked) {
    error("E27", path, "a row-dimensioned dataset that is not chunked");
  }
  if (chunk_rows == kNoChunkCheck || !is_row_dataset || !info.chunked) {
    return;
  }
  if (info.shape.empty() || info.chunk.empty()) return;
  std::size_t item = info.type.size;
  if (item == 0) item = 1;
  std::vector<std::size_t> rest(info.shape.begin() + 1, info.shape.end());
  std::vector<std::size_t> want;
  want.push_back(default_chunk_rows(item, rest, chunk_rows));
  for (const std::size_t e : rest) want.push_back(e);
  const std::vector<std::size_t> have(info.chunk.begin(), info.chunk.end());
  if (have != want) {
    warn("W12", path, "a chunk shape that is not the default of section 23");
  }
}

// --- passes -----------------------------------------------------------

void Validator::run() {
  for (const Member& m : f_.members("/supports")) {
    if (m.is_group) support_names_.push_back(m.name);
  }
  // Section 22: the support order is the group names sorted by their
  // UTF-8 bytes, which is the one ordering every language produces
  // identically.
  std::sort(support_names_.begin(), support_names_.end(), bytes_less);
  for (const Member& m : f_.members("/callables")) {
    if (m.is_group) callable_ids_.insert(m.name);
  }
  root();
  categories();
  keys();
  row_support_dataset();
  scalars();
  supports();
  callables();
}

void Validator::root() {
  const std::vector<RawAttr> attrs = f_.attributes("/");
  bool has_format = false;
  const std::string format = text_of(attrs, "format", &has_format);
  if (!has_format) {
    error("E01", "/", "the root `format` attribute is missing");
    error("E17", "/", "`format` is missing");
  } else {
    bool ok = format.compare(0, 7, "mestra/") == 0 && format.size() > 7;
    if (ok) {
      for (std::size_t i = 7; i < format.size(); ++i) {
        if (format[i] < '0' || format[i] > '9') ok = false;
      }
    }
    if (!ok) {
      error("E01", "/",
            "`format` is \"" + format + "\" and not \"mestra/<n>\"");
    } else if (format != "mestra/0") {
      error("E01", "/",
            "`format` is \"" + format +
                "\", a major version this reader must refuse");
    }
  }
  bool has_writer = false;
  text_of(attrs, "writer", &has_writer);
  if (!has_writer) error("E17", "/", "`writer` is missing");
  bool has_created = false;
  const std::string created = text_of(attrs, "created", &has_created);
  if (!has_created) {
    error("E17", "/", "`created` is missing");
  } else if (!internal::iso8601_utc(created)) {
    warn("W14", "/", "`created` is not an ISO 8601 UTC timestamp");
  }

  const RawAttr* aligned = find(attrs, "aligned");
  if (aligned == nullptr) {
    error("E39", "/", "`aligned` is missing");
  } else {
    aligned_ = aligned->value.kind() == AttrValue::Kind::Bool
                   ? aligned->value.as_bool()
                   : aligned->value.as_int() != 0;
  }
  check_attribute_encodings("/", attrs);

  for (const RawAttr& a : attrs) {
    if (internal::machinery_attribute(a.name)) continue;
    if (!internal::known_root_attribute(a.name)) {
      warn("W11", "/",
           "the root attribute \"" + a.name +
               "\" is one this version does not know; it is ignored");
    }
  }
  for (const Member& m : f_.members("/")) {
    if (m.is_group && !internal::known_root_group(m.name)) {
      warn("W11", "/" + m.name,
           "a root group this version does not know; it is ignored");
    }
  }
  // /notes is free-form, so nothing there is unknown (no W11), but
  // section 18 still holds: legal names, no variable-length string
  // anywhere in the file, and valid UTF-8.  /private is not looked at
  // at all, which section 29 requires.
  if (f_.is_group("/notes")) {
    check_attribute_encodings("/notes", f_.attributes("/notes"));
  }

  if (f_.is_dataset("/row")) {
    const DsetInfo info = f_.dataset_info("/row");
    n_rows_ = info.shape.empty()
                  ? 0
                  : static_cast<std::int64_t>(info.shape[0]);
    if (info.maxshape.empty() || info.maxshape[0] != H5S_UNLIMITED) {
      error("E27", "/row", "`row` is not an unlimited dimension");
    }
  } else {
    error("E39", "/", "the `row` dimension scale is missing");
  }
}

void Validator::categories() {
  for (const Member& m : f_.members("/categories")) {
    if (!m.is_dataset) continue;
    const std::string p = "/categories/" + m.name;
    const DsetInfo info = f_.dataset_info(p);
    if (!internal::legal_netcdf_name(m.name)) {
      error("E33", p, "\"" + m.name + "\" is not a legal netCDF-4 name");
    }
    if (internal::reserved_name(m.name)) {
      error("E33", p,
            "\"" + m.name + "\" begins with the reserved prefix mestra_");
    }
    if (info.type.klass != H5T_STRING) {
      error("E20", p, "a category table that is not a string dataset");
      continue;
    }
    check_string_dataset(p, info, true);
    category_tables_[m.name] = texts(p);
    axes_of(p, info, true);
    if (!info.scales.empty() && info.scales[0].size() == 1 &&
        info.scales[0].front() != "category_" + m.name) {
      error("E25", p,
            "the dimension scale on this table is not `category_" + m.name +
                "`");
    }
    check_dataset_storage(p, info, false, kNoChunkCheck);
  }
}

namespace {

struct KeyInfo {
  std::string name;
  std::string role;
  std::string category;
  std::string trajectory_group;
  DType dtype = DType::Float64;
  std::vector<double> f64;
  std::vector<std::int64_t> i64;
  bool has_lower = false;
  bool has_upper = false;
  double lower = 0.0;
  double upper = 0.0;
};

}  // namespace

void Validator::keys() {
  static const char* kRoles[] = {"design",      "condition", "time",
                                 "categorical", "group",     "split",
                                 "id",          "status"};
  std::map<std::string, int> role_count;
  std::vector<KeyInfo> infos;

  for (const Member& m : f_.members("/keys")) {
    if (!m.is_dataset) continue;
    const std::string p = "/keys/" + m.name;
    const DsetInfo info = f_.dataset_info(p);
    const std::vector<RawAttr> attrs = f_.attributes(p);
    check_attribute_encodings(p, attrs);
    if (!internal::legal_netcdf_name(m.name)) {
      error("E33", p, "\"" + m.name + "\" is not a legal netCDF-4 name");
    }
    if (internal::reserved_name(m.name)) {
      error("E33", p,
            "\"" + m.name + "\" begins with the reserved prefix mestra_");
    }
    for (const RawAttr& a : attrs) {
      if (internal::machinery_attribute(a.name)) continue;
      if (!internal::known_key_attribute(a.name)) {
        warn("W11", p,
             "the attribute \"" + a.name +
                 "\" is one this version does not know; it is ignored");
      }
    }

    KeyInfo k;
    k.name = m.name;
    bool has_role = false;
    k.role = text_of(attrs, "role", &has_role);
    bool known_role = false;
    for (const char* r : kRoles) {
      if (k.role == r) known_role = true;
    }
    if (!has_role || !known_role) {
      error("E02", p,
            has_role ? "the role \"" + k.role + "\" is not in section 3"
                     : "no role attribute");
      k.role.clear();
    } else {
      role_count[k.role] += 1;
    }

    bool has_units = false;
    const std::string units = text_of(attrs, "units", &has_units);
    if (k.role == "design" || k.role == "condition" || k.role == "time") {
      if (!has_units) {
        error("E39", p, "a " + k.role + " key with no `units`");
      }
    }
    if (has_units && !units_parse(units)) {
      warn("W10", p, "the units string \"" + units + "\" does not parse");
    }

    bool has_category = false;
    k.category = text_of(attrs, "category", &has_category);
    if ((k.role == "categorical" || k.role == "group" ||
         k.role == "split" || k.role == "status") &&
        !has_category) {
      error("E39", p, "a " + k.role + " key with no `category`");
    }
    k.trajectory_group = text_of(attrs, "trajectory_group");

    DType dtype = DType::Float64;
    const bool dtype_ok = internal::dtype_of(info.type, &dtype);
    k.dtype = dtype;
    if (!k.role.empty()) {
      bool allowed = true;
      if (k.role == "design" || k.role == "condition" || k.role == "time") {
        allowed = dtype_ok && dtype == DType::Float64;
      } else if (k.role == "categorical" || k.role == "group" ||
                 k.role == "split" || k.role == "status") {
        allowed = dtype_ok &&
                  (dtype == DType::Int32 || dtype == DType::Int64);
      } else if (k.role == "id") {
        allowed = dtype_ok &&
                  (dtype == DType::Int64 || dtype == DType::String);
      }
      if (!allowed) {
        error("E20", p,
              "the dtype is not one section 19 allows for role " + k.role);
      }
    }

    const RawAttr* lower = find(attrs, "lower");
    const RawAttr* upper = find(attrs, "upper");
    if (lower != nullptr) {
      k.has_lower = true;
      k.lower = lower->value.as_float();
    }
    if (upper != nullptr) {
      k.has_upper = true;
      k.upper = upper->value.as_float();
    }

    axes_of(p, info, true);
    if (!info.scales.empty() && info.scales[0].size() == 1 &&
        info.scales[0].front() != "row") {
      error("E25", p, "the dimension of a key is not `row`");
    }
    if (info.shape.size() != 1) {
      error("E39", p, "a key must have exactly one dimension, `row`");
    } else if (static_cast<std::int64_t>(info.shape[0]) != n_rows_) {
      error("E16", p,
            "a key of " +
                internal::format_i64(
                    static_cast<std::int64_t>(info.shape[0])) +
                " elements in a file of " + internal::format_i64(n_rows_) +
                " rows");
    }
    check_dataset_storage(p, info, true,
                          static_cast<std::size_t>(n_rows_));
    if (dtype == DType::String) check_string_dataset(p, info, true);

    if (dtype == DType::Float64) {
      k.f64 = reals(p);
    } else if (dtype != DType::String) {
      k.i64 = integers(p);
    }
    infos.push_back(std::move(k));
  }

  for (const char* role : {"time", "split", "id", "status"}) {
    if (role_count[role] > 1) {
      error("E03", "/keys",
            "more than one key with the role " + std::string(role));
    }
  }
  has_group_key_ = role_count["group"] > 0;

  const std::vector<RawAttr> root_attrs = f_.attributes("/");
  const bool has_gen = find(root_attrs, "generalisation_group") != nullptr;
  if (has_group_key_ && !has_gen) {
    // Section 19 requires the attribute (E39), and section 14 makes
    // the unit of generalisation public information: a file that
    // declares a group key and names it nowhere public breaks E18 as
    // well, which a validator sees from the missing public attribute
    // alone and never by interpreting /private.
    error("E39", "/",
          "the file declares a group key and no `generalisation_group`");
    error("E18", "/",
          "the unit of generalisation is public information and this file "
          "names it nowhere public");
  }

  const KeyInfo* time_key = nullptr;
  const KeyInfo* split_key = nullptr;
  const KeyInfo* status_key = nullptr;
  for (const KeyInfo& k : infos) {
    if (k.role == "time") time_key = &k;
    if (k.role == "split") split_key = &k;
    if (k.role == "status") status_key = &k;
  }
  if (time_key != nullptr && has_group_key_ &&
      time_key->trajectory_group.empty()) {
    error("E39", "/keys/" + time_key->name,
          "the time key names no `trajectory_group` in a file that declares "
          "a group key");
  }

  for (const KeyInfo& k : infos) {
    const std::string p = "/keys/" + k.name;
    if ((k.role == "categorical" || k.role == "group" ||
         k.role == "split" || k.role == "status") &&
        !k.category.empty()) {
      const auto it = category_tables_.find(k.category);
      if (it == category_tables_.end()) {
        error("E39", p,
              "the category table \"" + k.category +
                  "\" is not in the file");
      } else {
        const std::int64_t n = static_cast<std::int64_t>(it->second.size());
        bool outside = false;
        for (const std::int64_t v : k.i64) {
          if (v < 0 || v >= n) outside = true;
        }
        if (outside) error("E10", p, "a value outside its category table");
        if (k.role == "group") {
          const std::set<std::int64_t> used(k.i64.begin(), k.i64.end());
          for (std::int64_t i = 0; i < n; ++i) {
            if (used.count(i) == 0) {
              warn("W07", p,
                   "the category table has an entry no row uses: \"" +
                       it->second[static_cast<std::size_t>(i)] + "\"");
              break;
            }
          }
        }
      }
    }

    if (k.dtype == DType::Float64 && (k.has_lower || k.has_upper)) {
      bool outside = false;
      double lo = 0.0;
      double hi = 0.0;
      bool any = false;
      for (const double v : k.f64) {
        if (!std::isfinite(v)) continue;
        if (k.has_lower && v < k.lower) outside = true;
        if (k.has_upper && v > k.upper) outside = true;
        if (!any) {
          lo = v;
          hi = v;
          any = true;
        } else {
          lo = std::min(lo, v);
          hi = std::max(hi, v);
        }
      }
      if (outside) {
        warn("W04", p, "a key value outside its declared bounds");
      } else if (k.has_lower && k.has_upper && any && n_rows_ > 0) {
        // Decision 20: more than a factor of four in width.  A value
        // outside the bounds is W04 and not W08.
        if ((k.upper - k.lower) > 4.0 * (hi - lo)) {
          warn("W08", p,
               "declared bounds more than four times wider than the "
               "observed range");
        }
      }
    }
  }

  if (time_key != nullptr) {
    const KeyInfo* group = nullptr;
    for (const KeyInfo& k : infos) {
      if (k.name == time_key->trajectory_group) group = &k;
    }
    std::map<std::int64_t, double> last;
    bool bad = false;
    for (std::size_t i = 0; i < time_key->f64.size(); ++i) {
      const std::int64_t g =
          (group != nullptr && i < group->i64.size()) ? group->i64[i] : 0;
      const auto it = last.find(g);
      if (it != last.end() && !(time_key->f64[i] > it->second)) bad = true;
      last[g] = time_key->f64[i];
    }
    if (bad) {
      error("E09", "/keys/" + time_key->name,
            "time is not strictly increasing within a trajectory");
    }
  }

  if (status_key != nullptr && !status_key->category.empty()) {
    const auto it = category_tables_.find(status_key->category);
    if (it != category_tables_.end()) {
      std::int64_t converged = -1;
      for (std::size_t i = 0; i < it->second.size(); ++i) {
        if (it->second[i] == "converged") {
          converged = static_cast<std::int64_t>(i);
        }
      }
      for (const std::int64_t v : status_key->i64) {
        if (v != converged) {
          warn("W02", "/keys/" + status_key->name,
               "a row whose status is not converged");
          break;
        }
      }
    }
  }

  if (split_key != nullptr) {
    const std::string gen = text_of(root_attrs, "generalisation_group");
    const KeyInfo* unit = nullptr;
    for (const KeyInfo& k : infos) {
      if (k.name == gen && k.role == "group") unit = &k;
    }
    if (unit != nullptr) {
      std::map<std::int64_t, std::set<std::int64_t>> sides;
      const std::size_t n =
          std::min(unit->i64.size(), split_key->i64.size());
      for (std::size_t i = 0; i < n; ++i) {
        sides[unit->i64[i]].insert(split_key->i64[i]);
      }
      for (const auto& entry : sides) {
        if (entry.second.size() > 1) {
          warn("W01", "/keys/" + split_key->name,
               "the split places rows of one generalisation unit on both "
               "sides");
          break;
        }
      }
    }
  }
}

void Validator::scalars() {
  for (const Member& m : f_.members("/scalars")) {
    const std::string p = "/scalars/" + m.name;
    const std::vector<RawAttr> attrs = f_.attributes(p);
    check_attribute_encodings(p, attrs);
    if (!internal::legal_netcdf_name(m.name)) {
      error("E33", p, "\"" + m.name + "\" is not a legal netCDF-4 name");
    }
    if (internal::reserved_name(m.name)) {
      error("E33", p,
            "\"" + m.name + "\" begins with the reserved prefix mestra_");
    }
    for (const RawAttr& a : attrs) {
      if (internal::machinery_attribute(a.name)) continue;
      if (!internal::known_scalar_attribute(a.name)) {
        warn("W11", p,
             "the attribute \"" + a.name +
                 "\" is one this version does not know; it is ignored");
      }
    }

    bool has_units = false;
    const std::string units = text_of(attrs, "units", &has_units);
    if (!has_units) {
      error("E11", p, "a scalar with no `units`");
    } else if (!units_parse(units)) {
      warn("W10", p, "the units string \"" + units + "\" does not parse");
    }

    bool has_source = false;
    const std::string source = text_of(attrs, "source", &has_source);
    if (!has_source) {
      error("E39", p, "a scalar with no `source`");
    } else {
      const std::string id = internal::callable_of_source(source);
      if (source != "data" && id.empty()) {
        error("E36", p,
              "`source` is \"" + source +
                  "\", which is neither `data` nor `callable:<id>`");
      } else if (!id.empty()) {
        if (callable_ids_.count(id) == 0) {
          error("E14", p,
                "`source` names the callable \"" + id +
                    "\", which the file does not hold");
        }
        if (find(attrs, "output") == nullptr) {
          error("E39", p, "a callable-served slot with no `output`");
        }
        if (m.is_dataset) {
          error("E30", p, "a callable-served slot stored as a dataset");
        }
      } else if (source == "data" && m.is_group) {
        error("E30", p, "a slot whose source is data stored as a group");
      }
    }

    const std::string statistic = text_of(attrs, "statistic");
    if (!statistic.empty()) {
      if (statistic == "quantile" && find(attrs, "quantile") == nullptr) {
        error("E12", p, "a quantile statistic with no `quantile`");
      }
      if (statistic != "value" && statistic != "draw" &&
          find(attrs, "of") == nullptr) {
        error("E12", p, "a statistic other than value or draw with no `of`");
      }
    }

    if (!m.is_dataset) continue;
    const DsetInfo info = f_.dataset_info(p);
    DType dtype = DType::Float64;
    if (!internal::dtype_of(info.type, &dtype) || dtype != DType::Float64) {
      error("E20", p, "a scalar that is not float64");
    }
    axes_of(p, info, true);
    if (!info.scales.empty() && info.scales[0].size() == 1 &&
        info.scales[0].front() != "row") {
      error("E25", p, "the dimension of a scalar is not `row`");
    }
    if (info.shape.size() != 1) {
      error("E39", p, "a scalar must have exactly one dimension, `row`");
    } else if (static_cast<std::int64_t>(info.shape[0]) != n_rows_) {
      error("E16", p,
            "a scalar of " +
                internal::format_i64(
                    static_cast<std::int64_t>(info.shape[0])) +
                " elements in a file of " + internal::format_i64(n_rows_) +
                " rows");
    }
    check_dataset_storage(p, info, true,
                          static_cast<std::size_t>(n_rows_));
    if (dtype == DType::Float64) {
      for (const double v : reals(p)) {
        if (!std::isfinite(v)) {
          warn("W03", p, "a non-finite value in a scalar");
          break;
        }
      }
    }
  }
}

void Validator::row_support_dataset() {
  has_row_support_ = f_.is_dataset("/row_support");
  const std::size_t n_supports = support_names_.size();
  if (has_row_support_ && aligned_) {
    error("E28", "/row_support",
          "/row_support is present in a file that sets aligned = true");
  }
  if (!has_row_support_ && !aligned_) {
    error("E28", "/",
          "/row_support is absent in a file that sets aligned = false");
  }
  if (aligned_ != (n_supports <= 1)) {
    error("E37", "/",
          "`aligned` disagrees with the " +
              internal::format_i64(static_cast<std::int64_t>(n_supports)) +
              " supports the file declares");
  }
  if (n_supports > 1) {
    warn("W05", "/supports",
         "the file declares more than one support, so index-aligned "
         "operations are not available");
  }
  if (!has_row_support_) return;

  const std::string p = "/row_support";
  const DsetInfo info = f_.dataset_info(p);
  DType dtype = DType::Float64;
  if (!internal::dtype_of(info.type, &dtype) || dtype != DType::Int32) {
    error("E20", p, "/row_support must be int32");
  }
  axes_of(p, info, true);
  if (!info.scales.empty() && info.scales[0].size() == 1 &&
      info.scales[0].front() != "row") {
    error("E25", p, "the dimension of /row_support is not `row`");
  }
  if (!info.shape.empty() &&
      static_cast<std::int64_t>(info.shape[0]) != n_rows_) {
    error("E16", p, "/row_support does not have one entry per row");
  }
  check_dataset_storage(p, info, true, static_cast<std::size_t>(n_rows_));
  row_support_ = integers(p);
  std::set<std::int64_t> used;
  for (const std::int64_t v : row_support_) {
    if (v < 0 || v >= static_cast<std::int64_t>(n_supports)) {
      error("E06", p,
            "a row references support " + internal::format_i64(v) +
                ", which the file does not declare");
    } else {
      used.insert(v);
    }
  }
  for (std::size_t i = 0; i < n_supports; ++i) {
    if (used.count(static_cast<std::int64_t>(i)) == 0) {
      warn("W15", "/supports/" + support_names_[i],
           "a declared support that no row references");
    }
  }
}

void Validator::supports() {
  for (std::size_t index = 0; index < support_names_.size(); ++index) {
    const std::string name = support_names_[index];
    const std::string sp = "/supports/" + name;
    const std::vector<RawAttr> attrs = f_.attributes(sp);
    check_attribute_encodings(sp, attrs);
    if (!internal::legal_netcdf_name(name)) {
      error("E33", sp, "\"" + name + "\" is not a legal netCDF-4 name");
    }
    if (internal::reserved_name(name)) {
      error("E33", sp,
            "\"" + name + "\" begins with the reserved prefix mestra_");
    }
    for (const RawAttr& a : attrs) {
      if (internal::machinery_attribute(a.name)) continue;
      if (!internal::known_support_attribute(a.name)) {
        warn("W11", sp,
             "the attribute \"" + a.name +
                 "\" is one this version does not know; it is ignored");
      }
    }
    for (const Member& g : f_.members(sp)) {
      if (g.is_group && !internal::known_support_group(g.name)) {
        warn("W11", sp + "/" + g.name,
             "a group inside a support this version does not know");
      }
    }

    bool has_kind = false;
    const std::string kind = text_of(attrs, "kind", &has_kind);
    if (!has_kind) error("E39", sp, "a support with no `kind`");
    const RawAttr* n_nodes_attr = find(attrs, "n_nodes");
    const RawAttr* n_cells_attr = find(attrs, "n_cells");
    if (n_nodes_attr == nullptr) error("E39", sp, "no `n_nodes`");
    if (n_cells_attr == nullptr) error("E39", sp, "no `n_cells`");
    bool has_sid = false;
    const std::string stored_sid = text_of(attrs, "support_id", &has_sid);
    if (!has_sid) error("E39", sp, "a support with no `support_id`");
    const std::int64_t n_nodes =
        n_nodes_attr != nullptr ? n_nodes_attr->value.as_int() : 0;
    const std::int64_t n_cells =
        n_cells_attr != nullptr ? n_cells_attr->value.as_int() : 0;

    const bool has_types = f_.is_dataset(sp + "/cell_types");
    const bool has_offsets = f_.is_dataset(sp + "/cell_offsets");
    const bool has_conn = f_.is_dataset(sp + "/cell_connectivity");
    if (kind == "mesh") {
      if (!has_types || !has_offsets || !has_conn) {
        error("E38", sp,
              "a mesh support missing cell_types, cell_offsets or "
              "cell_connectivity");
      }
    } else if (kind == "axis" || kind == "none") {
      if (has_types || has_offsets || has_conn ||
          f_.is_dataset(sp + "/cell")) {
        error("E38", sp,
              "a support of kind " + kind + " carrying cell arrays");
      }
    }

    std::vector<std::uint8_t> types;
    std::vector<std::int64_t> offsets;
    std::vector<std::int64_t> conn;
    if (has_types) {
      const std::string p = sp + "/cell_types";
      const DsetInfo info = f_.dataset_info(p);
      DType dtype = DType::Float64;
      if (!internal::dtype_of(info.type, &dtype) || dtype != DType::UInt8) {
        error("E20", p, "cell_types must be uint8");
      }
      axes_of(p, info, true);
      if (!info.scales.empty() && info.scales[0].size() == 1 &&
          info.scales[0].front() != "cell") {
        error("E25", p, "the dimension of cell_types is not `cell`");
      }
      check_dataset_storage(p, info, false, kNoChunkCheck);
      for (const std::int64_t v : integers(p)) {
        types.push_back(static_cast<std::uint8_t>(v));
      }
    }
    if (has_offsets) {
      const std::string p = sp + "/cell_offsets";
      const DsetInfo info = f_.dataset_info(p);
      DType dtype = DType::Float64;
      if (!internal::dtype_of(info.type, &dtype) || dtype != DType::Int64) {
        error("E20", p, "cell_offsets must be int64");
      }
      axes_of(p, info, true);
      if (!info.scales.empty() && info.scales[0].size() == 1 &&
          info.scales[0].front() != "cell_plus_one") {
        error("E25", p,
              "the dimension of cell_offsets is not `cell_plus_one`");
      }
      check_dataset_storage(p, info, false, kNoChunkCheck);
      offsets = integers(p);
    }
    if (has_conn) {
      const std::string p = sp + "/cell_connectivity";
      const DsetInfo info = f_.dataset_info(p);
      DType dtype = DType::Float64;
      if (!internal::dtype_of(info.type, &dtype) || dtype != DType::Int64) {
        error("E20", p, "cell_connectivity must be int64");
      }
      axes_of(p, info, true);
      if (!info.scales.empty() && info.scales[0].size() == 1 &&
          info.scales[0].front() != "index") {
        error("E25", p,
              "the dimension of cell_connectivity is not `index`");
      }
      check_dataset_storage(p, info, false, kNoChunkCheck);
      conn = integers(p);
    }

    bool bad_code = false;
    for (const std::uint8_t code : types) {
      if (cell_type_nodes(code) < 0) bad_code = true;
    }
    if (bad_code) {
      error("E21", sp + "/cell_types",
            "a cell type code that is not in the table of section 20");
    }
    if (has_offsets) {
      bool bad = offsets.empty() || offsets.front() != 0;
      for (std::size_t i = 1; i < offsets.size(); ++i) {
        if (offsets[i] < offsets[i - 1]) bad = true;
      }
      if (!offsets.empty() && has_conn &&
          offsets.back() != static_cast<std::int64_t>(conn.size())) {
        bad = true;
      }
      if (bad) {
        error("E23", sp + "/cell_offsets",
              "cell_offsets does not start at 0, is not non-decreasing, or "
              "does not end at the length of cell_connectivity");
      } else if (has_types && offsets.size() == types.size() + 1) {
        bool bad_count = false;
        for (std::size_t j = 0; j < types.size(); ++j) {
          const int want = cell_type_nodes(types[j]);
          if (want < 0) continue;
          const std::int64_t got = offsets[j + 1] - offsets[j];
          if (types[j] == 7) {
            if (got < 3) bad_count = true;
          } else if (got != want) {
            bad_count = true;
          }
        }
        if (bad_count) {
          error("E22", sp + "/cell_offsets",
                "a cell whose node count disagrees with its cell type");
        }
      }
    }
    for (const std::int64_t v : conn) {
      if (v < 0 || v >= n_nodes) {
        error("E24", sp + "/cell_connectivity",
              "a connectivity value outside [0, n_nodes)");
        break;
      }
    }

    const bool has_coordinates = f_.is_dataset(sp + "/coordinates") ||
                                 f_.is_group(sp + "/coordinates");
    if ((kind == "mesh" || kind == "axis") && !has_coordinates) {
      error("E03", sp, "a " + kind + " support with no coordinates array");
    }
    if (has_coordinates) {
      slot(sp + "/coordinates", kind, n_nodes, n_cells, index, true);
    }
    for (int which = 0; which < 2; ++which) {
      const std::string gp =
          sp + (which == 0 ? "/node_arrays" : "/cell_arrays");
      for (const Member& a : f_.members(gp)) {
        slot(gp + "/" + a.name, kind, n_nodes, n_cells, index, false);
      }
    }

    if (has_sid) {
      // Section 24: the kind decides which arrays are hashed, so a
      // file that wrongly puts cell arrays on an axis support breaks
      // E38 and not E08 as well.
      std::string computed;
      const std::vector<std::uint8_t> no_types;
      const std::vector<std::int64_t> no_ints;
      if (kind == "axis" && f_.is_dataset(sp + "/coordinates")) {
        const std::vector<double> coords = reals(sp + "/coordinates");
        computed =
            support_id_digest(n_nodes, no_types, no_ints, no_ints, &coords);
      } else if (kind == "axis" || kind == "none") {
        computed =
            support_id_digest(n_nodes, no_types, no_ints, no_ints, nullptr);
      } else {
        computed = support_id_digest(n_nodes, types, offsets, conn, nullptr);
      }
      if (computed != stored_sid) {
        error("E08", sp,
              "the stored support_id does not match the stored arrays");
      }
    }
  }
}

void Validator::slot(const std::string& path,
                     const std::string& support_kind, std::int64_t n_nodes,
                     std::int64_t n_cells, std::size_t support_index,
                     bool is_coordinates) {
  const bool is_dataset = f_.is_dataset(path);
  const std::vector<RawAttr> attrs = f_.attributes(path);
  check_attribute_encodings(path, attrs);
  const std::string name = internal::basename(path);
  if (!internal::legal_netcdf_name(name)) {
    error("E33", path, "\"" + name + "\" is not a legal netCDF-4 name");
  }
  if (internal::reserved_name(name)) {
    error("E33", path,
          "\"" + name + "\" begins with the reserved prefix mestra_");
  }
  for (const RawAttr& a : attrs) {
    if (internal::machinery_attribute(a.name)) continue;
    if (!internal::known_array_attribute(a.name)) {
      warn("W11", path,
           "the attribute \"" + a.name +
               "\" is one this version does not know; it is ignored");
    }
  }

  static const char* kRoles[] = {"coordinates", "field",  "label",
                                 "weight",      "normal", "derived"};
  bool has_role = false;
  const std::string role = text_of(attrs, "role", &has_role);
  bool known_role = false;
  for (const char* r : kRoles) {
    if (role == r) known_role = true;
  }
  if (!has_role || !known_role) {
    error("E02", path,
          has_role ? "the role \"" + role + "\" is not in section 3"
                   : "no role attribute");
  }

  bool has_varies = false;
  const std::string varies = text_of(attrs, "varies", &has_varies);
  if (!has_varies) error("E39", path, "no `varies`");

  bool has_units = false;
  const std::string units = text_of(attrs, "units", &has_units);
  if (role == "field") {
    if (!has_units) error("E11", path, "a field with no `units`");
  } else if (role == "derived" || role == "coordinates") {
    if (!has_units) {
      error("E39", path, "a " + role + " array with no `units`");
    }
  }
  if (has_units && !units_parse(units)) {
    warn("W10", path, "the units string \"" + units + "\" does not parse");
  }

  if (role == "derived" && (find(attrs, "derived_from") == nullptr ||
                            find(attrs, "recipe") == nullptr)) {
    error("E13", path, "a derived array without `derived_from` and `recipe`");
  }
  if (role == "weight" || role == "normal") {
    const RawAttr* r = find(attrs, "recomputed");
    const bool marked =
        r != nullptr && (r->value.kind() == AttrValue::Kind::Bool
                             ? r->value.as_bool()
                             : r->value.as_int() != 0);
    if (!marked) {
      warn("W06", path,
           "a " + role + " array that does not say it was recomputed");
    }
  }

  const std::string statistic = text_of(attrs, "statistic");
  if (!statistic.empty()) {
    if (statistic == "quantile" && find(attrs, "quantile") == nullptr) {
      error("E12", path, "a quantile statistic with no `quantile`");
    }
    if (statistic != "value" && statistic != "draw" &&
        find(attrs, "of") == nullptr) {
      error("E12", path, "a statistic other than value or draw with no `of`");
    }
  }

  bool has_source = false;
  const std::string source = text_of(attrs, "source", &has_source);
  if (!has_source) {
    error("E39", path, "no `source`");
  } else {
    const std::string id = internal::callable_of_source(source);
    if (source != "data" && id.empty()) {
      error("E36", path,
            "`source` is \"" + source +
                "\", which is neither `data` nor `callable:<id>`");
    } else if (!id.empty()) {
      if (callable_ids_.count(id) == 0) {
        error("E14", path,
              "`source` names the callable \"" + id +
                  "\", which the file does not hold");
      }
      if (find(attrs, "output") == nullptr) {
        error("E39", path, "a callable-served slot with no `output`");
      }
      if (is_dataset) {
        error("E30", path, "a callable-served slot stored as a dataset");
      }
    } else if (source == "data" && !is_dataset) {
      error("E30", path, "a slot whose source is data stored as a group");
    }
  }

  const RawAttr* components_attr = find(attrs, "components");
  if (components_attr == nullptr) {
    error("E31", path, "an array slot with no `components`");
  }
  const std::int64_t components =
      components_attr != nullptr ? components_attr->value.as_int() : -1;

  if (is_coordinates && support_kind == "axis" && has_varies &&
      varies != "none") {
    error("E35", path,
          "an axis support's coordinates must have varies = none");
  }

  if (!is_dataset) return;
  const DsetInfo info = f_.dataset_info(path);
  const Axes axes = axes_of(path, info, true);

  DType dtype = DType::Float64;
  const bool dtype_ok = internal::dtype_of(info.type, &dtype);
  if (role == "coordinates" || role == "field" || role == "derived" ||
      role == "weight" || role == "normal") {
    if (!dtype_ok || dtype != DType::Float64) {
      error("E20", path, "an array with role " + role + " must be float64");
    }
  } else if (role == "label") {
    if (!dtype_ok || (dtype != DType::Int32 && dtype != DType::Int64)) {
      error("E20", path, "a label must be int32 or int64");
    }
  }

  const std::string leading = axes.logical.empty() ? "" : axes.logical[0];
  if (has_varies && !axes.logical.empty()) {
    if (varies == "none") {
      if (leading == "row" || leading.compare(0, 6, "group:") == 0) {
        error("E04", path,
              "`varies` is none and the leading dimension is \"" + leading +
                  "\"");
      }
    } else if (varies == "row") {
      if (leading != "row") {
        error("E04", path,
              "`varies` is row and the leading dimension is \"" + leading +
                  "\"");
      }
    } else if (varies.compare(0, 6, "group:") == 0 && leading != varies) {
      error("E04", path,
            "`varies` is \"" + varies + "\" and the leading dimension is \"" +
                leading + "\"");
    }
  }

  const int node_axis = axes.index_of("node");
  const int cell_axis = axes.index_of("cell");
  if (node_axis >= 0 &&
      static_cast<std::int64_t>(
          axes.extent[static_cast<std::size_t>(node_axis)]) != n_nodes) {
    error("E05", path, "the node count disagrees with the support");
  }
  if (cell_axis >= 0 &&
      static_cast<std::int64_t>(
          axes.extent[static_cast<std::size_t>(cell_axis)]) != n_cells) {
    error("E05", path, "the cell count disagrees with the support");
  }

  const int comp_axis = axes.index_of("component");
  if (comp_axis >= 0 && components >= 0 &&
      static_cast<std::int64_t>(
          axes.extent[static_cast<std::size_t>(comp_axis)]) != components) {
    error("E31", path,
          "`components` disagrees with the length of the component "
          "dimension");
  }

  if (varies.compare(0, 6, "group:") == 0 && !axes.extent.empty()) {
    const std::string key = varies.substr(6);
    const std::vector<RawAttr> key_attrs =
        f_.is_dataset("/keys/" + key) ? f_.attributes("/keys/" + key)
                                      : std::vector<RawAttr>();
    const std::string table = text_of(key_attrs, "category");
    const auto it = category_tables_.find(table);
    if (it != category_tables_.end() && axes.extent[0] != it->second.size()) {
      error("E34", path,
            "the leading dimension differs from the number of categories of "
            "the group key");
    }
  }

  const bool row_leading = leading == "row";
  std::size_t want_rows = static_cast<std::size_t>(n_rows_);
  if (row_leading && !aligned_ && has_row_support_) {
    want_rows = 0;
    for (const std::int64_t v : row_support_) {
      if (v == static_cast<std::int64_t>(support_index)) ++want_rows;
    }
  }
  if (row_leading && !axes.extent.empty() && axes.extent[0] != want_rows) {
    error("E16", path,
          "the leading dimension does not match the number of rows this "
          "slot must have");
  }

  check_dataset_storage(path, info, row_leading,
                        row_leading ? want_rows : kNoChunkCheck);

  if (role == "field" && dtype_ok && dtype == DType::Float64) {
    for (const double v : reals(path)) {
      if (!std::isfinite(v)) {
        warn("W03", path, "a non-finite value in a field");
        break;
      }
    }
  }

  if (role == "label") {
    const std::string table = text_of(attrs, "category");
    if (!table.empty()) {
      const auto it = category_tables_.find(table);
      if (it == category_tables_.end()) {
        error("E39", path,
              "the category table \"" + table + "\" is not in the file");
      } else {
        const std::int64_t n = static_cast<std::int64_t>(it->second.size());
        for (const std::int64_t v : integers(path)) {
          if (v < 0 || v >= n) {
            error("E10", path, "a label value outside its category table");
            break;
          }
        }
      }
    }
  }
}

void Validator::callables() {
  for (const Member& m : f_.members("/callables")) {
    if (!m.is_group) continue;
    const std::string p = "/callables/" + m.name;
    const std::vector<RawAttr> attrs = f_.attributes(p);
    if (!internal::legal_netcdf_name(m.name)) {
      error("E33", p, "\"" + m.name + "\" is not a legal netCDF-4 name");
    }
    if (internal::reserved_name(m.name)) {
      error("E33", p,
            "\"" + m.name + "\" begins with the reserved prefix mestra_");
    }
    if (find(attrs, "type") == nullptr) {
      error("E15", p, "a callable group with no `type`");
    }
    check_dict(p, true);
  }
}

void Validator::check_dict(const std::string& path, bool top_level) {
  // A callable's dictionary is opaque to a reader that does not own its
  // type, so nothing here interprets it: these are the rules of
  // section 25 about what is representable at all.
  for (const RawAttr& a : f_.attributes(path)) {
    if (internal::machinery_attribute(a.name)) continue;
    if (internal::reserved_name(a.name)) continue;
    if (top_level && (a.name == "type" || a.name == "repr")) {
      if (!internal::is_spec_string(a.type)) {
        error("E19", path,
              "the attribute \"" + a.name +
                  "\" is not stored in the encoding section 18 requires");
      }
      continue;
    }
    if (!internal::legal_netcdf_name(a.name)) {
      error("E33", path,
            "the dictionary key \"" + a.name +
                "\" is not a legal netCDF-4 name");
    }
    if (a.type.klass == H5T_STRING) {
      if (a.type.variable_length) {
        error("E19", path,
              "the dictionary entry \"" + a.name +
                  "\" is a variable-length string");
      } else if (!is_null_sentinel_bytes(a.raw_bytes)) {
        if (internal::embedded_nul(a.raw_bytes)) {
          error("E32", path,
                "the dictionary string \"" + a.name +
                    "\" holds an embedded NUL");
        } else if (!internal::valid_utf8(internal::strip_nul(a.raw_bytes))) {
          error("E26", path,
                "the dictionary string \"" + a.name + "\" is not valid "
                                                      "UTF-8");
        }
      }
      continue;
    }
    // Section 25: int8 is a boolean, int64 an integer, float64 a
    // float.  Anything else is not representable.
    const bool ok = internal::is_spec_bool(a.type) ||
                    internal::is_spec_int64(a.type) ||
                    internal::is_spec_float64(a.type);
    if (!ok) {
      error("E32", path,
            "the dictionary entry \"" + a.name +
                "\" is stored in a type section 25 does not allow");
    }
  }

  for (const Member& m : f_.members(path)) {
    if (internal::reserved_name(m.name)) continue;
    const std::string child = path + "/" + m.name;
    if (!internal::legal_netcdf_name(m.name)) {
      error("E33", child,
            "the dictionary key \"" + m.name +
                "\" is not a legal netCDF-4 name");
    }
    if (m.is_group) {
      check_dict(child, false);
      continue;
    }
    if (!m.is_dataset) continue;
    const DsetInfo info = f_.dataset_info(child);
    if (info.shape.empty()) {
      error("E32", child,
            "a zero-dimensional dataset, which section 25 requires to be "
            "written as an attribute");
      continue;
    }
    DType dtype = DType::Float64;
    const bool ok = internal::dtype_of(info.type, &dtype) &&
                    (dtype == DType::Bool || dtype == DType::Int32 ||
                     dtype == DType::Int64 || dtype == DType::Float64 ||
                     dtype == DType::String);
    if (!ok) {
      error("E32", child,
            "a dtype section 25 does not allow inside a dictionary");
      continue;
    }
    if (dtype == DType::String) check_string_dataset(child, info, true);
    const Axes axes = axes_of(child, info, true);
    for (std::size_t axis = 0; axis < info.shape.size(); ++axis) {
      if (info.scales[axis].size() != 1) continue;
      const std::string want =
          "mestra_" + m.name + "_d" +
          internal::format_i64(static_cast<std::int64_t>(axis));
      if (info.scales[axis].front() != want) {
        error("E25", child,
              "axis " + internal::format_i64(
                            static_cast<std::int64_t>(axis)) +
                  " does not carry the scale `" + want + "`");
      }
    }
    (void)axes;
    check_dataset_storage(child, info, false, kNoChunkCheck);
  }
}

}  // namespace

Report validate(const std::string& path) {
  Report r;
  try {
    File f;
    try {
      f = File::open_read(path);
    } catch (const Error& e) {
      // A file this reader cannot open as HDF5 at all has no `format`
      // and no `writer` or `created` either, which is what a reader
      // would say about any other file missing them.
      r.errors.push_back({"E01", path, e.what()});
      r.errors.push_back({"E17", path, "the file carries no root "
                                       "attributes this reader can read"});
      return r;
    }
    Validator v(f, &r);
    v.run();
  } catch (const Error& e) {
    r.errors.push_back({e.rule(), path, e.what()});
  } catch (const std::exception& e) {
    r.errors.push_back({std::string(), path, e.what()});
  }
  return r;
}

std::vector<std::string> Report::error_ids() const {
  std::vector<std::string> ids;
  for (const Finding& f : errors) {
    if (!f.id.empty()) ids.push_back(f.id);
  }
  std::sort(ids.begin(), ids.end());
  ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
  return ids;
}

std::vector<std::string> Report::warning_ids() const {
  std::vector<std::string> ids;
  for (const Finding& f : warnings) {
    if (!f.id.empty()) ids.push_back(f.id);
  }
  std::sort(ids.begin(), ids.end());
  ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
  return ids;
}

}  // namespace mestra
