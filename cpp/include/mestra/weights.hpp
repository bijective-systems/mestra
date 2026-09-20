// Integration weights, computed from connectivity (SPEC.md sections 3
// and 6: "computed from connectivity, never imported").  A file that
// arrives with an upstream exporter's weights in it is a file whose
// weights nobody can check; this is the other half of that rule, the
// half that lets a writer produce them.
#ifndef MESTRA_WEIGHTS_HPP
#define MESTRA_WEIGHTS_HPP

#include <string>
#include <vector>

#include "mestra/dataset.hpp"

namespace mestra {

// What `compute_weights` may be told.
struct WeightOptions {
  // The array's name.  "weight" at both locations unless the caller
  // names it, which is what docs/api-conventions.md section 3 asks
  // for.
  std::string name = "weight";
};

// Adds the integration weights of a support at one location, and
// returns the slot it added: cell measure (length, area or volume by
// cell type) at `Location::Cell`, and the lumped share of the
// adjacent cell measure at `Location::Node`.  The array carries role
// `weight`, the coordinate units raised to the support's dimension,
// `recomputed = true`, and the `varies` of the coordinates it was
// computed from, so that a family of meshes gets one instance per
// member.
//
// An existing array of that name at that location is replaced, so
// calling this twice leaves one weight array and not two.
//
// Measured here: line, triangle, quadrilateral, polygon, tetrahedron,
// hexahedron, wedge and pyramid.  A surface cell of any shape goes
// through Newell's method, which is exact for a polygon that is not
// convex and gives the projected area for one that is not planar; a
// volume cell is a signed sum of tetrahedra.
//
// Refuses, with a message naming the cell type and the cell index,
// anything it cannot measure: the quadratic cell types of section 20,
// which are refused rather than approximated by their corner nodes, a
// support whose cells are not all of one dimension, and a support with
// no coordinates.  An `axis` support has no cells, so its node weights
// come from the spacing of its coordinates and `Location::Cell` on
// one is refused.
ArraySlot& compute_weights(Support& s, Location where,
                           const WeightOptions& options = WeightOptions());

// The measure of one cell: length for a line, area for a surface cell
// and volume for a volume cell, in the coordinate units raised to the
// cell's own dimension.  `nodes` are the cell's node indices and
// `coordinates` is the flat (node, component) block for one instance.
// Throws Error naming the cell type when this version cannot measure
// it.
double cell_measure(std::uint8_t cell_type,
                    const std::vector<std::int64_t>& nodes,
                    const std::vector<double>& coordinates,
                    std::int64_t components);

// The topological dimension of a cell type: 1 for a line, 2 for a
// surface cell, 3 for a volume cell, and 0 for a type this version
// does not measure.
int cell_dimension(std::uint8_t cell_type);

}  // namespace mestra

#endif  // MESTRA_WEIGHTS_HPP
