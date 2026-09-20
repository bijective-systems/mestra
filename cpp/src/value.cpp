#include "mestra/value.hpp"

#include <algorithm>
#include <cstring>
#include <stdexcept>

#include "mestra/io.hpp"
#include "names.hpp"

namespace mestra {

bool bytes_less(const std::string& a, const std::string& b) {
  const std::size_t n = std::min(a.size(), b.size());
  for (std::size_t i = 0; i < n; ++i) {
    const unsigned char ca = static_cast<unsigned char>(a[i]);
    const unsigned char cb = static_cast<unsigned char>(b[i]);
    if (ca != cb) return ca < cb;
  }
  return a.size() < b.size();
}

const char* dtype_name(DType t) {
  switch (t) {
    case DType::Bool: return "bool";
    case DType::UInt8: return "uint8";
    case DType::Int32: return "int32";
    case DType::Int64: return "int64";
    case DType::Float64: return "float64";
    case DType::String: return "string";
  }
  return "?";
}

// --- Array -----------------------------------------------------------

std::size_t Array::size() const {
  std::size_t n = 1;
  for (const std::size_t e : shape) n *= e;
  return shape.empty() ? 1 : n;
}

namespace {
std::size_t flat_index(const std::vector<std::size_t>& shape,
                       const std::vector<std::size_t>& index) {
  if (index.size() != shape.size()) {
    throw Error("", "an index of the wrong rank for this array");
  }
  std::size_t at = 0;
  for (std::size_t i = 0; i < shape.size(); ++i) {
    if (index[i] >= shape[i]) {
      throw Error("", "an index outside the array");
    }
    at = at * shape[i] + index[i];
  }
  return at;
}
}  // namespace

double Array::at_f64(const std::vector<std::size_t>& index) const {
  const std::size_t at = flat_index(shape, index);
  if (dtype == DType::Float64) return f64.at(at);
  return static_cast<double>(i64.at(at));
}

std::int64_t Array::at_i64(const std::vector<std::size_t>& index) const {
  const std::size_t at = flat_index(shape, index);
  if (dtype == DType::Float64) return static_cast<std::int64_t>(f64.at(at));
  return i64.at(at);
}

int Array::axis(const std::string& name) const {
  for (std::size_t i = 0; i < dims.size(); ++i) {
    if (dims[i] == name) return static_cast<int>(i);
  }
  return -1;
}

Array Array::floats(std::vector<std::size_t> shape_,
                    std::vector<double> values,
                    std::vector<std::string> dims_) {
  Array a;
  a.dtype = DType::Float64;
  a.shape = std::move(shape_);
  a.f64 = std::move(values);
  a.dims = std::move(dims_);
  return a;
}

Array Array::ints(DType t, std::vector<std::size_t> shape_,
                  std::vector<std::int64_t> values,
                  std::vector<std::string> dims_) {
  Array a;
  a.dtype = t;
  a.shape = std::move(shape_);
  a.i64 = std::move(values);
  a.dims = std::move(dims_);
  return a;
}

Array Array::strings(std::vector<std::size_t> shape_,
                     std::vector<std::string> values,
                     std::vector<std::string> dims_) {
  Array a;
  a.dtype = DType::String;
  a.shape = std::move(shape_);
  a.str = std::move(values);
  a.dims = std::move(dims_);
  return a;
}

// --- AttrValue -------------------------------------------------------

AttrValue AttrValue::boolean(bool v) {
  AttrValue a;
  a.kind_ = Kind::Bool;
  a.b_ = v;
  return a;
}

AttrValue AttrValue::integer(std::int64_t v) {
  AttrValue a;
  a.kind_ = Kind::Int;
  a.i_ = v;
  return a;
}

AttrValue AttrValue::real(double v) {
  AttrValue a;
  a.kind_ = Kind::Float;
  a.d_ = v;
  return a;
}

AttrValue AttrValue::text(std::string v) {
  AttrValue a;
  a.kind_ = Kind::Str;
  a.s_ = std::move(v);
  return a;
}

AttrValue AttrValue::raw_text(std::string bytes) {
  AttrValue a;
  a.kind_ = Kind::Str;
  a.s_ = std::move(bytes);
  return a;
}

bool AttrValue::operator==(const AttrValue& o) const {
  if (kind_ != o.kind_) return false;
  switch (kind_) {
    case Kind::Bool: return b_ == o.b_;
    case Kind::Int: return i_ == o.i_;
    case Kind::Float:
      // Compared as bits, so that NaN equals NaN and -0.0 differs
      // from 0.0, which is what section 30 asks of every float
      // comparison and what Value already does.
      return std::memcmp(&d_, &o.d_, sizeof(double)) == 0;
    case Kind::Str: return s_ == o.s_;
  }
  return false;
}

const AttrValue* find_attr(const AttrMap& m, const std::string& name) {
  for (const auto& entry : m) {
    if (entry.first == name) return &entry.second;
  }
  return nullptr;
}

void set_attr(AttrMap& m, const std::string& name, AttrValue v) {
  for (auto& entry : m) {
    if (entry.first == name) {
      entry.second = std::move(v);
      return;
    }
  }
  m.emplace_back(name, std::move(v));
}

// --- Value -----------------------------------------------------------

Value::Value() : kind_(Kind::Null) {}

Value::Value(const Value& o)
    : kind_(o.kind_), b_(o.b_), i_(o.i_), d_(o.d_), s_(o.s_), a_(o.a_) {
  if (o.dict_) dict_.reset(new Dict(*o.dict_));
}

Value::Value(Value&& o) noexcept
    : kind_(o.kind_),
      b_(o.b_),
      i_(o.i_),
      d_(o.d_),
      s_(std::move(o.s_)),
      a_(std::move(o.a_)),
      dict_(std::move(o.dict_)) {
  // A moved-from Value is a null, not a dictionary whose dictionary
  // has gone: the default move leaves `kind_` behind while `dict_` is
  // taken, and `as_dict` on the result would then throw.
  o.kind_ = Kind::Null;
  o.b_ = false;
  o.i_ = 0;
  o.d_ = 0.0;
}

Value& Value::operator=(Value o) {
  // `o` is the caller's value by copy or by move; taking its members
  // and leaving it a null keeps the same invariant the move
  // constructor keeps.
  kind_ = o.kind_;
  b_ = o.b_;
  i_ = o.i_;
  d_ = o.d_;
  s_ = std::move(o.s_);
  a_ = std::move(o.a_);
  dict_ = std::move(o.dict_);
  o.kind_ = Kind::Null;
  return *this;
}

Value::~Value() = default;

Value Value::null() { return Value(); }

Value Value::boolean(bool v) {
  Value x;
  x.kind_ = Kind::Bool;
  x.b_ = v;
  return x;
}

Value Value::integer(std::int64_t v) {
  Value x;
  x.kind_ = Kind::Int;
  x.i_ = v;
  return x;
}

Value Value::real(double v) {
  Value x;
  x.kind_ = Kind::Float;
  x.d_ = v;
  return x;
}

Value Value::text(std::string v) {
  Value x;
  x.kind_ = Kind::Str;
  x.s_ = std::move(v);
  return x;
}

Value Value::numbers(const Array& a) {
  if (a.shape.empty()) {
    throw Error("E32",
                "a zero-dimensional array must be written as the number "
                "it holds (section 25)");
  }
  Value x;
  x.kind_ = Kind::Numbers;
  x.a_ = a;
  x.a_.dims.clear();
  return x;
}

Value Value::strings(const Array& a) {
  if (a.shape.empty()) {
    throw Error("E32", "a zero-dimensional string array is not "
                       "representable (section 25)");
  }
  Value x;
  x.kind_ = Kind::Strings;
  x.a_ = a;
  x.a_.dims.clear();
  x.a_.dtype = DType::String;
  return x;
}

Value Value::dict(Dict d) {
  if (d.depth() + 1 > kMaxDictDepth) {
    throw Error("E41",
                "a dictionary nested deeper than this reader walks");
  }
  Value x;
  x.kind_ = Kind::Dict;
  x.dict_.reset(new Dict(std::move(d)));
  return x;
}

int Value::depth() const {
  return kind_ == Kind::Dict && dict_ ? dict_->depth() + 1 : 0;
}

const Dict& Value::as_dict() const {
  if (!dict_) throw Error("", "this dictionary value is not a dictionary");
  return *dict_;
}

Dict& Value::as_dict() {
  if (!dict_) throw Error("", "this dictionary value is not a dictionary");
  return *dict_;
}

bool Value::operator==(const Value& o) const {
  if (kind_ != o.kind_) return false;
  switch (kind_) {
    case Kind::Null: return true;
    case Kind::Bool: return b_ == o.b_;
    case Kind::Int: return i_ == o.i_;
    case Kind::Float:
      // Compared as bits so that NaN equals NaN (section 30).
      return std::memcmp(&d_, &o.d_, sizeof(double)) == 0;
    case Kind::Str: return s_ == o.s_;
    case Kind::Numbers:
      return a_.dtype == o.a_.dtype && a_.shape == o.a_.shape &&
             a_.i64 == o.a_.i64 && a_.f64 == o.a_.f64;
    case Kind::Strings:
      return a_.shape == o.a_.shape && a_.str == o.a_.str;
    case Kind::Dict: return as_dict() == o.as_dict();
  }
  return false;
}

// --- Dict ------------------------------------------------------------

bool Dict::has(const std::string& key) const {
  return map_.find(key) != map_.end();
}

const Value& Dict::at(const std::string& key) const {
  const auto it = map_.find(key);
  if (it == map_.end()) {
    throw Error("", "the dictionary has no key \"" + key + "\"");
  }
  return it->second;
}

void Dict::set(const std::string& key, Value v) {
  const int was = v.depth();
  map_[key] = std::move(v);
  if (was > depth_) depth_ = was;
}

void Dict::erase(const std::string& key) {
  map_.erase(key);
  recount();
}

void Dict::recount() {
  depth_ = 0;
  for (const auto& entry : map_) {
    const int d = entry.second.depth();
    if (d > depth_) depth_ = d;
  }
}

// --- dump ------------------------------------------------------------

namespace {

// Escapes everything outside printable ASCII, plus '%' and ' ', so
// that one leaf is one line whatever a string holds.
std::string escape(const std::string& s) {
  static const char* digits = "0123456789ABCDEF";
  std::string out;
  for (const char raw : s) {
    const unsigned char c = static_cast<unsigned char>(raw);
    if (c > 0x20 && c < 0x7F && c != '%') {
      out.push_back(static_cast<char>(c));
    } else {
      out.push_back('%');
      out.push_back(digits[c >> 4]);
      out.push_back(digits[c & 0x0Fu]);
    }
  }
  // A lone "%" means the empty string: every other "%" in the output
  // is followed by two hexadecimal digits, so the two cannot be
  // confused.
  if (out.empty()) out = "%";
  return out;
}

std::string shape_text(const std::vector<std::size_t>& shape) {
  std::string out = internal::format_i64(
      static_cast<std::int64_t>(shape.size()));
  for (const std::size_t e : shape) {
    out += " " + internal::format_i64(static_cast<std::int64_t>(e));
  }
  return out;
}

void dump_value(const std::string& path, const Value& v,
                std::vector<std::string>& lines, int depth) {
  if (depth > kMaxDictDepth) {
    throw Error("E41", "a dictionary nested deeper than this reader walks, "
                       "at \"" + path + "\"");
  }
  switch (v.kind()) {
    case Value::Kind::Null:
      lines.push_back("N " + path);
      return;
    case Value::Kind::Bool:
      lines.push_back("B " + path + " " + (v.as_bool() ? "1" : "0"));
      return;
    case Value::Kind::Int:
      lines.push_back("I " + path + " " + internal::format_i64(v.as_int()));
      return;
    case Value::Kind::Float:
      lines.push_back("F " + path + " " + internal::format_f64(v.as_float()));
      return;
    case Value::Kind::Str:
      lines.push_back("S " + path + " " + escape(v.as_text()));
      return;
    case Value::Kind::Numbers: {
      const Array& a = v.as_array();
      std::string line = "A " + path + " " + dtype_name(a.dtype) + " " +
                         shape_text(a.shape);
      if (a.dtype == DType::Float64) {
        for (const double x : a.f64) line += " " + internal::format_f64(x);
      } else {
        for (const std::int64_t x : a.i64) {
          line += " " + internal::format_i64(x);
        }
      }
      lines.push_back(line);
      return;
    }
    case Value::Kind::Strings: {
      const Array& a = v.as_array();
      std::string line = "T " + path + " " + shape_text(a.shape);
      for (const std::string& x : a.str) line += " " + escape(x);
      lines.push_back(line);
      return;
    }
    case Value::Kind::Dict: {
      const Dict& d = v.as_dict();
      lines.push_back("D " + path);
      for (const auto& entry : d) {
        dump_value(path + "/" + entry.first, entry.second, lines, depth + 1);
      }
      return;
    }
  }
}

}  // namespace

std::string dump_dict(const Dict& d) {
  std::vector<std::string> lines;
  lines.push_back("D .");
  for (const auto& entry : d) {
    dump_value("./" + entry.first, entry.second, lines, 1);
  }
  std::string out;
  for (const std::string& line : lines) {
    out += line;
    out.push_back('\n');
  }
  return out;
}

}  // namespace mestra
