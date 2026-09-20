#include "layout.hpp"

#include <algorithm>
#include <set>

#include "names.hpp"

namespace mestra {
namespace internal {

std::string logical_dim(const std::string& disk) {
  if (disk.compare(0, 10, "component_") == 0) return "component";
  if (disk.compare(0, 5, "draw_") == 0) return "draw";
  if (disk.compare(0, 6, "group_") == 0) return "group:" + disk.substr(6);
  return disk;   // row, node, cell, index, cell_plus_one
}

std::size_t rows_on_support(const Dataset& d, std::size_t index) {
  if (!d.row_support.has_value()) {
    return static_cast<std::size_t>(d.n_rows);
  }
  std::size_t n = 0;
  for (const std::int32_t at : *d.row_support) {
    if (at >= 0 && static_cast<std::size_t>(at) == index) ++n;
  }
  return n;
}

bool needs_local_row(const Dataset& d, const Support& s) {
  if (d.aligned) return false;
  if (s.coordinates.has_value() && s.coordinates->varies == "row") {
    return true;
  }
  for (const ArraySlot& a : s.node_arrays) {
    if (a.varies == "row" && !a.is_callable()) return true;
  }
  for (const ArraySlot& a : s.cell_arrays) {
    if (a.varies == "row" && !a.is_callable()) return true;
  }
  return false;
}

namespace {

void collect(const ArraySlot& a, std::set<std::size_t>* components,
             std::set<std::size_t>* draws) {
  if (a.is_callable()) return;          // a slot with no data has no axes
  const int comp = a.data.axis("component");
  if (comp >= 0) {
    components->insert(a.data.shape[static_cast<std::size_t>(comp)]);
  }
  const int draw = a.data.axis("draw");
  if (draw >= 0) {
    draws->insert(a.data.shape[static_cast<std::size_t>(draw)]);
  }
}

}  // namespace

std::vector<std::size_t> component_lengths(const Dataset& d) {
  std::set<std::size_t> components;
  std::set<std::size_t> draws;
  for (const Support& s : d.supports) {
    if (s.coordinates.has_value()) collect(*s.coordinates, &components,
                                           &draws);
    for (const ArraySlot& a : s.node_arrays) collect(a, &components, &draws);
    for (const ArraySlot& a : s.cell_arrays) collect(a, &components, &draws);
  }
  return std::vector<std::size_t>(components.begin(), components.end());
}

std::vector<std::size_t> draw_lengths(const Dataset& d) {
  std::set<std::size_t> components;
  std::set<std::size_t> draws;
  for (const Support& s : d.supports) {
    if (s.coordinates.has_value()) collect(*s.coordinates, &components,
                                           &draws);
    for (const ArraySlot& a : s.node_arrays) collect(a, &components, &draws);
    for (const ArraySlot& a : s.cell_arrays) collect(a, &components, &draws);
  }
  return std::vector<std::size_t>(draws.begin(), draws.end());
}

namespace {

bool one_of(const std::string& name, const std::vector<const char*>& list) {
  for (const char* n : list) {
    if (name == n) return true;
  }
  return false;
}

}  // namespace

bool known_root_attribute(const std::string& name) {
  return one_of(name, {"format", "writer", "created", "aligned",
                       "generalisation_group"});
}

bool known_key_attribute(const std::string& name) {
  return one_of(name, {"role", "units", "lower", "upper", "category",
                       "trajectory_group", "parent"});
}

bool known_scalar_attribute(const std::string& name) {
  return one_of(name, {"units", "source", "output", "statistic", "of",
                       "quantile"});
}

bool known_support_attribute(const std::string& name) {
  return one_of(name, {"kind", "n_nodes", "n_cells", "support_id"});
}

bool known_array_attribute(const std::string& name) {
  return one_of(name, {"role", "varies", "units", "components", "source",
                       "output", "statistic", "of", "quantile", "category",
                       "recomputed", "derived_from", "recipe", "reference"});
}

bool known_callable_attribute(const std::string& name) {
  return one_of(name, {"type", "repr"});
}

bool known_root_group(const std::string& name) {
  return one_of(name, {"keys", "scalars", "categories", "supports",
                       "callables", "notes", "private"});
}

bool known_support_group(const std::string& name) {
  return one_of(name, {"node_arrays", "cell_arrays"});
}

bool root_scale_name(const std::string& name) {
  if (name == "row") return true;
  return name.compare(0, 10, "component_") == 0 ||
         name.compare(0, 5, "draw_") == 0 ||
         name.compare(0, 6, "group_") == 0 ||
         name.compare(0, 9, "category_") == 0;
}

}  // namespace internal
}  // namespace mestra
