// The callable protocol of SPEC.md section 10, and the keys table of
// section 26.  A callable is exactly four things: `call`, `to_dict`,
// a static `from_dict` dispatched on a `type` string, and an optional
// `repr`.  Everything else it knows lives inside its dictionary and is
// its own business.
#ifndef MESTRA_CALLABLE_HPP
#define MESTRA_CALLABLE_HPP

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "mestra/value.hpp"

namespace mestra {

// The keys table: "one column per key the file declares, in the file's
// key order, and any number of rows" (section 26).  C++ cannot give a
// struct member names chosen at run time, so this is a struct of named
// vectors: the names and the columns side by side, looked up by name
// and never by position.  A column of a key with role `id` may be
// strings; every other column is numeric.
struct KeysTable {
  std::vector<std::string> names;
  std::vector<std::vector<double>> numeric;
  std::vector<std::vector<std::string>> text;   // empty unless strings

  std::size_t rows() const;
  bool has(const std::string& name) const;
  // Throws mestra::Error when the column is not in the table, which is
  // what section 26 calls an error at call time.
  const std::vector<double>& column(const std::string& name) const;
  const std::vector<std::string>& text_column(const std::string& name) const;

  void add_column(const std::string& name, std::vector<double> values);
  void add_text_column(const std::string& name,
                       std::vector<std::string> values);
};

// What a callable returns: one array per output name, shaped as the
// slot would be stored, that is (row, [draw], node | cell, component)
// for an array and (row) for a scalar, with the dimension names filled
// in.
struct Outputs {
  std::map<std::string, Array, BytesLess> by_output;

  bool has(const std::string& output) const;
  const Array& at(const std::string& output) const;
  void set(const std::string& output, Array a);
};

// The four things and nothing more.
class Callable {
 public:
  virtual ~Callable() = default;

  // Keys in, values out.
  virtual Outputs call(const KeysTable& keys) const = 0;
  // A nested dictionary that fully represents the callable.
  virtual Dict to_dict() const = 0;
  // The public type string, so that a reader knows which tool can
  // evaluate this callable.
  virtual std::string type() const = 0;
  // Optional: one line for printing.  The default is empty, which
  // means the file carries no `repr`.
  virtual std::string repr() const { return std::string(); }
};

// The registry `from_dict` dispatches through.  A tool that owns a
// type registers a factory for it at start-up; a reader that meets a
// type nobody registered may still copy the dictionary unchanged and
// must not interpret it (section 25).
class CallableRegistry {
 public:
  using Factory = std::function<std::unique_ptr<Callable>(const Dict&)>;

  static void register_type(const std::string& type, Factory factory);
  static bool knows(const std::string& type);
  // Returns nullptr when no factory is registered for `type`.
  static std::unique_ptr<Callable> from_dict(const std::string& type,
                                             const Dict& dict);
  static std::vector<std::string> types();
};

}  // namespace mestra

#endif  // MESTRA_CALLABLE_HPP
