// A support and a field: the same six rows on a two-quad mesh.
// See README.md in this directory for the data and the output.
#include <cstdio>
#include <string>
#include <vector>

#include "mestra/mestra.hpp"

// Python's repr of a tuple of names, so that this prints what
// python.py prints.
static std::string names_of(const std::vector<std::string>& v) {
  std::string s;
  for (const std::string& n : v) s += (s.empty() ? "'" : ", '") + n + "'";
  return "(" + s + ")";
}

int main() {
  std::vector<double> coordinates, pressure;
  // Six nodes, with the x of every node scaled per member.
  const double xy[12] = {0, 0, 1, 0, 2, 0, 0, 1, 1, 1, 2, 1};
  for (const double scale : {1.0, 1.5, 2.0})
    for (int i = 0; i < 12; ++i)
      coordinates.push_back(i % 2 == 0 ? xy[i] * scale : xy[i]);
  for (int r = 1; r <= 6; ++r)
    for (int n = 1; n <= 6; ++n) pressure.push_back(100.0 * r + n);

  mestra::Dataset ds;
  ds.writer = "mestra examples 1";
  ds.created = "2026-09-19T00:00:00Z";
  ds.add_key("mach", {0.4, 0.8, 0.4, 0.8, 0.4, 0.8}, "condition", "1");
  ds.add_category_table("member", {"wing_a", "wing_b", "wing_c"});
  ds.add_category_key("member", {0, 0, 1, 1, 2, 2}, "group", "member");
  ds.set_generalisation_group("member");
  mestra::Support& s = ds.add_mesh_support("s0", 6, {9, 9}, {0, 4, 8},
                                           {0, 1, 4, 3, 1, 2, 5, 4});
  // `dims` names the axes of the array as it was flattened, and the
  // builder takes `varies` and `components` from it.
  mestra::set_coordinates(s, coordinates, "m",
                          {"group:member", "node", {"component", 2}});
  mestra::add_node_array(s, "pressure", pressure, "Pa", {"row", "node"});
  mestra::write(ds, "family.mes");

  const mestra::Dataset d = mestra::read("family.mes");
  const mestra::Support* got = d.support("s0");
  const mestra::ArraySlot* p = got->node_array("pressure");
  const long long nodes = got->n_nodes, cells = got->n_cells;
  std::printf("aligned: %s nodes: %lld cells: %lld\n",
              d.aligned ? "True" : "False", nodes, cells);
  std::printf("pressure %s %s\n", names_of(p->data.dims).c_str(),
              p->units->c_str());
  std::printf("pressure at row 1 node 3: %.1f\n", p->data.at_f64({1, 3, 0}));
  // `instance` names the leading axis of an array that varies along a
  // group, so this is wing_b's node 2.
  std::printf("x of node 2 for wing_b: %.1f\n",
              got->coordinates->data.at_f64({1, 2, 0}));
}
