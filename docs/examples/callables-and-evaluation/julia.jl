# A callable and evaluation: a file with no rows that produces rows.
# See README.md in this directory for the data and the output.
using Mestra

model = Mestra.affine(["mach", "alpha"], Dict(
    "cl" => (A = [2.0 0.1], b = [0.05], shape = Int64[]),
    "pressure" => (A = [1.0 0; 2 0; 3 0.5; 4 0.5; 5 1; 6 1],
                   b = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5], shape = Int64[6, 1])))

ds = Mestra.Dataset(writer = "mestra examples 1")
Mestra.add_key!(ds, "mach", Float64[]; role = :condition, units = "1",
                lower = 0.1, upper = 0.9)
Mestra.add_key!(ds, "alpha", Float64[]; role = :condition,
                units = "degree", lower = 0.0, upper = 8.0)
Mestra.add_callable!(ds, "m1", model)
s = Mestra.add_mesh_support!(ds, "s0";
    coordinates = [0.0 0.0; 1.0 0.0; 2.0 0.0; 0.0 1.0; 1.0 1.0; 2.0 1.0],
    dims = (:node, :component), cell_types = UInt8[9, 9],
    cell_offsets = Int64[0, 4, 8],
    cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])
Mestra.add_callable_slot!(ds, s, "pressure"; units = "Pa", components = 1,
                          callable = "m1", output = "pressure")
Mestra.add_callable_scalar!(ds, "cl"; units = "1", callable = "m1",
                            output = "cl")
Mestra.write(ds, "model.mes")

d = Mestra.read("model.mes")
println("rows: ", d.nrows, " callables: ", sort(collect(keys(d.callables))))
println("cl source: ", d.scalars["cl"].source)
out = Mestra.evaluate(d, Dict("mach" => [0.5], "alpha" => [4.0]))
println("evaluated rows: ", out.nrows, " source: ", out.scalars["cl"].source)
println("cl: ", Mestra.at(Mestra.values(out, out.scalars["cl"]); row = 1))
v = Mestra.values(out, out["pressure"])
println("pressure: ", Mestra.permute(v, (:row, :node, :component))[1, :, 1])
