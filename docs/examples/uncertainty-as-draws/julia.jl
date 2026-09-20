# Uncertainty as draws: four whole fields per row, and two summaries.
# See README.md in this directory for the data and the output.
using Mestra

base = [101.0 102 103 104 105 106; 201.0 202 203 204 205 206]
draws = [base[r, n] + (-1, -1, 1, 1)[d] for r in 1:2, d in 1:4, n in 1:6]
over_draws(x) = dropdims(sum(x; dims = 2); dims = 2) ./ 4
mean = over_draws(draws)
std = sqrt.(over_draws((draws .- reshape(mean, 2, 1, 6)) .^ 2))

ds = Mestra.Dataset(writer = "mestra examples 1")
Mestra.add_key!(ds, "mach", [0.4, 0.8]; role = :condition, units = "1")
s = Mestra.add_mesh_support!(ds, "s0"; dims = (:node, :component),
    coordinates = [0.0 0.0; 1.0 0.0; 2.0 0.0; 0.0 1.0; 1.0 1.0; 2.0 1.0],
    cell_types = UInt8[9, 9], cell_offsets = Int64[0, 4, 8],
    cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])
Mestra.add_node_array!(ds, s, "pressure", draws; units = "Pa",
    dims = (:row, :draw, :node), statistic = "draw")
Mestra.add_node_array!(ds, s, "pressure_mean", mean; units = "Pa",
    dims = (:row, :node), statistic = "mean", of = "pressure")
Mestra.add_node_array!(ds, s, "pressure_std", std; units = "Pa",
    dims = (:row, :node), statistic = "std", of = "pressure")
Mestra.write(ds, "draws.mes")

d = Mestra.read("draws.mes")
p = d["pressure"]
v = Mestra.permute(Mestra.values(d, p), (:row, :draw, :node, :component))
println("pressure ", Mestra.dimnames(v), " ", p.statistic)
println("draw 0 of row 0: ", v[1, 1, :, 1])
for name in ("pressure_mean", "pressure_std")
    a = d[name]
    println(name, " ", a.statistic, " of ", a.of, " at row 0, node 0: ",
            Mestra.at(Mestra.values(d, a); row = 1, node = 1, component = 1))
end
