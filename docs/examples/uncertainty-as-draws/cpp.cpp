// Uncertainty as draws: four whole fields per row, and two summaries.
// See README.md in this directory for the data and the output.
//
// The summaries are computed here rather than asserted: C++ has no
// mean-over-an-axis, so the two loops below are what the one numpy
// call in python.py does, and the README's "exactly 1" is the answer
// they come out with.
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "mestra/mestra.hpp"

int main() {
  std::vector<double> draws, mean, deviation;
  for (int r = 1; r <= 2; ++r)                       // (row, draw, node)
    for (const double offset : {-1., -1., 1., 1.})
      for (int n = 1; n <= 6; ++n) draws.push_back(100.0 * r + n + offset);
  for (std::size_t i = 0; i < 12; ++i) {             // one row and node
    const std::size_t at = i / 6 * 24 + i % 6;       // its first draw
    double m = 0.0, variance = 0.0;
    for (std::size_t k = 0; k < 4; ++k) m += draws[at + k * 6] / 4.0;
    for (std::size_t k = 0; k < 4; ++k)
      variance += (draws[at + k * 6] - m) * (draws[at + k * 6] - m) / 4.0;
    mean.push_back(m);
    deviation.push_back(std::sqrt(variance));
  }

  mestra::Dataset ds;
  ds.writer = "mestra examples 1";
  ds.created = "2026-09-19T00:00:00Z";
  ds.add_key("mach", {0.4, 0.8}, "condition", "1");
  mestra::Support& s = ds.add_mesh_support("s0", 6, {9, 9}, {0, 4, 8},
                                           {0, 1, 4, 3, 1, 2, 5, 4});
  mestra::set_coordinates(s, {0, 0, 1, 0, 2, 0, 0, 1, 1, 1, 2, 1}, "m",
                          {"node", {"component", 2}});
  // `node` comes from the support and `row` from what is left over,
  // but two unknown lengths are refused rather than guessed at, so the
  // draw axis is given one.  `statistic` and `of` are plain attributes
  // with no shape behind them, assigned on the slot handed back.
  mestra::add_node_array(s, "pressure", draws, "Pa",
                         {"row", {"draw", 4}, "node"}).statistic = "draw";
  mestra::ArraySlot& mn =
      mestra::add_node_array(s, "pressure_mean", mean, "Pa", {"row", "node"});
  mn.statistic = "mean";
  mn.of = "pressure";
  mestra::ArraySlot& sd = mestra::add_node_array(s, "pressure_std", deviation,
                                                 "Pa", {"row", "node"});
  sd.statistic = "std";
  sd.of = "pressure";
  mestra::write(ds, "draws.mes");

  const mestra::Dataset d = mestra::read("draws.mes");
  const mestra::Support* got = d.support("s0");
  const mestra::ArraySlot* p = got->node_array("pressure");
  // Every axis of a stored array is named, which is what python.py
  // prints as a tuple.
  std::string axes;
  for (const std::string& n : p->data.dims)
    axes += (axes.empty() ? "'" : ", '") + n + "'";
  std::printf("pressure (%s) %s\n", axes.c_str(), p->statistic->c_str());
  std::printf("draw 0 of row 0: [%.0f.", p->data.at_f64({0, 0, 0, 0}));
  for (std::size_t n = 1; n < 6; ++n)
    std::printf(" %.0f.", p->data.at_f64({0, 0, n, 0}));
  std::printf("]\n");
  for (const char* name : {"pressure_mean", "pressure_std"}) {
    const mestra::ArraySlot& a = *got->node_array(name);
    std::printf("%s %s of %s at row 0, node 0: %.1f\n", name,
                a.statistic->c_str(), a.of->c_str(), a.data.at_f64({0, 0, 0}));
  }
}
