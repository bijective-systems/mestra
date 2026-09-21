// `affine`, the reference callable of SPEC.md section 27.
//
// SPEC.md section 27 fixes the summation order: the dot product is
// accumulated over the keys in the declared key order and b is added
// last, with no fused multiply-add.  The whole library is compiled
// with -ffp-contract=off so that the compiler may not fuse a multiply
// and an add into one rounding step; the corpus compares float64
// results bit for bit and the other orders differ in the last place.
#include "mestra/affine.hpp"

#include <algorithm>
#include <string>

#include "mestra/io.hpp"

// Section 27 fixes the summation order, and the corpus compares
// float64 results bit for bit, so no multiply and add here may be
// contracted into one rounding step.  The CMake build passes
// -ffp-contract=off, but a translation unit that says so itself is
// right however it is compiled: these two pragmas say it to clang and
// to any compiler that implements the C standard pragma, and the
// accumulation below is written through a named temporary so that
// there is no multiply-add expression left for a compiler that
// honours neither.
#if defined(__clang__)
#pragma clang fp contract(off)
#elif defined(__GNUC__)
#pragma GCC optimize("fp-contract=off")
#endif
#if defined(__STDC_VERSION__) || defined(FP_CONTRACT)
#pragma STDC FP_CONTRACT OFF
#endif

namespace mestra {

std::size_t AffineOutput::out_flat() const {
  std::size_t n = 1;   // the empty product is 1, so a scalar slot is 1
  for (const std::int64_t e : shape) {
    n *= static_cast<std::size_t>(e < 0 ? 0 : e);
  }
  return n;
}

namespace {

// Section 27: a band is all three of uncertainty, level and method,
// the uncertainty is one value per output element, and the level is a
// coverage.
void check_band(const std::string& name, const AffineOutput& o) {
  const int parts = (o.uncertainty.has_value() ? 1 : 0) +
                    (o.level.has_value() ? 1 : 0) +
                    (o.method.has_value() ? 1 : 0);
  if (parts == 0) return;
  if (parts != 3) {
    throw Error("", "a band on the affine output \"" + name +
                        "\" is all three of uncertainty, level and method");
  }
  if (o.uncertainty->size() != o.out_flat()) {
    throw Error("", "the affine output \"" + name +
                        "\" has an uncertainty of " +
                        std::to_string(o.uncertainty->size()) +
                        " values where its shape needs " +
                        std::to_string(o.out_flat()));
  }
  if (!(*o.level > 0.0 && *o.level < 1.0)) {
    throw Error("", "the affine output \"" + name +
                        "\" has a level that is not a coverage in (0, 1)");
  }
  if (o.method->empty()) {
    throw Error("", "the affine output \"" + name +
                        "\" has a method that is not one sentence");
  }
}

}  // namespace

Affine::Affine(std::vector<std::string> keys,
               std::map<std::string, AffineOutput, BytesLess> outputs,
               std::string repr_line)
    : keys_(std::move(keys)),
      outputs_(std::move(outputs)),
      repr_(std::move(repr_line)) {
  for (const auto& entry : outputs_) check_band(entry.first, entry.second);
}

Outputs Affine::call(const KeysTable& table) const {
  const std::size_t rows = table.rows();
  // X of shape (rows, n_keys), built from the declared keys.
  std::vector<std::vector<double>> columns;
  columns.reserve(keys_.size());
  for (const std::string& name : keys_) {
    const std::vector<double>& c = table.column(name);
    if (c.size() != rows) {
      throw Error("", "the keys table column \"" + name +
                          "\" is not as long as the table");
    }
    columns.push_back(c);
  }

  Outputs out;
  for (const auto& entry : outputs_) {
    const AffineOutput& o = entry.second;
    const std::size_t flat = o.out_flat();
    if (o.b.size() != flat || o.A.size() != flat * keys_.size()) {
      throw Error("", "the affine output \"" + entry.first +
                          "\" has an A or b that does not match its shape");
    }
    Array a;
    a.dtype = DType::Float64;
    a.shape.push_back(rows);
    a.dims.push_back("row");
    a.f64.resize(rows * flat);
    for (std::size_t r = 0; r < rows; ++r) {
      for (std::size_t i = 0; i < flat; ++i) {
        // Accumulated over the keys in the declared key order, with b
        // added last.  Each product lands in its own named value
        // before it is added, so the multiply and the add are two
        // statements and cannot be fused whatever the compiler is
        // told on the command line.
        double acc = 0.0;
        for (std::size_t k = 0; k < keys_.size(); ++k) {
          const double term = o.A[i * keys_.size() + k] * columns[k][r];
          acc += term;
        }
        acc += o.b[i];   // b is added last
        a.f64[r * flat + i] = acc;
      }
    }
    // Section 27: the stored form is (row, node | cell, component)
    // for an array slot and (row) for a scalar, so `shape` is either
    // [node count, component count] or empty and nothing else.
    if (!o.shape.empty() && o.shape.size() != 2) {
      throw Error("", "the affine output \"" + entry.first +
                          "\" has a shape of rank " +
                          std::to_string(o.shape.size()) +
                          "; section 27 allows [node, component] or []");
    }
    for (const std::int64_t e : o.shape) {
      a.shape.push_back(static_cast<std::size_t>(e));
    }
    if (o.shape.size() == 2) {
      a.dims.push_back("node");
      a.dims.push_back("component");
    }
    Prediction p;
    p.mean = std::move(a);
    if (o.has_band()) {
      // The band is a constant, repeated for each of the rows, so that
      // evaluation stays exact (section 27).
      Array u;
      u.dtype = DType::Float64;
      u.shape = p.mean.shape;
      u.dims = p.mean.dims;
      u.f64.resize(rows * flat);
      for (std::size_t r = 0; r < rows; ++r) {
        for (std::size_t i = 0; i < flat; ++i) {
          u.f64[r * flat + i] = (*o.uncertainty)[i];
        }
      }
      p.uncertainty = std::move(u);
      p.level = o.level;
      p.method = o.method;
    }
    p.check(entry.first);
    out.set(entry.first, std::move(p));
  }
  return out;
}

Dict Affine::to_dict() const {
  Dict d;
  Array keys;
  keys.dtype = DType::String;
  keys.shape.push_back(keys_.size());
  keys.str = keys_;
  d.set("keys", Value::strings(keys));

  Dict outputs;
  for (const auto& entry : outputs_) {
    const AffineOutput& o = entry.second;
    Dict one;
    Array A;
    A.dtype = DType::Float64;
    A.shape = {o.b.size(), keys_.size()};
    A.f64 = o.A;
    one.set("A", Value::numbers(A));
    Array b;
    b.dtype = DType::Float64;
    b.shape = {o.b.size()};
    b.f64 = o.b;
    one.set("b", Value::numbers(b));
    Array shape;
    shape.dtype = DType::Int64;
    shape.shape = {o.shape.size()};
    shape.i64 = o.shape;
    one.set("shape", Value::numbers(shape));
    if (o.has_band()) {
      // Section 25: the band is a dataset, and the level and the
      // method are attributes on the entry.
      Array u;
      u.dtype = DType::Float64;
      u.shape = {o.uncertainty->size()};
      u.f64 = *o.uncertainty;
      one.set("uncertainty", Value::numbers(u));
      one.set("level", Value::real(*o.level));
      one.set("method", Value::text(*o.method));
    }
    outputs.set(entry.first, Value::dict(std::move(one)));
  }
  d.set("outputs", Value::dict(std::move(outputs)));
  return d;
}

Affine Affine::from_dict(const Dict& d) {
  // Section 27: there is nothing else in the dictionary; a reader
  // refuses an `affine` dictionary with any other key.
  for (const auto& entry : d) {
    if (entry.first != "keys" && entry.first != "outputs") {
      throw Error("", "an affine dictionary with the extra key \"" +
                          entry.first + "\"");
    }
  }
  if (!d.has("keys") || !d.has("outputs")) {
    throw Error("", "an affine dictionary needs `keys` and `outputs`");
  }
  const Value& keys_value = d.at("keys");
  if (keys_value.kind() != Value::Kind::Strings) {
    throw Error("", "an affine `keys` must be a list of key names");
  }
  Affine a;
  a.keys_ = keys_value.as_array().str;

  const Value& outputs = d.at("outputs");
  if (outputs.kind() != Value::Kind::Dict) {
    throw Error("", "an affine `outputs` must be a dictionary");
  }
  for (const auto& entry : outputs.as_dict()) {
    const Value& one = entry.second;
    if (one.kind() != Value::Kind::Dict) {
      throw Error("", "the affine output \"" + entry.first +
                          "\" must be a dictionary");
    }
    const Dict& o = one.as_dict();
    for (const auto& k : o) {
      if (k.first != "A" && k.first != "b" && k.first != "shape" &&
          k.first != "uncertainty" && k.first != "level" &&
          k.first != "method") {
        throw Error("", "the affine output \"" + entry.first +
                            "\" has the extra key \"" + k.first + "\"");
      }
    }
    if (!o.has("A") || !o.has("b") || !o.has("shape")) {
      throw Error("", "the affine output \"" + entry.first +
                          "\" needs A, b and shape");
    }
    AffineOutput out;
    out.A = o.at("A").as_array().f64;
    out.b = o.at("b").as_array().f64;
    out.shape = o.at("shape").as_array().i64;
    if (o.has("uncertainty")) {
      out.uncertainty = o.at("uncertainty").as_array().f64;
    }
    if (o.has("level")) out.level = o.at("level").as_float();
    if (o.has("method")) out.method = o.at("method").as_text();
    check_band(entry.first, out);
    a.outputs_[entry.first] = std::move(out);
  }
  return a;
}

void Affine::register_type() {
  CallableRegistry::register_type(
      "affine", [](const Dict& d) -> std::unique_ptr<Callable> {
        return std::unique_ptr<Callable>(new Affine(Affine::from_dict(d)));
      });
}

}  // namespace mestra
