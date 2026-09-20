// `affine`, the one callable type this package defines (SPEC.md
// section 27).  It exists so that the protocol, the codec and
// evaluation can be conformance-tested in every language with no
// proprietary model.
#ifndef MESTRA_AFFINE_HPP
#define MESTRA_AFFINE_HPP

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "mestra/callable.hpp"

namespace mestra {

// One output slot: y = A x + b, reshaped to `shape` in C order.
struct AffineOutput {
  std::vector<double> A;             // (n_out_flat, n_keys), C order
  std::vector<double> b;             // (n_out_flat)
  std::vector<std::int64_t> shape;   // the slot's dimensions after row
                                     // ([] for a scalar slot)
  std::size_t out_flat() const;      // product of `shape`, 1 when empty
};

// The callable.  Its dictionary is exactly {keys, outputs}; a reader
// refuses an `affine` dictionary with any other key, and a writer must
// not add to it.
class Affine : public Callable {
 public:
  Affine() = default;
  Affine(std::vector<std::string> keys,
         std::map<std::string, AffineOutput, BytesLess> outputs,
         std::string repr_line = std::string());

  // The declared key order: x is built by taking these keys from the
  // keys table in this order.
  const std::vector<std::string>& keys() const { return keys_; }
  const std::map<std::string, AffineOutput, BytesLess>& outputs() const {
    return outputs_;
  }

  Outputs call(const KeysTable& table) const override;
  Dict to_dict() const override;
  std::string type() const override { return "affine"; }
  std::string repr() const override { return repr_; }

  // The inverse of `to_dict`.  Throws mestra::Error when the
  // dictionary is not an `affine` dictionary.
  static Affine from_dict(const Dict& d);

  // Registers `affine` with CallableRegistry.  Called once by the
  // library at start-up; calling it again is harmless.
  static void register_type();

 private:
  std::vector<std::string> keys_;
  std::map<std::string, AffineOutput, BytesLess> outputs_;
  std::string repr_;
};

}  // namespace mestra

#endif  // MESTRA_AFFINE_HPP
