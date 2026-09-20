# The conformance corpus, run in this implementation's own test suite
# (SPEC.md section 15).  No implementation is the reference: what this
# file checks is the specification and the golden files under
# vectors/, and nothing else.

using Test
using Mestra
using JSON3
using NCDatasets
using HDF5

const HERE = @__DIR__
const REPO = normpath(joinpath(HERE, "..", ".."))
const CASES = joinpath(REPO, "vectors", "cases")
const SCRATCH = mktempdir()

case_names() = sort(readdir(CASES))
case_file(name) = joinpath(CASES, name, "case.mes")
expected(name) = JSON3.read(read(joinpath(CASES, name, "expected.json"),
                                String))

"""Section 30: a float in expected.json is the C format %.17e, and a
comparison parses it to float64 and requires bit equality."""
function parse_expected(s::AbstractString)
    s == "nan" && return NaN
    s == "inf" && return Inf
    s == "-inf" && return -Inf
    return parse(Float64, s)
end

bitequal(a::Float64, b::Float64) =
    reinterpret(UInt64, a) == reinterpret(UInt64, b)

"""One probe, read back through the public reader."""
function probe_value(ds::Mestra.Dataset, p)
    slot = String(p.slot)
    parts = split(slot, '/'; keepempty = false)
    idx = Dict{Symbol,Int}()
    for (json, name) in (("row", :row), ("instance", :instance),
                         ("draw", :draw), ("node", :node),
                         ("component", :component))
        haskey(p, json) && (idx[name] = Int(p[json]) + 1)
    end
    if parts[1] == "keys"
        return Mestra.values(ds, ds.keys[parts[2]])[idx[:row]]
    elseif parts[1] == "scalars"
        return Mestra.values(ds, ds.scalars[parts[2]])[idx[:row]]
    elseif parts[1] == "row_support"
        return ds.row_support[idx[:row]]
    elseif parts[1] == "callables"
        v = ds.callables[parts[2]].dict
        for k in parts[3:end]
            v = v[k]
        end
        haskey(p, "component") && return v[idx[:node], idx[:component]]
        haskey(p, "node") && return v[idx[:node]]
        return v[]
    elseif parts[1] == "supports"
        sup = ds.supports[Mestra.support_by_name(ds, parts[2])]
        if parts[3] == "cell_types"
            return sup.cell_types[Int(p["cell"]) + 1]
        elseif parts[3] == "cell_offsets"
            return sup.cell_offsets[Int(p["cell_plus_one"]) + 1]
        elseif parts[3] == "cell_connectivity"
            return sup.cell_connectivity[Int(p["index"]) + 1]
        elseif parts[3] == "coordinates"
            return Mestra.at(Mestra.values(ds, sup.coordinates); idx...)
        elseif parts[3] == "node_arrays"
            return Mestra.at(Mestra.values(ds, sup.node_arrays[parts[4]]);
                             idx...)
        elseif parts[3] == "cell_arrays"
            return Mestra.at(Mestra.values(ds, sup.cell_arrays[parts[4]]);
                             idx...)
        end
    end
    error("a probe path this test does not know: $(slot)")
end

function check_probe(ds, p)
    got = probe_value(ds, p)
    want = String(p.value)
    if got isa AbstractFloat
        return bitequal(Float64(got), parse_expected(want))
    end
    return string(Int(got)) == want
end

# --------------------------------------- the tagged form of section 30

cflat(a::AbstractArray) =
    ndims(a) <= 1 ? collect(a) :
    vec(permutedims(collect(a), ntuple(i -> ndims(a) - i + 1, ndims(a))))

function tagged_ok(got, want)
    t = String(want["t"])
    if t == "dict"
        got isa AbstractDict || return false
        Set(String.(keys(got))) == Set(String.(keys(want["v"]))) || return false
        return all(tagged_ok(got[String(k)], v) for (k, v) in want["v"])
    elseif t == "null"
        return got === nothing
    elseif t == "bool"
        return got isa Bool && got == want["v"]
    elseif t == "i64"
        return got isa Integer && !(got isa Bool) && Int64(got) == want["v"]
    elseif t == "f64"
        return got isa AbstractFloat &&
               bitequal(Float64(got), parse_expected(String(want["v"])))
    elseif t == "str"
        return got isa AbstractString && String(got) == String(want["v"])
    elseif t == "strings"
        got isa AbstractArray || return false
        collect(size(got)) == Int.(want["shape"]) || return false
        return all(String(a) == String(b)
                   for (a, b) in zip(cflat(got), want["data"]))
    elseif t == "array"
        got isa AbstractArray || return false
        collect(size(got)) == Int.(want["shape"]) || return false
        dtype = String(want["dtype"])
        flat = cflat(got)
        if dtype == "float64"
            eltype(got) === Float64 || return false
            return all(bitequal(Float64(a), parse_expected(String(b)))
                       for (a, b) in zip(flat, want["data"]))
        elseif dtype == "int64"
            eltype(got) === Int64 || return false
        elseif dtype == "int32"
            eltype(got) === Int32 || return false
        elseif dtype == "bool"
            eltype(got) === Bool || return false
        else
            return false
        end
        return all(a == b for (a, b) in zip(flat, want["data"]))
    end
    return false
end

# ---------------------------------------------------------- the tests

@testset "Mestra" begin

@testset "units parser (W10)" begin
    for u in ("1", "m", "m2", "s", "K", "Pa", "W", "W m-2", "m2 s-1",
              "degree", "kg m-3", "m s-1", "J kg-1 K-1", "1e-3 m",
              "kg/(m s2)", "m^3", "%")
        @test Mestra.parse_units(u)
    end
    for u in ("kg/(m s", "", "m//s", "()", "m (")
        @test !Mestra.parse_units(u)
    end
end

@testset "support_id worked examples (section 24)" begin
    @test Mestra.support_id(6; cell_types = UInt8[9, 9],
                            cell_offsets = Int64[0, 4, 8],
                            cell_connectivity =
                                Int64[0, 1, 4, 3, 1, 2, 5, 4]) ==
          "96df395d80ef548444562292de441525ba0b5c8ad00a8dadff19a19c943936c7"
    @test Mestra.support_id(4;
                            axis_coordinates = [0.0, 0.5, 1.0, 1.5]) ==
          "57467fe7370808bdb0ad01b95d963f59e8bc6762f90f96049453ae33bb05a54c"
    @test Mestra.support_id(0) ==
          "af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc"
end

@testset "corpus: validator outcomes" begin
    for name in case_names()
        e = expected(name)
        r = Mestra.validate(case_file(name))
        @test r.errors == sort(String.(e.validator.errors))
        @test r.warnings == sort(String.(e.validator.warnings))
    end
end

@testset "corpus: support ids" begin
    for name in case_names()
        e = expected(name)
        isempty(e.support_ids) && continue
        ds = Mestra.read(case_file(name))
        for (sname, want) in e.support_ids
            i = Mestra.support_by_name(ds, String(sname))
            @test i !== nothing
            @test Mestra.support_id(ds.supports[i]) == String(want)
        end
    end
end

@testset "corpus: probes" begin
    n = 0
    for name in case_names()
        e = expected(name)
        isempty(e.probes) && continue
        ds = Mestra.read(case_file(name))
        for p in e.probes
            @test check_probe(ds, p)
            n += 1
        end
    end
    @test n > 0
    @info "probes checked" n
end

@testset "corpus: codec round trip" begin
    n = 0
    for name in case_names()
        e = expected(name)
        isempty(e.codec) && continue
        ds = Mestra.read(case_file(name))
        for (id, want) in e.codec
            @test tagged_ok(ds.callables[String(id)].dict, want)
            n += 1
        end
    end
    @test n > 0
    @info "codec round trips checked" n
end

@testset "corpus: evaluation" begin
    n = 0
    for name in case_names()
        e = expected(name)
        isempty(e.evaluation) && continue
        ds = Mestra.read(case_file(name))
        for ev in e.evaluation
            table = Dict{String,Vector{Float64}}(
                String(k) => [parse_expected(String(x)) for x in v]
                for (k, v) in ev.keys)
            out = Mestra.evaluate(ds, table)
            for p in ev.probes
                @test check_probe(out, p)
                n += 1
            end
        end
    end
    @test n > 0
    @info "evaluation probes checked" n
end

@testset "corpus: read, write, compare (section 30)" begin
    equal = 0
    identical = 0
    total = 0
    for name in case_names()
        isempty(expected(name).validator.errors) || continue
        total += 1
        src = case_file(name)
        dst = joinpath(SCRATCH, name * ".mes")
        ds = Mestra.read(src; lazy = false)
        Mestra.write(ds, dst)
        diff = Mestra.structural_diff(src, dst)
        isempty(diff) || @info "structural difference" name diff
        @test isempty(diff)
        isempty(diff) && (equal += 1)
        read(src) == read(dst) && (identical += 1)
        # what was written must still validate the same way
        @test Mestra.validate(dst).errors == String[]
    end
    @info "read-write-compare" total equal identical
end

@testset "corpus: a lazy read touches no array" begin
    ds = Mestra.read(case_file("mesh_two_rows"))
    @test ds.nrows == 2
    @test ds["pressure"].data === nothing
    @test ds.supports[1].support_id[1:8] == "96df395d"
    # one slot, one row range, and nothing else
    v = Mestra.rows(ds, ds["pressure"], 2:2)
    @test size(v) == (1, 6, 1)
    @test Mestra.at(v; row = 1, node = 4, component = 1) == 204.0
    @test ds["pressure"].data === nothing
    big = Mestra.read(case_file("cascade_varying_geometry"))
    w = Mestra.rows(big, big["mach"], 2:3)
    @test size(w) == (1, 6, 2)
    full = Mestra.permute(Mestra.values(big, big["mach"]),
                          (:row, :node, :component))
    @test Mestra.permute(w, (:row, :node, :component))[1, :, 1] ==
          full[2, :, 1]
end

@testset "axis order and permuting by name" begin
    ds = Mestra.read(case_file("mesh_two_rows"); lazy = false)
    v = Mestra.values(ds, ds["pressure"])
    # Julia is column major and the file is C order, so the axes are
    # reversed: (component, node, row) for a (row, node, component)
    # array.  The names come with it, so nothing counts axes.
    @test Mestra.dimnames(v) == (:component, :node, :row)
    @test size(v) == (1, 6, 2)
    p = Mestra.permute(v, (:row, :node, :component))
    @test Mestra.dimnames(p) == (:row, :node, :component)
    @test p[2, 4, 1] == 204.0
    @test Mestra.at(v; row = 2, node = 4, component = 1) == 204.0
    # docs/example.md: 105 is what a reader that took the axes by
    # position would return
    @test p[2, 4, 1] != 105.0
    c = Mestra.values(ds, ds.supports[1].coordinates)
    @test Mestra.dimnames(c) == (:component, :node, Symbol("group:member"))
    @test Mestra.at(c; instance = 2, node = 3, component = 1) == 3.0
    @test_throws Mestra.MestraError Mestra.permute(v, (:row, :node))
    @test_throws Mestra.MestraError Mestra.at(v; row = 1, cheese = 1)
end

@testset "dimension names come from the link, not from NAME" begin
    ds = Mestra.read(case_file("mesh_two_rows"))
    @test ds["pressure"].ldims == [:row, :node, :component]
    @test ds.supports[1].coordinates.ldims ==
          [Symbol("group:member"), :node, :component]
    # NAME is the same sentence in every scale; a reader that took the
    # dimension name from it would find them all called the same thing
    HDF5.h5open(case_file("mesh_two_rows"), "r") do f
        a = read(attributes(f["row"])["NAME"])
        b = read(attributes(f["component_1"])["NAME"])
        @test startswith(a, "This is a netCDF dimension")
        @test a[1:53] == b[1:53]
    end
end

@testset "the affine callable (section 27)" begin
    ds = Mestra.read(case_file("affine_zero_rows"))
    c = Mestra.callable(ds, "m1")
    @test c isa Mestra.Affine
    @test c.keys == ["mach", "alpha"]
    @test sprint(show, c) == "affine(mach, alpha -> cl, pressure)"
    out = c(Dict("mach" => [0.5], "alpha" => [4.0]))
    @test bitequal(out["cl"][1], 1.45)
    want = [0.5, 1.1, 3.7, 4.3, 6.9, 7.5]
    got = vec(out["pressure"])
    @test all(bitequal(a, b) for (a, b) in zip(got, want))
    # b added last, no fused multiply-add: accumulating b first differs
    # in the last place
    @test bitequal(out["cl"][1], 2.0 * 0.5 + 0.1 * 4.0 + 0.05)
    # the other two accepted keys tables of section 26
    out2 = c((mach = [0.5], alpha = [4.0]))
    @test bitequal(out2["cl"][1], 1.45)
    out3 = c(([4.0 0.5], ["alpha", "mach"]))
    @test bitequal(out3["cl"][1], 1.45)
    @test_throws Mestra.MestraError c(Dict("mach" => [0.5]))
end

@testset "evaluate produces a dataset that can be written" begin
    ds = Mestra.read(case_file("affine_zero_rows"))
    out = Mestra.evaluate(ds, Dict("mach" => [0.5], "alpha" => [4.0]))
    @test out.nrows == 1
    @test out.scalars["cl"].source == "data"
    @test out.supports[1].node_arrays["pressure"].source == "data"
    path = joinpath(SCRATCH, "evaluated.mes")
    Mestra.write(out, path)
    r = Mestra.validate(path)
    @test r.errors == String[]
    back = Mestra.read(path; lazy = false)
    @test bitequal(Mestra.values(back, back.scalars["cl"])[1], 1.45)
    v = Mestra.permute(Mestra.values(back, back["pressure"]),
                       (:row, :node, :component))
    @test all(bitequal(v[1, i, 1], w)
              for (i, w) in pairs([0.5, 1.1, 3.7, 4.3, 6.9, 7.5]))
    # the support is the same one, and a tool knows it from one
    # attribute
    @test back.supports[1].support_id == ds.supports[1].support_id
end

@testset "the dictionary codec (sections 17 and 25)" begin
    d = Dict{String,Any}(
        "an_int" => Int64(42),
        "a_float" => 42.0,
        "a_bool" => true,
        "a_string" => "skål",
        "nothing_at_all" => nothing,
        "numbers" => [1.0, 2.0, 3.0],
        "ints" => Int32[1, 2, 3],
        "flags" => [true, false],
        "matrix" => [1.0 2.0; 3.0 4.0; 5.0 6.0],
        "names" => ["mach", "alpha"],
        "empty" => Float64[],
        "nested" => Dict{String,Any}("type" => "allowed here",
                                     "repr" => "and here"))
    path = joinpath(SCRATCH, "codec.mes")
    HDF5.h5open(path, "w") do f
        g = Mestra.create_group(f, "g")
        Mestra.write_dict(g, d)
    end
    back = HDF5.h5open(path, "r") do f
        Mestra.read_dict(f["g"])
    end
    @test Set(keys(back)) == Set(keys(d))
    @test back["an_int"] === Int64(42)
    @test back["a_float"] === 42.0
    @test back["a_bool"] === true
    @test back["a_string"] == "skål"
    @test back["nothing_at_all"] === nothing
    @test back["numbers"] == [1.0, 2.0, 3.0]
    @test eltype(back["ints"]) === Int32
    @test back["flags"] == [true, false]
    @test eltype(back["flags"]) === Bool
    @test back["matrix"] == [1.0 2.0; 3.0 4.0; 5.0 6.0]
    @test back["names"] == ["mach", "alpha"]
    @test size(back["empty"]) == (0,) && eltype(back["empty"]) === Float64
    @test back["nested"]["type"] == "allowed here"
    # a zero-dimensional array is written as the number it holds
    HDF5.h5open(joinpath(SCRATCH, "zerod.mes"), "w") do f
        g = Mestra.create_group(f, "g")
        Mestra.write_dict(g, Dict{String,Any}("t" => fill(1.5)))
    end
    z = HDF5.h5open(joinpath(SCRATCH, "zerod.mes"), "r") do f
        Mestra.read_dict(f["g"])
    end
    @test z["t"] === 1.5
    # what the codec must refuse
    HDF5.h5open(joinpath(SCRATCH, "refuse.mes"), "w") do f
        g = Mestra.create_group(f, "g")
        @test_throws Mestra.MestraError Mestra.write_dict(g,
            Dict{String,Any}("x" => Float32[1.0]))
        @test_throws Mestra.MestraError Mestra.write_dict(g,
            Dict{String,Any}("mestra_x" => 1))
        @test_throws Mestra.MestraError Mestra.write_dict(g,
            Dict{String,Any}("x" => "a\0b"))
    end
end

@testset "building a dataset from arrays" begin
    ds = Mestra.Dataset(writer = "mestra.jl test 0",
                        created = "2026-09-19T00:00:00Z")
    Mestra.add_category_table!(ds, "member", ["wing_a", "wing_b"])
    Mestra.add_key!(ds, "mach", [0.4, 0.8]; role = :condition, units = "1")
    Mestra.add_key!(ds, "member", [0, 1]; role = :group,
                    category = "member")
    Mestra.add_scalar!(ds, "cl", [0.25, 0.55]; units = "1")
    coords = cat([0.0 0.0; 1.0 0.0; 2.0 0.0; 0.0 1.0; 1.0 1.0; 2.0 1.0],
                 [0.0 0.0; 1.5 0.0; 3.0 0.0; 0.0 1.0; 1.5 1.0; 3.0 1.0];
                 dims = 3)
    coords = permutedims(coords, (3, 1, 2))     # (instance, node, comp)
    s = Mestra.add_mesh_support!(ds, "s0";
            coordinates = coords,
            dims = (Symbol("group:member"), :node, :component),
            cell_types = UInt8[9, 9], cell_offsets = Int64[0, 4, 8],
            cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])
    # a (row, node) matrix: the component axis is added for you
    Mestra.add_node_array!(ds, s, "pressure",
                           [101.0 102 103 104 105 106;
                            201.0 202 203 204 205 206]; units = "Pa")
    Mestra.add_cell_array!(ds, s, "region", [0, 1];
                           role = :label, dims = (:cell,),
                           category = "region")
    Mestra.add_category_table!(ds, "region", ["inlet", "outlet"])
    # the bounds were filled in from the data
    @test ds.keys["mach"].lower == 0.4
    @test ds.keys["mach"].upper == 0.8
    # and the support id from the cells
    @test s.support_id ==
          "96df395d80ef548444562292de441525ba0b5c8ad00a8dadff19a19c943936c7"
    path = joinpath(SCRATCH, "built.mes")
    Mestra.write(ds, path)
    r = Mestra.validate(path)
    @test r.errors == String[]
    @test r.warnings == String[]
    back = Mestra.read(path; lazy = false)
    @test back.nrows == 2
    @test Mestra.at(Mestra.values(back, back["pressure"]);
                    row = 2, node = 4, component = 1) == 204.0
    @test Mestra.at(Mestra.values(back, back.supports[1].coordinates);
                    instance = 2, node = 3, component = 1) == 3.0
end

@testset "building a model file with a callable slot" begin
    ds = Mestra.Dataset(writer = "mestra.jl test 0",
                        created = "2026-09-19T00:00:00Z")
    Mestra.add_key!(ds, "mach", Float64[]; role = :condition, units = "1",
                    bounds = (0.1, 0.9))
    Mestra.add_key!(ds, "alpha", Float64[]; role = :condition,
                    units = "degree", bounds = (-2.0, 10.0))
    s = Mestra.add_mesh_support!(ds, "s0";
            coordinates = [0.0 0.0; 1.0 0.0; 2.0 0.0;
                           0.0 1.0; 1.0 1.0; 2.0 1.0],
            dims = (:node, :component),
            cell_types = UInt8[9, 9], cell_offsets = Int64[0, 4, 8],
            cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])
    c = Mestra.affine(["mach", "alpha"], Dict(
        "cl" => (A = [2.0 0.1], b = [0.05], shape = Int64[]),
        "pressure" => (A = [1.0 0.0; 2.0 0.0; 3.0 0.5;
                            4.0 0.5; 5.0 1.0; 6.0 1.0],
                       b = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5],
                       shape = Int64[6, 1])))
    Mestra.add_callable!(ds, "m1", c)
    Mestra.add_callable_scalar!(ds, "cl"; units = "1", id = "m1",
                                output = "cl")
    Mestra.add_callable_slot!(ds, s, "pressure"; units = "Pa",
                              components = 1, id = "m1",
                              output = "pressure")
    path = joinpath(SCRATCH, "model.mes")
    Mestra.write(ds, path)
    @test Mestra.validate(path).errors == String[]
    back = Mestra.read(path)
    @test back.nrows == 0
    @test back.scalars["cl"].source == "callable:m1"
    out = Mestra.evaluate(back, Dict("mach" => [0.5], "alpha" => [4.0]))
    @test bitequal(Mestra.values(out, out.scalars["cl"])[1], 1.45)
end

@testset "notes and private are carried, never interpreted" begin
    ds = Mestra.read(case_file("mesh_two_rows"); lazy = false)
    Mestra.set_notes!(ds, Dict("solver" => "a solver, version 3",
                               "licence" => "CC-BY-4.0",
                               "iterations" => 1200,
                               "residual" => 1.0e-6,
                               "converged" => true))
    Mestra.set_private!(ds, Dict("our_own_record" => "kept, not read"))
    @test_throws Mestra.MestraError Mestra.set_notes!(ds,
        Dict("not a legal name" => 1))
    path = joinpath(SCRATCH, "noted.mes")
    Mestra.write(ds, path)
    r = Mestra.validate(path)
    @test r.errors == String[]
    @test r.warnings == String[]
    back = Mestra.read(path)
    @test back.notes !== nothing
    got = Dict(a.name => a.value for a in back.notes.attrs)
    @test got["solver"] == "a solver, version 3"
    @test got["iterations"] === Int64(1200)
    @test got["residual"] === 1.0e-6
    @test got["converged"] === true
    @test back.private !== nothing
    # a round trip keeps them unchanged
    again = joinpath(SCRATCH, "noted2.mes")
    Mestra.write(Mestra.read(path; lazy = false), again)
    @test isempty(Mestra.structural_diff(path, again))
end

@testset "gzip and shuffle, the two portable filters (section 23)" begin
    ds = Mestra.Dataset(writer = "mestra.jl test 0",
                        created = "2026-09-19T00:00:00Z")
    Mestra.add_key!(ds, "mach", collect(range(0.1, 0.9, length = 32));
                    role = :condition, units = "1")
    Mestra.add_scalar!(ds, "cl", collect(1.0:32.0); units = "1",
                       deflate = 4, shuffle = true)
    s = Mestra.add_mesh_support!(ds, "s0";
            coordinates = [0.0 0.0; 1.0 0.0; 2.0 0.0;
                           0.0 1.0; 1.0 1.0; 2.0 1.0],
            dims = (:node, :component),
            cell_types = UInt8[9, 9], cell_offsets = Int64[0, 4, 8],
            cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])
    Mestra.add_node_array!(ds, s, "pressure",
                           repeat(collect(1.0:32.0), 1, 6); units = "Pa",
                           deflate = 9)
    path = joinpath(SCRATCH, "compressed.mes")
    Mestra.write(ds, path)
    r = Mestra.validate(path)
    @test r.errors == String[]
    @test r.warnings == String[]
    back = Mestra.read(path; lazy = false)
    @test back.scalars["cl"].deflate == 4
    @test back.scalars["cl"].shuffle
    @test back["pressure"].deflate == 9
    @test Mestra.at(Mestra.values(back, back["pressure"]);
                    row = 7, node = 3, component = 1) == 7.0
    @test isempty(Mestra.structural_diff(path, path))
end

@testset "mistakes name the rule they break" begin
    ds = Mestra.Dataset()
    @test_throws Mestra.MestraError Mestra.add_key!(ds, "x", [1.0];
                                                    role = :nonsense)
    e = try
        Mestra.add_key!(ds, "mestra_x", [1.0]; role = :condition,
                        units = "1")
        Mestra.write(ds, joinpath(SCRATCH, "bad.mes"))
        nothing
    catch err
        err
    end
    @test e isa Mestra.MestraError && e.rule == "E33"
    @test occursin("E33", sprint(showerror, e))
    ds2 = Mestra.Dataset()
    Mestra.add_key!(ds2, "m", [1.0, 2.0]; role = :condition, units = "1")
    @test_throws Mestra.MestraError Mestra.add_key!(ds2, "g", [0];
                                                    role = :group)
end

@testset "what is written is a netCDF-4 file with the right dimensions" begin
    for (name, want) in (("mesh_two_rows",
                          Dict("row" => 2, "component_1" => 1,
                               "component_2" => 2, "group_member" => 2,
                               "category_member" => 2,
                               "category_region" => 2)),
                         ("draws_and_summaries",
                          Dict("row" => 2, "component_1" => 1,
                               "component_2" => 2, "draw_3" => 3)))
        path = joinpath(SCRATCH, name * ".mes")
        NCDatasets.NCDataset(path, "r") do nc
            for (dim, len) in want
                @test haskey(nc.dim, dim)
                @test nc.dim[dim] == len
            end
        end
    end
    # the dimension names of one variable, in the file's own order
    NCDatasets.NCDataset(joinpath(SCRATCH, "mesh_two_rows.mes"), "r") do nc
        g = nc.group["supports"].group["s0"].group["node_arrays"]
        @test NCDatasets.dimnames(g["pressure"]) ==
              ("component_1", "node", "row")
    end
end

@testset "post-processing written against the format" begin
    ds = Mestra.read(case_file("mesh_two_rows"); lazy = false)
    st = Mestra.field_statistics(ds, ds["pressure"])
    @test length(st) == 2
    @test st[1].row == 1 && st[1].mean == 103.5
    @test st[2].row == 2 && st[2].min == 201.0 && st[2].max == 206.0
    byregion = Mestra.field_statistics(ds, ds["region"], by = "region")
    @test Set(x.region for x in byregion) == Set(["inlet", "outlet"])

    # integration over a region of a label, with a weight array
    w = Mestra.Dataset(writer = "mestra.jl test 0",
                       created = "2026-09-19T00:00:00Z")
    Mestra.add_category_table!(w, "region", ["inlet", "outlet"])
    Mestra.add_key!(w, "mach", [0.4, 0.8]; role = :condition, units = "1")
    ws = Mestra.add_mesh_support!(w, "s0";
             coordinates = [0.0 0.0; 1.0 0.0; 2.0 0.0;
                            0.0 1.0; 1.0 1.0; 2.0 1.0],
             dims = (:node, :component),
             cell_types = UInt8[9, 9], cell_offsets = Int64[0, 4, 8],
             cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])
    Mestra.add_node_array!(w, ws, "pressure",
                           [1.0 2 3 4 5 6; 10.0 20 30 40 50 60];
                           units = "Pa")
    Mestra.add_node_array!(w, ws, "measure", fill(0.5, 6);
                           role = :weight, units = "m2", dims = (:node,),
                           recomputed = true)
    Mestra.add_node_array!(w, ws, "region", Int32[0, 0, 0, 1, 1, 1];
                           role = :label, dims = (:node,),
                           category = "region")
    total = Mestra.integrate(w, w["pressure"]; weight = "measure")
    @test size(total) == (2, 1)
    @test total[1, 1] == 0.5 * sum(1:6)
    inlet = Mestra.integrate(w, w["pressure"]; weight = "measure",
                             by = "region", region = "inlet")
    @test inlet[1, 1] == 0.5 * (1 + 2 + 3)
    @test inlet[2, 1] == 0.5 * (10 + 20 + 30)
    wpath = joinpath(SCRATCH, "weighted.mes")
    Mestra.write(w, wpath)
    @test Mestra.validate(wpath).errors == String[]
    @test Mestra.validate(wpath).warnings == String[]

    # a time series at a node, along one trajectory
    t = Mestra.read(case_file("transient_fixed_mesh"); lazy = false)
    times, xs = Mestra.time_series(t, t["u"]; node = 3,
                                   trajectory = "r000")
    @test times == [0.0, 0.1, 0.3]
    @test xs == [302.0, 312.0, 322.0]
    times2, xs2 = Mestra.time_series(t, t["u"]; node = 1,
                                     trajectory = 1)
    @test times2 == [0.0, 0.25]

    # a split that honours the unit of generalisation
    sc = Mestra.read(case_file("scalars_only"); lazy = false)
    parts = Mestra.grouped_split(sc; fractions = ["train" => 2 / 3,
                                                  "test" => 1 / 3])
    @test sort(vcat(parts["train"], parts["test"])) == collect(1:6)
    g = Mestra.values(sc, sc.keys["geometry"])
    @test isempty(intersect(Set(g[parts["train"]]), Set(g[parts["test"]])))
    @test isempty(Mestra.split_leaks(sc))
    leaky = Mestra.read(case_file("warn_w01"); lazy = false)
    @test !isempty(Mestra.split_leaks(leaky))
    # a file with no unit of generalisation is refused, not guessed at
    none = Mestra.read(case_file("labels_tables"); lazy = false)
    @test_throws Mestra.MestraError Mestra.grouped_split(none)
end

@testset "the two files of docs/example.md, checked as it asks" begin
    # docs/example.md, "Checking an implementation against these two"
    one = Mestra.read(joinpath(REPO, "docs", "examples",
                               "mesh_two_rows.mes"); lazy = false)
    two = Mestra.read(joinpath(REPO, "docs", "examples",
                               "affine_zero_rows.mes"))
    @test Mestra.support_id(one.supports[1]) == one.supports[1].support_id
    @test Mestra.support_id(two.supports[1]) == two.supports[1].support_id
    @test Mestra.at(Mestra.values(one, one["pressure"]);
                    row = 2, node = 4, component = 1) == 204.0
    @test one["pressure"].ldims == [:row, :node, :component]
    @test one.supports[1].support_id == two.supports[1].support_id
    d = two.callables["m1"].dict
    @test d["keys"] == ["mach", "alpha"]
    @test d["outputs"]["cl"]["shape"] == Int64[]
    @test eltype(d["outputs"]["cl"]["shape"]) === Int64
    out = Mestra.callable(two, "m1")(Dict("mach" => [0.5], "alpha" => [4.0]))
    @test bitequal(out["cl"][1], 1.45)
end

end # testset Mestra
