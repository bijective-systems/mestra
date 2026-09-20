# A support and a field: the same six rows on a two-quad mesh.
# See README.md in this directory for the data and the output.
using Mestra

xy = [0.0 0.0; 1.0 0.0; 2.0 0.0; 0.0 1.0; 1.0 1.0; 2.0 1.0]
coordinates = permutedims(cat([xy .* [s 1.0] for s in (1.0, 1.5, 2.0)]...;
                              dims = 3), (3, 1, 2))
pressure = [100.0 * r + n for r in 1:6, n in 1:6]

ds = Mestra.Dataset(writer = "mestra examples 1")
Mestra.add_key!(ds, "mach", [0.4, 0.8, 0.4, 0.8, 0.4, 0.8];
                role = :condition, units = "1")
Mestra.add_category_table!(ds, "member", ["wing_a", "wing_b", "wing_c"])
Mestra.add_key!(ds, "member", [0, 0, 1, 1, 2, 2]; role = :group,
                category = "member")
Mestra.set_generalisation_group!(ds, "member")
support = Mestra.add_mesh_support!(ds, "s0"; coordinates = coordinates,
    dims = (:instance, :node, :component), varies = "group:member",
    cell_types = UInt8[9, 9], cell_offsets = Int64[0, 4, 8],
    cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])
Mestra.add_node_array!(ds, support, "pressure", pressure; units = "Pa",
                       dims = (:row, :node))
Mestra.write(ds, "family.mes")

d = Mestra.read("family.mes")
s = d.supports[1]
p = s.node_arrays["pressure"]
v = Mestra.permute(Mestra.values(d, p), (:row, :node, :component))
println("aligned: ", d.aligned, " nodes: ", s.n_nodes, " cells: ", s.n_cells)
println("pressure ", Mestra.dimnames(v), " ", p.units)
# One based here, so the README's row 1, node 3 is (2, 4).
println("pressure at row 1 node 3: ", v[2, 4, 1])
println("x of node 2 for wing_b: ",
        Mestra.at(Mestra.values(d, s.coordinates);
                  instance = 2, node = 3, component = 1))
