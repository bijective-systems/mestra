// The value types every other header is built from: the numeric and
// string arrays a dataset carries, the attribute values the format
// names, and the `Dict` of the callable dictionary codec (SPEC.md
// sections 17 and 25).
#ifndef MESTRA_VALUE_HPP
#define MESTRA_VALUE_HPP

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace mestra {

// Compares two names as sequences of unsigned bytes.  The spec orders
// keys, support groups and dictionary keys "by their UTF-8 bytes"
// (sections 22, 25 and 26); plain `std::string` comparison is
// signed-char on most platforms and would order non-ASCII names
// differently, so every ordering in this library goes through here.
bool bytes_less(const std::string& a, const std::string& b);

// Same ordering, as a comparator for the standard containers.
struct BytesLess {
  bool operator()(const std::string& a, const std::string& b) const {
    return bytes_less(a, b);
  }
};

// The dtypes this format allows on disk (section 19).  `Bool` is int8
// and means a boolean everywhere it appears, including inside a
// callable's dictionary (section 25).  float32 is deliberately absent:
// the format allows it nowhere.
enum class DType {
  Bool,     // int8, value 0 or 1
  UInt8,    // cell_types only
  Int32,
  Int64,
  Float64,
  String    // fixed-length, UTF-8, NUL-padded
};

const char* dtype_name(DType t);   // "bool", "int32", ... , "string"

// How deep a callable's dictionary may nest.  A dictionary is a tree
// and every walk of it -- reading, writing, dumping, copying and
// destroying -- is recursive, so a file that nests one far enough
// would overflow the stack, and a stack overflow cannot be caught.
// The limit is therefore enforced where a dictionary is built, which
// makes a deeper one impossible to hold rather than merely unsafe to
// walk.
const int kMaxDictDepth = 64;

// One array with its dimension names.  `shape` is in C order and
// `dims` holds the logical dimension name of each axis (section 4:
// "row", "group:<k>", "draw", "node", "cell", "component", "index",
// "cell_plus_one"), so that a caller permutes by name and never by
// position.  Exactly one of the three value vectors is used, chosen by
// `dtype`; integers of every width live in `i64`.
struct Array {
  DType dtype = DType::Float64;
  std::vector<std::string> dims;
  std::vector<std::size_t> shape;
  std::vector<double> f64;
  std::vector<std::int64_t> i64;
  std::vector<std::string> str;

  std::size_t size() const;          // product of `shape`
  bool empty() const { return size() == 0; }

  // Index by subscripts in stored (C) order.
  double at_f64(const std::vector<std::size_t>& index) const;
  std::int64_t at_i64(const std::vector<std::size_t>& index) const;

  // Position of the axis whose logical dimension name is `name`, or
  // -1 when the array has no such axis.
  int axis(const std::string& name) const;

  // Builders.  `dims` may be left empty and filled in by the writer
  // helpers of dataset.hpp.
  static Array floats(std::vector<std::size_t> shape,
                      std::vector<double> values,
                      std::vector<std::string> dims = {});
  static Array ints(DType t, std::vector<std::size_t> shape,
                    std::vector<std::int64_t> values,
                    std::vector<std::string> dims = {});
  static Array strings(std::vector<std::size_t> shape,
                       std::vector<std::string> values,
                       std::vector<std::string> dims = {});
};

// An attribute value in one of the four encodings of section 18.
// `raw` carries the stored bytes of a string attribute unchanged,
// which is how the null sentinel ("\0null") survives a round trip.
class AttrValue {
 public:
  enum class Kind { Bool, Int, Float, Str };

  AttrValue() : kind_(Kind::Int), i_(0) {}
  static AttrValue boolean(bool v);
  static AttrValue integer(std::int64_t v);
  static AttrValue real(double v);
  static AttrValue text(std::string v);
  static AttrValue raw_text(std::string bytes);  // stored bytes as-is

  Kind kind() const { return kind_; }
  bool as_bool() const { return b_; }
  std::int64_t as_int() const { return i_; }
  double as_float() const { return d_; }
  const std::string& as_text() const { return s_; }

  bool operator==(const AttrValue& o) const;

 private:
  Kind kind_;
  bool b_ = false;
  std::int64_t i_ = 0;
  double d_ = 0.0;
  std::string s_;
};

// Attributes in the order they were read, so that a writer can put
// unknown ones back where it found them (section 28).
using AttrMap = std::vector<std::pair<std::string, AttrValue>>;

const AttrValue* find_attr(const AttrMap& m, const std::string& name);
void set_attr(AttrMap& m, const std::string& name, AttrValue v);

class Dict;

// One value of a callable's dictionary (section 17).  The leaves are
// numbers, booleans, strings, null, numeric arrays and string arrays;
// the branches are nested dictionaries.
class Value {
 public:
  enum class Kind { Null, Bool, Int, Float, Str, Numbers, Strings, Dict };

  Value();                                   // null
  Value(const Value& o);
  Value(Value&& o) noexcept;
  Value& operator=(Value o);
  ~Value();

  static Value null();
  static Value boolean(bool v);
  static Value integer(std::int64_t v);
  static Value real(double v);
  static Value text(std::string v);
  // A numeric or boolean array of one dimension or more.  A
  // zero-dimensional array is not representable: section 25 requires
  // it to be written as the number it holds.
  static Value numbers(const Array& a);
  static Value strings(const Array& a);
  // Throws mestra::Error("E32", ...) when nesting `d` would take the
  // result past kMaxDictDepth.
  static Value dict(Dict d);

  Kind kind() const { return kind_; }
  bool is_null() const { return kind_ == Kind::Null; }
  bool as_bool() const { return b_; }
  std::int64_t as_int() const { return i_; }
  double as_float() const { return d_; }
  const std::string& as_text() const { return s_; }
  const Array& as_array() const { return a_; }
  const Dict& as_dict() const;
  Dict& as_dict();
  // 0 for a leaf; for a dictionary, one more than the deepest
  // dictionary below it.
  int depth() const;

  bool operator==(const Value& o) const;

 private:
  Kind kind_ = Kind::Null;
  bool b_ = false;
  std::int64_t i_ = 0;
  double d_ = 0.0;
  std::string s_;
  Array a_;
  std::unique_ptr<Dict> dict_;
};

// A callable's dictionary.  Keys are ordered by their UTF-8 bytes, so
// iteration order is the order section 25 requires a writer to visit
// them in and two writers given the same dictionary agree.
class Dict {
 public:
  using Map = std::map<std::string, Value, BytesLess>;

  bool has(const std::string& key) const;
  const Value& at(const std::string& key) const;   // throws when absent
  // The only way to put a value in.  There is no mutable accessor,
  // because the nesting depth is accounted here and a caller that
  // could reach in and replace a value would walk past the accounting.
  void set(const std::string& key, Value v);
  void erase(const std::string& key);
  std::size_t size() const { return map_.size(); }
  bool empty() const { return map_.empty(); }
  // The deepest nesting below this dictionary: 0 when every value is
  // a leaf.  Kept as values go in rather than walked for.
  int depth() const { return depth_; }

  Map::const_iterator begin() const { return map_.begin(); }
  Map::const_iterator end() const { return map_.end(); }

  bool operator==(const Dict& o) const { return map_ == o.map_; }

 private:
  void recount();

  Map map_;
  int depth_ = 0;
};

// The dictionary written out as one line per leaf, for tests and for
// `mestra-cli dict-dump`.  It exists so that the conformance driver
// can compare a dictionary without any JSON code in C++.  The first
// field is the kind, the second the path from `.`, and the rest the
// value:
//
//     D .                      a nested dictionary
//     N ./x                    null
//     B ./x 1                  a boolean
//     I ./x 42                 an int64
//     F ./x 2.50000000000000000e+00      a float64
//     S ./x hello              a string
//     A ./x float64 2 6 2 ...  an array: dtype, rank, extents, elements
//     T ./x 1 2 mach alpha     a string array: rank, extents, elements
//
// Anything outside printable ASCII, and `%` itself, is written `%XX`;
// a lone `%` is the empty string.  Keys come out in ascending order of
// their UTF-8 bytes, which is the order section 25 tells a writer to
// visit them in.
std::string dump_dict(const Dict& d);

}  // namespace mestra

#endif  // MESTRA_VALUE_HPP
