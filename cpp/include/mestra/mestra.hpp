// mestra, the C++ implementation: one header to include.
//
//   mestra::read(path)              a Dataset value type
//   mestra::write(dataset, path)    a conforming file
//   mestra::validate(path)          errors and warnings by rule id
//   mestra::evaluate(dataset, keys) a materialised Dataset
//   mestra::compute_weights(support, location)   integration weights
//   mestra::integrate(dataset, slot)             one slot, integrated
//   mestra::field_statistics(dataset, slot, by)  one slot, summarised
//
// SPEC.md is the normative document and vectors/ is the conformance
// corpus.  No implementation is the reference.
#ifndef MESTRA_MESTRA_HPP
#define MESTRA_MESTRA_HPP

#include "mestra/affine.hpp"
#include "mestra/callable.hpp"
#include "mestra/dataset.hpp"
#include "mestra/evaluate.hpp"
#include "mestra/io.hpp"
#include "mestra/post.hpp"
#include "mestra/sha256.hpp"
#include "mestra/validate.hpp"
#include "mestra/value.hpp"
#include "mestra/weights.hpp"

namespace mestra {

// The format version this build reads and writes.
inline const char* format_string() { return "mestra/0"; }
inline int major_version() { return 0; }

// The library's own version, written into a file's `writer` attribute
// when the caller leaves it empty.
const char* library_version();

}  // namespace mestra

#endif  // MESTRA_MESTRA_HPP
