# Evaluate a Python-written callable file in Julia, as julia/README.md
# spells it.  Run: julia --project=julia model_eval.jl MODEL.mes OUT.mes

using Mestra

path, out = ARGS[1], ARGS[2]
ds = Mestra.read(path)
e = Mestra.evaluate(ds, Dict("mach" => [0.5], "alpha" => [4.0]))

println("    cl = ", Mestra.values(e, e.scalars["cl"]))
p = Mestra.values(e, e["pressure"])
println("    pressure dims: ", Mestra.dimnames(p))
q = Mestra.permute(p, (:row, :node, :component))
println("    pressure = ", [q[1, n, 1] for n in 1:6])
println("    support id: ", ds.supports[1].support_id[1:16])

Mestra.write(e, out)
println("    wrote ", out)
