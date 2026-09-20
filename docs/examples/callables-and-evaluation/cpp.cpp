// A callable and evaluation: a file with no rows that produces rows.
// See README.md in this directory for the data and the output.
#include <cstdio>
#include <vector>

#include "mestra/mestra.hpp"

int main() {
  mestra::Dataset ds;
  ds.writer = "mestra examples 1";
  ds.created = "2026-09-19T00:00:00Z";
  // No rows, so there is no observed range: the domain the model is
  // valid over is said out loud.  Fetch the key by name rather than
  // hold what `add_key` returned -- adding one keeps the vector
  // sorted, which invalidates references into it.
  ds.add_key("mach", {}, "condition", "1");
  ds.add_key("alpha", {}, "condition", "degree");
  ds.key("mach")->lower = 0.1;
  ds.key("mach")->upper = 0.9;
  ds.key("alpha")->lower = 0.0;
  ds.key("alpha")->upper = 8.0;
  // y = A x + b per output, over the keys mach and alpha; `shape` is
  // what the output's slot holds after the row axis.  `add_callable`
  // takes the type, the dictionary and the repr from the object.
  ds.add_callable("m1", mestra::Affine({"mach", "alpha"},
      {{"cl", {{2.0, 0.1}, {0.05}, {}}},
       {"pressure", {{1., 0., 2., 0., 3., .5, 4., .5, 5., 1., 6., 1.},
                     {0., .1, .2, .3, .4, .5}, {6, 1}}}}));
  mestra::Support& s = ds.add_mesh_support("s0", 6, {9, 9}, {0, 4, 8},
                                           {0, 1, 4, 3, 1, 2, 5, 4});
  mestra::set_coordinates(s, {0, 0, 1, 0, 2, 0, 0, 1, 1, 1, 2, 1}, "m",
                          {"node", {"component", 2}});
  // A callable slot stores nothing, so its component axis has no
  // values to take a length from and is given one.
  mestra::add_callable_node_array(
      s, "pressure", "Pa", {"row", "node", {"component", 1}}, "m1", "pressure");
  mestra::add_callable_scalar(ds, "cl", "1", "m1", "cl");
  mestra::write(ds, "model.mes");

  const mestra::Dataset d = mestra::read("model.mes");
  std::printf("rows: %lld callables: ['%s']\n",
              static_cast<long long>(d.n_rows), d.callables.front().id.c_str());
  std::printf("cl source: %s\n", d.scalar("cl")->source.c_str());
  mestra::KeysTable table;
  table.add_column("mach", {0.5});
  table.add_column("alpha", {4.0});
  const mestra::Dataset out = mestra::evaluate(d, table);
  const mestra::Scalar* cl = out.scalar("cl");
  std::printf("evaluated rows: %lld source: %s\n",
              static_cast<long long>(out.n_rows), cl->source.c_str());
  std::printf("cl: %.2f\n", cl->values[0]);
  const mestra::Array& p = out.support("s0")->node_array("pressure")->data;
  std::printf("pressure: [%.1f", p.f64[0]);
  for (std::size_t i = 1; i < p.f64.size(); ++i) std::printf(" %.1f", p.f64[i]);
  std::printf("]\n");
}
