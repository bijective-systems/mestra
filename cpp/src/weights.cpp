// Cell measures and the weights that follow from them.  Nothing here
// reads or writes a file: it works on a Support that is already in
// memory, which is the only place connectivity and coordinates are
// both to hand.
#include "mestra/weights.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>

#include "mestra/io.hpp"
#include "names.hpp"

namespace mestra {
namespace {

[[noreturn]] void refuse(const std::string& path,
                         const std::string& message) {
  throw Error("", "mestra::compute_weights " + path + ": " + message);
}

// A point of the flat (node, component) block, padded to three
// dimensions so that one set of formulas covers d = 1, 2 and 3.
struct Point {
  double x = 0.0;
  double y = 0.0;
  double z = 0.0;
};

Point point_at(const std::vector<double>& coordinates,
               std::int64_t components, std::int64_t node) {
  Point p;
  const std::size_t at =
      static_cast<std::size_t>(node) * static_cast<std::size_t>(components);
  if (at < coordinates.size()) p.x = coordinates[at];
  if (components > 1 && at + 1 < coordinates.size()) p.y = coordinates[at + 1];
  if (components > 2 && at + 2 < coordinates.size()) p.z = coordinates[at + 2];
  return p;
}

Point minus(const Point& a, const Point& b) {
  return Point{a.x - b.x, a.y - b.y, a.z - b.z};
}

Point cross(const Point& a, const Point& b) {
  return Point{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
               a.x * b.y - a.y * b.x};
}

double dot(const Point& a, const Point& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

double length(const Point& a) { return std::sqrt(dot(a, a)); }

// The area of a planar polygon, by Newell's method.  It is the
// shoelace formula in two dimensions and the projected area in three,
// it is exact for any simple polygon rather than only a convex one,
// and it needs no triangulation to choose, so a triangle, a
// quadrilateral and a polygon of any size are one case here.
double polygon_area(const std::vector<Point>& p) {
  Point n;
  for (std::size_t i = 0; i < p.size(); ++i) {
    const Point& a = p[i];
    const Point& b = p[(i + 1) % p.size()];
    n.x += a.y * b.z - a.z * b.y;
    n.y += a.z * b.x - a.x * b.z;
    n.z += a.x * b.y - a.y * b.x;
  }
  return 0.5 * length(n);
}

// The signed volume of a tetrahedron; the pieces of a decomposition
// are summed signed and the total taken absolute, so that a
// decomposition of a cell whose faces are not planar still adds up.
double tet_volume(const Point& a, const Point& b, const Point& c,
                  const Point& d) {
  return dot(minus(b, a), cross(minus(c, a), minus(d, a))) / 6.0;
}

double sum_tets(const std::vector<Point>& p,
                const std::vector<std::array<int, 4>>& tets) {
  double v = 0.0;
  for (const std::array<int, 4>& t : tets) {
    v += tet_volume(p[static_cast<std::size_t>(t[0])],
                    p[static_cast<std::size_t>(t[1])],
                    p[static_cast<std::size_t>(t[2])],
                    p[static_cast<std::size_t>(t[3])]);
  }
  return std::fabs(v);
}

const char* cell_type_name(std::uint8_t code) {
  switch (code) {
    case 1: return "vertex";
    case 3: return "line";
    case 5: return "triangle";
    case 7: return "polygon";
    case 9: return "quadrilateral";
    case 10: return "tetrahedron";
    case 12: return "hexahedron";
    case 13: return "wedge";
    case 14: return "pyramid";
    case 21: return "quadratic line";
    case 22: return "quadratic triangle";
    case 23: return "quadratic quadrilateral";
    case 24: return "quadratic tetrahedron";
    case 25: return "quadratic hexahedron";
    case 26: return "quadratic wedge";
    case 27: return "quadratic pyramid";
    default: return "an unknown cell type";
  }
}

}  // namespace

int cell_dimension(std::uint8_t cell_type) {
  switch (cell_type) {
    case 3: return 1;                       // line
    case 5: case 7: case 9: return 2;       // triangle, polygon, quad
    case 10: case 12: case 13: case 14: return 3;
    default: return 0;                      // not measured here
  }
}

double cell_measure(std::uint8_t cell_type,
                    const std::vector<std::int64_t>& nodes,
                    const std::vector<double>& coordinates,
                    std::int64_t components) {
  const int dimension = cell_dimension(cell_type);
  if (dimension == 0) {
    throw Error("", std::string("mestra::cell_measure: a ") +
                        cell_type_name(cell_type) + " (cell type " +
                        internal::format_i64(cell_type) +
                        ") has no measure this version computes; section "
                        "3 asks for the measure of the linear cell types "
                        "and this build stops there");
  }
  if (components < dimension) {
    throw Error("", std::string("mestra::cell_measure: a ") +
                        cell_type_name(cell_type) + " is " +
                        internal::format_i64(dimension) +
                        "-dimensional and the coordinates have " +
                        internal::format_i64(components) + " component(s)");
  }
  std::vector<Point> p;
  p.reserve(nodes.size());
  for (const std::int64_t n : nodes) {
    p.push_back(point_at(coordinates, components, n));
  }
  switch (cell_type) {
    case 3:
      return length(minus(p[1], p[0]));
    case 5:
    case 7:
    case 9:
      return polygon_area(p);
    case 10:
      return std::fabs(tet_volume(p[0], p[1], p[2], p[3]));
    case 12:
      // The six tetrahedra that share the main diagonal 0-6 of a
      // hexahedron in the node order of section 20.
      return sum_tets(p, {{{0, 1, 2, 6}}, {{0, 2, 3, 6}}, {{0, 3, 7, 6}},
                          {{0, 7, 4, 6}}, {{0, 4, 5, 6}}, {{0, 5, 1, 6}}});
    case 13:
      return sum_tets(p, {{{0, 1, 2, 3}}, {{1, 2, 3, 4}}, {{2, 3, 4, 5}}});
    case 14:
      return sum_tets(p, {{{0, 1, 2, 4}}, {{0, 2, 3, 4}}});
    default:
      break;
  }
  throw Error("", std::string("mestra::cell_measure: no measure for ") +
                      cell_type_name(cell_type));
}

ArraySlot& compute_weights(Support& s, Location where,
                           const WeightOptions& options) {
  const std::string path = "/supports/" + s.name +
                           (where == Location::Node ? "/node_arrays/"
                                                    : "/cell_arrays/") +
                           options.name;
  if (!s.coordinates.has_value()) {
    refuse(path,
           "the support carries no coordinates, and a measure is "
           "computed from coordinates and connectivity");
  }
  const ArraySlot& xyz = *s.coordinates;
  if (xyz.is_callable() || xyz.data.f64.empty()) {
    refuse(path,
           "the support's coordinates hold no values, and a measure is "
           "computed from coordinates and connectivity");
  }
  const std::int64_t components = xyz.components;
  const std::size_t nodes = static_cast<std::size_t>(s.n_nodes);
  const std::size_t cells = static_cast<std::size_t>(s.n_cells);
  const std::size_t per_instance = nodes * static_cast<std::size_t>(
                                               components < 1 ? 1 : components);
  const std::size_t instances =
      per_instance == 0 ? 1 : std::max<std::size_t>(
                                  1, xyz.data.f64.size() / per_instance);

  if (s.kind == "none") {
    refuse(path, "a support of kind none has neither nodes nor cells");
  }
  if (where == Location::Cell && s.kind != "mesh") {
    refuse(path, "a support of kind " + s.kind +
                     " has no cells; ask for the node weights instead");
  }

  // The dimension of the measure, and one message rather than many
  // when the mesh mixes dimensions.
  int dimension = 0;
  if (s.kind == "mesh") {
    for (std::size_t c = 0; c < cells && c < s.cell_types.size(); ++c) {
      const int d = cell_dimension(s.cell_types[c]);
      if (d == 0) {
        refuse(path, std::string("cell ") + internal::format_i64(
                         static_cast<std::int64_t>(c)) + " is a " +
                         cell_type_name(s.cell_types[c]) +
                         " and this version measures the linear cell "
                         "types only");
      }
      if (dimension == 0) {
        dimension = d;
      } else if (dimension != d) {
        refuse(path,
               "the mesh mixes cells of " +
                   internal::format_i64(dimension) + " and " +
                   internal::format_i64(d) +
                   " dimensions, so its cells have no one measure");
      }
    }
    if (dimension == 0) dimension = 1;
  } else {
    dimension = 1;                       // an axis support is a line
  }

  const std::size_t count = where == Location::Node ? nodes : cells;
  std::vector<double> weight(instances * count, 0.0);

  for (std::size_t instance = 0; instance < instances; ++instance) {
    std::vector<double> block;
    const std::size_t from = instance * per_instance;
    if (from + per_instance <= xyz.data.f64.size()) {
      block.assign(xyz.data.f64.begin() + static_cast<std::ptrdiff_t>(from),
                   xyz.data.f64.begin() +
                       static_cast<std::ptrdiff_t>(from + per_instance));
    } else {
      block = xyz.data.f64;
    }
    double* out = weight.data() + instance * count;

    if (s.kind == "axis") {
      // No cells: the node's share is half of each segment it touches,
      // which is the trapezoid rule and the lumped measure of a line.
      // An axis support's coordinates have one component (section 6),
      // but the stride is taken from the slot rather than assumed.
      const std::size_t stride =
          components < 1 ? 1 : static_cast<std::size_t>(components);
      auto position = [&block, stride](std::size_t n) {
        const std::size_t at = n * stride;
        return at < block.size() ? block[at] : 0.0;
      };
      for (std::size_t n = 0; n < nodes; ++n) {
        double w = 0.0;
        if (n + 1 < nodes) {
          w += 0.5 * std::fabs(position(n + 1) - position(n));
        }
        if (n > 0) w += 0.5 * std::fabs(position(n) - position(n - 1));
        out[n] = w;
      }
      continue;
    }

    for (std::size_t c = 0; c < cells; ++c) {
      if (c + 1 >= s.cell_offsets.size()) break;
      const std::size_t begin =
          static_cast<std::size_t>(s.cell_offsets[c]);
      const std::size_t end =
          static_cast<std::size_t>(s.cell_offsets[c + 1]);
      if (end > s.cell_connectivity.size() || end < begin) break;
      const std::vector<std::int64_t> cell(
          s.cell_connectivity.begin() + static_cast<std::ptrdiff_t>(begin),
          s.cell_connectivity.begin() + static_cast<std::ptrdiff_t>(end));
      const double measure =
          cell_measure(s.cell_types[c], cell, block, components);
      if (where == Location::Cell) {
        out[c] = measure;
      } else if (!cell.empty()) {
        // Lumped: the cell's measure shared equally among its nodes.
        const double share = measure / static_cast<double>(cell.size());
        for (const std::int64_t n : cell) {
          if (n >= 0 && static_cast<std::size_t>(n) < nodes) {
            out[static_cast<std::size_t>(n)] += share;
          }
        }
      }
    }
  }

  ArraySlot a;
  a.name = options.name;
  a.role = "weight";
  a.varies = xyz.varies;
  a.components = 1;
  a.source = "data";
  a.recomputed = true;
  a.location = where;
  if (xyz.units.has_value()) {
    a.units = internal::units_power(*xyz.units, dimension);
  }
  a.data.dtype = DType::Float64;
  if (a.varies != "none") {
    a.data.dims.push_back(a.varies);
    a.data.shape.push_back(instances);
  }
  a.data.dims.push_back(where == Location::Node ? "node" : "cell");
  a.data.shape.push_back(count);
  a.data.dims.push_back("component");
  a.data.shape.push_back(1);
  a.data.f64 = std::move(weight);

  std::vector<ArraySlot>& into =
      where == Location::Node ? s.node_arrays : s.cell_arrays;
  for (std::size_t i = 0; i < into.size(); ++i) {
    if (into[i].name == a.name) {
      into[i] = std::move(a);
      return into[i];
    }
  }
  auto at = std::lower_bound(
      into.begin(), into.end(), a,
      [](const ArraySlot& x, const ArraySlot& y) {
        return bytes_less(x.name, y.name);
      });
  return *into.insert(at, std::move(a));
}

}  // namespace mestra
