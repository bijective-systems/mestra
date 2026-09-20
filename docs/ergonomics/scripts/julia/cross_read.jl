# Read another language's d1_family.mes, permute by name and check the
# one deterministic value.  Run: julia --project=julia cross_read.jl L=D ...

using Mestra

for arg in ARGS
    label, d = split(arg, "="; limit = 2)
    println("##### d1_family written by ", label, " #####")
    ds = Mestra.read(joinpath(d, "d1_family.mes"))
    println("    ", ds.nrows, " rows, aligned = ", ds.aligned)

    c = Mestra.values(ds, ds.supports[1].coordinates)
    println("    coordinates dims: ", Mestra.dimnames(c))
    p = Mestra.permute(c, (Symbol("group:member"), :node, :component))
    println("    permuted: ", Mestra.dimnames(p), " size ", size(p))
    println("    p[2, 3, 1] = ", p[2, 3, 1])
    println("    at(instance=2, node=3, component=1) = ",
            Mestra.at(c; instance = 2, node = 3, component = 1))

    e = Mestra.values(ds, ds["cad_edge_t"])
    println("    cad_edge_t dims: ", Mestra.dimnames(e),
            "  node 3 (0-based) = ", Mestra.at(e; node = 4, component = 1))
    # ds.keys["mach"].values is `nothing` after a lazy read and raises a
    # bare MethodError on Nothing.  Mestra.values is the documented way,
    # but the README never says the field exists and is empty.
    println("    mach row 1 (0-based) = ",
            Mestra.values(ds, ds.keys["mach"])[2])
end
