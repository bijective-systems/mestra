# Reading someone else's file: ask the file what is in it, then take
# one value by name. See README.md for the data and the output.
using Mestra

path = joinpath(@__DIR__, "..", "mesh_two_rows.mes")
println("valid: ", isvalid(Mestra.validate(path)))

d = Mestra.read(path)
println(d.nrows, " rows, aligned: ", d.aligned)
println("keys: ", [(n, d.keys[n].role) for n in Mestra.key_order(d)])
println("scalars: ", sort(collect(keys(d.scalars))))
for s in Mestra.support_order(d)
    println("support ", s.name, " ", s.kind, " ", s.n_nodes, " nodes ",
            s.n_cells, " cells")
    println("  node arrays: ", sort(collect(keys(s.node_arrays))))
    println("  cell arrays: ", sort(collect(keys(s.cell_arrays))))
end
p = d["pressure"]
v = Mestra.permute(Mestra.values(d, p), (:row, :node, :component))
println("pressure ", Mestra.dimnames(v), " ", p.units, " ", p.varies)
# One based here, so the README's row 1, node 3 is (2, 4).
println("pressure at row 1 node 3: ", v[2, 4, 1])
println("row 0 alone: ", size(Mestra.rows(d, p, 1:1)))
region = d["region"]
println("region is a ", region.role, " over ",
        d.categories[region.category].entries)
