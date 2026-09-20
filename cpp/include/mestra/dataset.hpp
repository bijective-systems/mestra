// The dataset value type: what `mestra::read` returns and what
// `mestra::write` puts back on disk.  It is the model of SPEC.md
// sections 2 to 12 with the byte-level facts of sections 18 to 25 kept
// where a writer needs them (the stored integer width of a key, the
// declared byte size of a category table, a chunk shape that is not
// the default).  Nothing here reads or writes a file.
#ifndef MESTRA_DATASET_HPP
#define MESTRA_DATASET_HPP

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "mestra/value.hpp"

namespace mestra {

// Where an array sits: under `node_arrays` or under `cell_arrays`.
// It is not an attribute (section 19); the group the slot sits in says
// it.
enum class Location { Node, Cell };

// A per-row column that locates the row in the sampled space.
// `role` is one of design, condition, time, categorical, group, split,
// id, status (section 3).  A key stores category ids when its role is
// categorical, group, split or status: the zero-based position of the
// entry in its category table (section 21).
struct Key {
  std::string name;
  std::string role;
  std::optional<std::string> units;
  std::optional<double> lower;
  std::optional<double> upper;
  std::optional<std::string> category;          // category table name
  std::optional<std::string> trajectory_group;  // on the time key
  std::optional<std::string> parent;            // on a group key
  DType dtype = DType::Float64;
  std::vector<double> f64;
  std::vector<std::int64_t> i64;
  std::vector<std::string> str;                 // a string id column
  // The declared byte size of a string id column.  Left unset the
  // writer uses the longest element, which is what section 19 asks
  // for; a larger size is legal and draws W13.
  std::optional<std::size_t> string_size;
  AttrMap extra;   // attributes this version does not know (W11)

  std::size_t rows() const;
};

// A per-row quantity of interest.  `source` is "data" or
// "callable:<id>"; a callable-served scalar carries no values.
struct Scalar {
  std::string name;
  std::string units;
  std::string source = "data";
  std::optional<std::string> output;     // when served by a callable
  std::optional<std::string> statistic;
  std::optional<std::string> of;
  std::optional<double> quantile;
  std::vector<double> values;
  AttrMap extra;

  bool is_callable() const;
  std::string callable_id() const;       // "" when source is data
};

// A field-like quantity on a support, or a support's coordinates.
// `varies` is "none", "row" or "group:<k>" (section 5).  `data`
// carries the stored values with their dimension names; it is empty
// when the slot is served by a callable.
struct ArraySlot {
  std::string name;
  std::string role;                      // coordinates|field|label|...
  std::string varies = "none";
  std::optional<std::string> units;
  std::int64_t components = 1;
  std::string source = "data";
  std::optional<std::string> output;
  std::optional<std::string> statistic;
  std::optional<std::string> of;
  std::optional<double> quantile;
  std::optional<std::string> category;   // a label's table
  std::optional<bool> recomputed;        // weight and normal
  std::optional<std::string> derived_from;
  std::optional<std::string> recipe;
  std::optional<std::string> reference;  // "row=<i>" or "group:<k>=<c>"
  Location location = Location::Node;
  Array data;
  AttrMap extra;

  bool is_callable() const;
  std::string callable_id() const;
};

// The structure a field lives on.  `kind` is mesh, axis or none.
// The cell arrays are present only for a mesh (section 20).
struct Support {
  std::string name;                      // the group name, e.g. "s0"
  std::string kind = "mesh";
  std::int64_t n_nodes = 0;
  std::int64_t n_cells = 0;
  std::string support_id;                // as stored, lower-case hex
  std::vector<std::uint8_t> cell_types;
  std::vector<std::int64_t> cell_offsets;
  std::vector<std::int64_t> cell_connectivity;
  std::optional<ArraySlot> coordinates;
  std::vector<ArraySlot> node_arrays;
  std::vector<ArraySlot> cell_arrays;
  AttrMap extra;
  std::vector<std::string> unknown_groups;   // ignored and reported

  // The digest of section 24, computed from the arrays above rather
  // than read from `support_id`.
  std::string computed_support_id() const;
};

// A category table under /categories.  `string_size` is the declared
// byte size of the fixed-length strings; left unset the writer uses
// the longest element, which is what section 19 asks for.
struct CategoryTable {
  std::string name;
  std::vector<std::string> entries;
  std::optional<std::size_t> string_size;

  int index_of(const std::string& entry) const;   // -1 when absent
};

// A callable as the file stores it: a public `type`, an optional
// one-line `repr`, and the dictionary the codec round-trips.
struct StoredCallable {
  std::string id;
  std::string type;
  std::optional<std::string> repr;
  Dict dict;
};

// One file.
struct Dataset {
  std::string format = "mestra/0";
  std::string writer;
  std::string created;
  bool aligned = true;
  std::optional<std::string> generalisation_group;

  // The length of the `row` dimension.  Every row-dimensioned dataset
  // in an aligned file has this many entries (section 21).
  std::int64_t n_rows = 0;

  std::vector<Key> keys;
  std::vector<Scalar> scalars;
  std::vector<CategoryTable> categories;
  std::vector<Support> supports;
  std::vector<StoredCallable> callables;

  // Present exactly when the file declares more than one support
  // (section 22).  Values are positions in the support order, which
  // is the support group names sorted by their UTF-8 bytes.
  std::optional<std::vector<std::int32_t>> row_support;

  AttrMap notes;                 // /notes, free-form
  bool has_notes = false;
  bool has_private = false;      // /private exists; never interpreted
  AttrMap root_extra;            // root attributes this version does
                                 // not know (W11)
  std::vector<std::string> unknown_root_groups;
  // Container groups the file carries even when they hold nothing, so
  // that a round trip does not add or drop an object path.
  std::set<std::string> container_groups;
  // A chunk shape that is not the default of section 23, by the HDF5
  // path of the dataset it belongs to.  A reader fills this in for
  // every dataset whose chunk it finds is not the default, so that a
  // round trip reproduces the file; a caller building a dataset from
  // vectors leaves it alone and gets the default everywhere.
  std::map<std::string, std::vector<std::size_t>> chunk_overrides;

  // --- lookup ------------------------------------------------------
  const Key* key(const std::string& name) const;
  const Scalar* scalar(const std::string& name) const;
  const Support* support(const std::string& name) const;
  // The same three by name, for a caller that wants to change one.
  // Adding a key, a scalar or a support keeps the vectors sorted and
  // therefore invalidates references into them, so fetch again by
  // name rather than holding a reference across an `add_`.
  Key* key(const std::string& name);
  Scalar* scalar(const std::string& name);
  Support* support(const std::string& name);
  const CategoryTable* category(const std::string& name) const;
  const StoredCallable* callable(const std::string& id) const;
  // The support of a row, by /row_support or by the single support.
  const Support* support_of_row(std::size_t row) const;
  // Key names sorted by their UTF-8 bytes: the file's key order
  // (section 26).
  std::vector<std::string> key_order() const;

  // --- building ----------------------------------------------------
  // Each of these fills in the dimension names, the shape and, where
  // the format decides it, the support id, so that a caller builds a
  // conforming file from plain vectors.
  Key& add_key(const std::string& name, const std::string& role,
               std::vector<double> values,
               const std::string& units = "1");
  Key& add_category_key(const std::string& name, const std::string& role,
                        std::vector<std::int64_t> ids,
                        const std::string& category_table,
                        DType dtype = DType::Int32);
  Scalar& add_scalar(const std::string& name, const std::string& units,
                     std::vector<double> values);
  CategoryTable& add_categories(const std::string& name,
                                std::vector<std::string> entries);
  // A mesh support; `support_id` is computed from the arrays.
  Support& add_mesh_support(const std::string& name,
                            std::int64_t n_nodes,
                            std::vector<std::uint8_t> cell_types,
                            std::vector<std::int64_t> cell_offsets,
                            std::vector<std::int64_t> connectivity);
  Support& add_axis_support(const std::string& name,
                            const std::vector<double>& coordinates,
                            const std::string& units);
  Support& add_none_support(const std::string& name);
  StoredCallable& add_callable(const std::string& id,
                               const std::string& type, Dict dict);
};

// --- support helpers ------------------------------------------------

// Set a support's coordinates from a flat array in stored order.
// `varies` is "none", "row" or "group:<k>"; for those two the values
// are the instances one after another, and how many there are follows
// from the length of `values`, so there is no count to get wrong.
void set_coordinates(Support& s, const std::vector<double>& values,
                     std::int64_t components, const std::string& units,
                     const std::string& varies = "none");

// Add a field.  `values` is the slot's contents flattened in stored
// order; the dimension names and the shape follow from `varies`, the
// support, `components` and the length of `values`.
ArraySlot& add_field(Support& s, Location where, const std::string& name,
                     const std::string& units,
                     const std::vector<double>& values,
                     std::int64_t components = 1,
                     const std::string& varies = "row");

// Add an integer label, with or without a category table.
ArraySlot& add_label(Support& s, Location where, const std::string& name,
                     const std::vector<std::int64_t>& values,
                     std::optional<std::string> category = std::nullopt,
                     DType dtype = DType::Int32,
                     const std::string& varies = "none");

// Add a slot served by a callable: it carries the attributes and no
// data (section 19).
ArraySlot& add_callable_field(Support& s, Location where,
                              const std::string& name,
                              const std::string& units,
                              std::int64_t components,
                              const std::string& callable_id,
                              const std::string& output,
                              const std::string& varies = "row");
Scalar& add_callable_scalar(Dataset& d, const std::string& name,
                            const std::string& units,
                            const std::string& callable_id,
                            const std::string& output);

// The digest of section 24 over the arrays given, without a file.
std::string support_id_digest(std::int64_t n_nodes,
                              const std::vector<std::uint8_t>& cell_types,
                              const std::vector<std::int64_t>& cell_offsets,
                              const std::vector<std::int64_t>& connectivity,
                              const std::vector<double>* axis_coordinates);

// The number of nodes a VTK cell type code takes, or 0 for a polygon
// (code 7, three or more) and -1 for a code section 20 does not allow.
int cell_type_nodes(std::uint8_t code);

// The default chunk length along `row` of section 23.
std::size_t default_chunk_rows(std::size_t item_bytes,
                               const std::vector<std::size_t>& other_extents,
                               std::size_t row_count);

}  // namespace mestra

#endif  // MESTRA_DATASET_HPP
