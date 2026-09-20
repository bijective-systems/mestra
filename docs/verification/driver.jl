# Phase 3 verification driver for the Julia implementation.
#
# Speaks the same JSON as the other three drivers, so that the harness
# can compare them without knowing anything about any of them.
#
#   julia --project=julia docs/verification/driver.jl check FILE PROBES
#   julia ... driver.jl write  IN.mes OUT.mes
#   julia ... driver.jl eval   FILE SPEC.json
#   julia ... driver.jl evalw  FILE SPEC.json OUT.mes
#   julia ... driver.jl codec  FILE

using Mestra
using JSON3
using Printf

const AXES = ("row", "instance", "draw", "node", "component", "index")

function fmtvalue(v)
    if v isa Bool
        return string(Int(v))
    elseif v isa AbstractFloat
        return fmt17(Float64(v))
    elseif v isa Integer
        return string(v)
    elseif v isa AbstractString
        return String(v)
    else
        return string(v)
    end
end

function fmt17(x::Float64)
    isnan(x) && return "nan"
    isinf(x) && return x > 0 ? "inf" : "-inf"
    return @sprintf("%.17e", x)
end

"""One probe, found by axis name through the public reader."""
function probe_value(ds, p)
    slot = String(p["slot"])
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
    elseif parts[1] == "categories"
        return ds.categories[parts[2]].entries[Int(p["category"]) + 1]
    elseif parts[1] == "callables"
        v = ds.callables[parts[2]].dict
        for k in parts[3:end]
            v = v[k]
        end
        # Section 30: a dictionary dataset has no logical dimension
        # names; the index fields apply in a fixed order to the axes
        # in file order.
        want = Int[]
        for name in AXES
            haskey(p, name) && push!(want, Int(p[name]) + 1)
        end
        isempty(want) && return v[]
        return v[want...]
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
    error("a probe path this driver does not know: $(slot)")
end

function do_check(path, probes_path)
    out = Dict{String,Any}("errors" => String[], "warnings" => String[],
                           "support_ids" => Dict{String,String}(),
                           "probes" => Any[], "trouble" => String[])
    try
        r = Mestra.validate(path)
        out["errors"] = String.(r.errors)
        out["warnings"] = String.(r.warnings)
    catch e
        push!(out["trouble"], "validate: $(sprint(showerror, e))")
    end
    probes = JSON3.read(read(probes_path, String))
    local ds
    ok = true
    try
        ds = Mestra.read(path)
    catch e
        ok = false
        push!(out["trouble"], "read: $(sprint(showerror, e))")
    end
    if ok
        try
            for s in ds.supports
                out["support_ids"][s.name] = Mestra.support_id(s)
            end
        catch e
            push!(out["trouble"], "support_id: $(sprint(showerror, e))")
        end
        for p in probes
            try
                push!(out["probes"], fmtvalue(probe_value(ds, p)))
            catch e
                push!(out["probes"], nothing)
                push!(out["trouble"],
                      "probe $(p["slot"]): $(sprint(showerror, e))")
            end
        end
    else
        for _ in probes
            push!(out["probes"], nothing)
        end
    end
    return out
end

function do_write(src, dst)
    ds = Mestra.read(src)
    Mestra.materialise!(ds)
    Mestra.write(ds, dst)
    return Dict("ok" => true)
end

function do_eval(path, spec_path, out_path = nothing)
    spec = JSON3.read(read(spec_path, String))
    table = Dict{String,Vector{Float64}}()
    for (k, vs) in pairs(spec["keys"])
        table[String(k)] = [parse(Float64, String(v)) for v in vs]
    end
    out = Dict{String,Any}("probes" => Any[], "trouble" => String[])
    ds = Mestra.read(path)
    got = Mestra.evaluate(ds, table)
    for p in spec["probes"]
        try
            push!(out["probes"], fmtvalue(probe_value(got, p)))
        catch e
            push!(out["probes"], nothing)
            push!(out["trouble"], "$(p["slot"]): $(sprint(showerror, e))")
        end
    end
    out_path === nothing || Mestra.write(got, out_path)
    return out
end

"""The tagged form of section 30, for comparing dictionaries."""
function tagged(v)
    v === nothing && return Dict("t" => "null")
    v === missing && return Dict("t" => "null")
    if v isa AbstractDict
        return Dict("t" => "dict",
                    "v" => Dict(String(k) => tagged(x) for (k, x) in pairs(v)))
    elseif v isa Bool
        return Dict("t" => "bool", "v" => v)
    elseif v isa AbstractString
        return Dict("t" => "str", "v" => String(v))
    elseif v isa Integer
        return Dict("t" => "i64", "v" => Int64(v))
    elseif v isa AbstractFloat
        return Dict("t" => "f64", "v" => fmt17(Float64(v)))
    elseif v isa AbstractArray
        shape = collect(size(v))
        # This reader holds a dictionary array with the file's own
        # subscripts, so the C-order flattening of section 30 is the
        # reverse permutation and not Julia's own column-major one.
        flat = ndims(v) <= 1 ? collect(v) :
               vec(permutedims(v, reverse(1:ndims(v))))
        if eltype(v) <: AbstractString
            return Dict("t" => "strings", "shape" => shape,
                        "data" => [String(x) for x in flat])
        elseif eltype(v) <: Bool
            return Dict("t" => "array", "dtype" => "bool", "shape" => shape,
                        "data" => [Bool(x) for x in flat])
        elseif eltype(v) <: Int32
            return Dict("t" => "array", "dtype" => "int32", "shape" => shape,
                        "data" => [Int64(x) for x in flat])
        elseif eltype(v) <: Integer
            return Dict("t" => "array", "dtype" => "int64", "shape" => shape,
                        "data" => [Int64(x) for x in flat])
        else
            return Dict("t" => "array", "dtype" => "float64", "shape" => shape,
                        "data" => [fmt17(Float64(x)) for x in flat])
        end
    end
    return Dict("t" => "?", "v" => string(v))
end

function do_codec(path)
    ds = Mestra.read(path)
    out = Dict{String,Any}()
    for (id, c) in pairs(ds.callables)
        out[String(id)] = Dict("type" => c.type, "dict" => tagged(c.dict))
    end
    return out
end

function run_job(job)
    op = String(job["op"])
    if op == "check"
        return do_check(String(job["file"]), String(job["probes"]))
    elseif op == "write"
        return do_write(String(job["src"]), String(job["dst"]))
    elseif op == "eval"
        return do_eval(String(job["file"]), String(job["spec"]))
    elseif op == "evalw"
        return do_eval(String(job["file"]), String(job["spec"]),
                       String(job["mes"]))
    elseif op == "codec"
        return do_codec(String(job["file"]))
    end
    error("unknown op $(op)")
end

function do_batch(jobs_path)
    jobs = JSON3.read(read(jobs_path, String))
    n = 0
    for job in jobs
        result = try
            run_job(job)
        catch e
            Dict("failed" => sprint(showerror, e))
        end
        open(String(job["out"]), "w") do io
            write(io, JSON3.write(result))
        end
        n += 1
    end
    return Dict("jobs" => n)
end

function main()
    mode = ARGS[1]
    result = if mode == "batch"
        do_batch(ARGS[2])
    elseif mode == "check"
        do_check(ARGS[2], ARGS[3])
    elseif mode == "write"
        do_write(ARGS[2], ARGS[3])
    elseif mode == "eval"
        do_eval(ARGS[2], ARGS[3])
    elseif mode == "evalw"
        do_eval(ARGS[2], ARGS[3], ARGS[4])
    elseif mode == "codec"
        do_codec(ARGS[2])
    else
        error("unknown mode $(mode)")
    end
    println(JSON3.write(result))
end

main()
