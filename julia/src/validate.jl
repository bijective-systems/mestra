# The validator of section 14.
#
# Every rule has an identifier and the identifiers are stable, so this
# file is organised by identifier and says which rule each check is.
# Retired identifiers (E07, W09) are never emitted.  The validator
# works on the file itself rather than on the reader's model, so that
# a file the reader would refuse still gets a full report.
#
# Two rules beyond section 14 as it stands, for what a file that was
# not written by a conforming writer can be:
#
#   E40  a link that is not a hard link anywhere in the public tree.
#        It is reported and never followed: a soft link may point at
#        nothing or in a circle, and an external link would open
#        another file on this file's say-so.
#   E41  an object the validator could not read, with its path. The
#        pass then continues, so that one unreadable object does not
#        hide everything after it.
#
# Every per-object check below runs inside `guard!`, which turns
# anything thrown into E41 against that object's path and carries on.

"""
    ValidationReport

`errors` and `warnings` are the rule identifiers of section 14, sorted
and without duplicates; `findings` says where each came from.
"""
struct ValidationReport
    errors::Vector{String}
    warnings::Vector{String}
    findings::Vector{Finding}
end

Base.isvalid(r::ValidationReport) = isempty(r.errors)

function Base.show(io::IO, ::MIME"text/plain", r::ValidationReport)
    if isempty(r.findings)
        print(io, "mestra: valid, no warnings")
        return
    end
    println(io, "mestra: ", length(r.errors), " error id(s), ",
            length(r.warnings), " warning id(s)")
    for f in r.findings
        println(io, "  ", f.rule, "  ", f.path, ": ", f.message)
    end
end

mutable struct Validator
    f::HDF5.File
    idx::ScaleIndex
    findings::Vector{Finding}
    nrows::Int
    supports::Vector{String}
    row_support::Vector{Int}
    aligned::Bool
    categories::Dict{String,Vector{String}}
    keyroles::Dict{String,String}
    keyvals::Dict{String,Any}
    keycat::Dict{String,String}
    gen_group::Union{Nothing,String}
    missing_public::Bool
    max_elements::Int
end

report!(v::Validator, rule, path, msg) =
    push!(v.findings, Finding(rule, String(path), String(msg)))

"""Run one object's checks, and turn anything thrown into E41 against
that object rather than into the end of the pass."""
function guard!(fn, v::Validator, path)
    try
        return fn()
    catch e
        e isa MestraError && e.rule !== nothing ?
            report!(v, e.rule, path, e.msg) :
            report!(v, "E41", path,
                    "this object could not be read: " *
                    first(sprint(showerror, e), 200))
        return nothing
    end
end

"""The children of a group reached by a hard link, in name order,
reporting every other link as E40 without following it."""
function vchildren!(v::Validator, g, path)
    out = String[]
    for (name, kind) in child_links(g)
        if kind === :hard
            push!(out, name)
        else
            report!(v, "E40", "$(path)/$(name)",
                    "a $(kind) link; the public tree is hard links and " *
                    "this reader never follows another kind")
        end
    end
    return sort(out, by = codeunits)
end

"""Open a child through its hard link, reporting E41 if it will not
open."""
function vopen!(v::Validator, g, name, path)
    obj = hard_child(g, name)
    obj === nothing && report!(v, "E41", path, "this object would not open")
    return obj
end

"""A root group, if it is one, reached by a hard link."""
function vroot(v::Validator, name)
    obj = hard_child(v.f, name)
    return obj isa HDF5.Group ? obj : nothing
end

const KEY_ATTRS = Set(["role", "units", "lower", "upper", "category",
                       "trajectory_group", "parent"])
const SCALAR_ATTRS = Set(["units", "source", "output", "statistic", "of",
                          "quantile"])
const ARRAY_ATTRS = Set(["role", "varies", "units", "components", "source",
                         "output", "statistic", "of", "quantile", "category",
                         "recomputed", "derived_from", "recipe", "reference"])
const SUPPORT_ATTRS = Set(["kind", "n_nodes", "n_cells", "support_id"])
const CALLABLE_ATTRS = Set(["type", "repr"])
const SUPPORT_DATASETS = Set(["coordinates", "cell_types", "cell_offsets",
                              "cell_connectivity"])

# The node count each cell type code takes (section 20); 0 means
# "three or more", which only the polygon uses.
const CELL_NODES = Dict{Int,Int}(1 => 1, 3 => 2, 5 => 3, 7 => 0, 9 => 4,
                                 10 => 4, 12 => 8, 13 => 6, 14 => 5,
                                 21 => 3, 22 => 6, 23 => 8, 24 => 10,
                                 25 => 20, 26 => 15, 27 => 13)

const DTYPE_BY_ROLE = Dict{String,Vector{DataType}}(
    "coordinates" => [Float64], "field" => [Float64],
    "derived" => [Float64], "weight" => [Float64], "normal" => [Float64],
    "label" => [Int32, Int64])

"""
    validate(path) -> ValidationReport

Check a file against section 14.  The report names rules by identifier
and nothing else, as the conformance corpus does.
"""
function validate(path::AbstractString;
                  max_elements::Integer = DEFAULT_MAX_ELEMENTS)
    if !isfile(String(path))
        return ValidationReport(["E01"], String[],
            [Finding("E01", String(path), "there is no file here")])
    end
    f = try
        HDF5.h5open(String(path), "r")
    catch e
        return ValidationReport(["E01"], String[],
            [Finding("E01", String(path),
                     "not a file this reader can open as HDF5: " *
                     first(sprint(showerror, e), 200))])
    end
    try
        v = Validator(f, ScaleIndex(collect_scales(f)), Finding[], 0,
                      String[], Int[], true, Dict{String,Vector{String}}(),
                      Dict{String,String}(), Dict{String,Any}(),
                      Dict{String,String}(), nothing, false,
                      Int(max_elements))
        run_validator!(v)
        errs = sort(unique([x.rule for x in v.findings if x.rule[1] == 'E']))
        warns = sort(unique([x.rule for x in v.findings if x.rule[1] == 'W']))
        return ValidationReport(errs, warns, v.findings)
    finally
        close(f)
    end
end

function run_validator!(v::Validator)
    for pass in (check_root!, check_names!, collect_categories!,
                 collect_keys!, check_keys!, check_scalars!,
                 check_row_support!, check_supports!, check_callables!,
                 check_every_dataset!, check_unknown!, check_private!)
        guard!(v, "/") do
            pass(v)
        end
    end
    return v
end

# ------------------------------------------------------------- root

iso8601_utc(s::AbstractString) =
    occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|\+00:00)$", s)

function check_root!(v::Validator)
    f = v.f
    a = own_attrs(f)
    check_attr_types!(v, "/", a)
    if !haskey(a, "format")
        report!(v, "E01", "/", "no `format` attribute")
        report!(v, "E17", "/", "`format` is missing")
        v.missing_public = true
    else
        fmt = a["format"].value
        if !(fmt isa AbstractString) || !occursin(r"^mestra/\d+$", fmt)
            report!(v, "E01", "/", "`format` is not \"mestra/<n>\"")
        elseif fmt != "mestra/0"
            report!(v, "E01", "/",
                    "a version 0 reader must refuse $(fmt) outright")
        end
    end
    for name in ("writer", "created")
        if !haskey(a, name)
            report!(v, "E17", "/", "`$(name)` is missing")
            v.missing_public = true
        end
    end
    if haskey(a, "created") && a["created"].value isa AbstractString &&
       !iso8601_utc(a["created"].value)
        report!(v, "W14", "/", "`created` is not an ISO 8601 UTC timestamp")
    end
    if !haskey(a, "aligned")
        report!(v, "E39", "/", "`aligned` is missing")
        v.missing_public = true
    else
        v.aligned = a["aligned"].value === true
    end
    v.gen_group = haskey(a, "generalisation_group") &&
                  a["generalisation_group"].value isa AbstractString ?
                  a["generalisation_group"].value : nothing

    rowscale = hard_child(f, "row")
    if rowscale isa HDF5.Dataset
        guard!(v, "/row") do
            cdims, cmax = disk_shape(rowscale)
            v.nrows = isempty(cdims) ? 0 : cdims[1]
            isempty(cmax) || cmax[1] == -1 || report!(v, "E27", "/row",
                "`row` is not an unlimited dimension")
        end
    end
    sup = vroot(v, "supports")
    if sup !== nothing
        v.supports = String[n for n in vchildren!(v, sup, "/supports")
                            if hard_child(sup, n) isa HDF5.Group]
    end
    length(v.supports) > 1 && report!(v, "W05", "/supports",
        "$(length(v.supports)) supports; index-aligned operations are " *
        "not available")
    if v.aligned && length(v.supports) > 1
        report!(v, "E37", "/",
                "`aligned` is true with $(length(v.supports)) supports")
    elseif !v.aligned && length(v.supports) <= 1
        report!(v, "E37", "/",
                "`aligned` is false with $(length(v.supports)) support(s)")
    end
    return v
end

"""E19: every attribute this specification names has one encoding."""
function check_attr_types!(v::Validator, path::String,
                           a::Dict{String,RawAttr})
    for (name, at) in a
        expected = attr_kind(name)
        expected === nothing && continue
        if !at.scalar
            report!(v, "E19", path,
                    "`$(name)` has a dataspace of $(at.npoints) elements; " *
                    "section 18 gives every attribute a scalar one")
            continue
        end
        if !at.readable
            # A variable-length attribute is not read on purpose: E19
            # says everything there is to say about it.
            at.ti.vlen ?
                report!(v, "E19", path,
                        "`$(name)` is a variable-length string") :
                report!(v, "E41", "$(path)@$(name)",
                        "this attribute could not be read")
            continue
        end
        if at.ti.class === :string
            if expected !== :string
                report!(v, "E19", path, "`$(name)` is a string")
            elseif at.ti.vlen
                report!(v, "E19", path,
                        "`$(name)` is a variable-length string")
            elseif at.ti.cset != HDF5.API.H5T_CSET_UTF8 ||
                   at.ti.strpad != HDF5.API.H5T_STR_NULLPAD
                report!(v, "E19", path,
                        "`$(name)` is not UTF-8 with NUL padding")
            elseif !check_string_bytes(at.raw)
                report!(v, "E26", path, "`$(name)` is not a legal string")
            end
        elseif at.ti.class === :int
            if expected === :bool
                (at.ti.size == 1) || report!(v, "E19", path,
                    "boolean `$(name)` is not int8")
            elseif expected === :int
                (at.ti.size == 8 && at.ti.signed) ||
                    report!(v, "E19", path, "integer `$(name)` is not int64")
            else
                report!(v, "E19", path, "`$(name)` is an integer")
            end
        elseif at.ti.class === :float
            if expected === :float
                at.ti.size == 8 || report!(v, "E19", path,
                    "float `$(name)` is not float64")
            else
                report!(v, "E19", path, "`$(name)` is a float")
            end
        end
    end
    return v
end

function attr_kind(name::AbstractString)
    name in ("aligned", "recomputed") && return :bool
    name in ("n_nodes", "n_cells", "components") && return :int
    name in ("lower", "upper", "quantile") && return :float
    name in ("format", "writer", "created", "generalisation_group", "role",
             "units", "category", "trajectory_group", "parent", "varies",
             "source", "output", "statistic", "of", "derived_from",
             "recipe", "reference", "kind", "support_id", "type",
             "repr") && return :string
    return nothing
end

"""E26: valid UTF-8, and no NUL except in the trailing padding."""
function check_string_bytes(raw::Vector{UInt8})
    body = strip_nul(raw)
    any(==(0x00), body) && return false
    return isvalid(String(body))
end

# ------------------------------------------------------------ names

function check_names!(v::Validator)
    deep = walk_objects(v.f) do path, obj
        for n in split(lstrip(path, '/'), '/')
            isempty(n) && continue
            legal_name(n) || report!(v, "E33", path,
                "`$(n)` is not a legal netCDF-4 name")
        end
        for n in attr_names(obj)
            n in MACHINERY_ATTRS && continue
            legal_name(n) || report!(v, "E33", path,
                "attribute `$(n)` is not a legal netCDF-4 name")
        end
    end
    for p in sort(collect(deep))
        report!(v, "E41", isempty(p) ? "/" : p,
                "groups nested deeper than $(MAX_DEPTH); this validator " *
                "stops there rather than following a file's own depth")
    end
    for group in ("keys", "scalars", "categories", "supports", "callables")
        g = vroot(v, group)
        g === nothing && continue
        for n in vchildren!(v, g, "/$(group)")
            reserved(n) && report!(v, "E33", "/$(group)/$(n)",
                "a producer-chosen name may not begin with `mestra_`")
        end
    end
    supports = vroot(v, "supports")
    supports === nothing && return v
    for s in v.supports
        g = hard_child(supports, s)
        g isa HDF5.Group || continue
        for sub in ("node_arrays", "cell_arrays")
            sg = hard_child(g, sub)
            sg isa HDF5.Group || continue
            for n in vchildren!(v, sg, "/supports/$(s)/$(sub)")
                reserved(n) && report!(v, "E33",
                    "/supports/$(s)/$(sub)/$(n)",
                    "a producer-chosen name may not begin with `mestra_`")
            end
        end
    end
    return v
end

"""Visit every object reachable by hard links, on an explicit stack
and no deeper than MAX_DEPTH.  The call stack is not used, because the
file chooses how deep it goes."""
function walk_objects(fn, root, path = "")
    stack = Tuple{Any,String,Int}[(root, String(path), 0)]
    visited = 0
    deep = Set{String}()
    while !isempty(stack)
        g, base, depth = pop!(stack)
        if depth >= MAX_DEPTH
            base in deep && continue
            push!(deep, base)
            continue
        end
        for (name, kind) in child_links(g)
            kind === :hard || continue
            visited += 1
            visited > MAX_OBJECTS && return deep
            obj = hard_child(g, name)
            obj === nothing && continue
            p = base * "/" * name
            try
                fn(p, obj)
            catch
            end
            obj isa HDF5.Group && push!(stack, (obj, p, depth + 1))
        end
    end
    return deep
end

# ------------------------------------------------------- categories

function collect_categories!(v::Validator)
    g = vroot(v, "categories")
    g === nothing && return v
    for name in vchildren!(v, g, "/categories")
        d = vopen!(v, g, name, "/categories/$(name)")
        if !(d isa HDF5.Dataset)
            d === nothing || report!(v, "E30", "/categories/$(name)",
                "a category table is a dataset")
            continue
        end
        guard!(v, "/categories/$(name)") do
        ti, recs = read_string_records(d; max_elements = v.max_elements)
        if ti.class !== :string || ti.vlen
            report!(v, "E20", "/categories/$(name)",
                    "a category table must be a fixed-length UTF-8 string")
            return
        end
        for r in recs
            check_string_bytes(r) || report!(v, "E26", "/categories/$(name)",
                "an entry is not valid UTF-8 or holds a NUL byte before " *
                "its trailing padding")
        end
        entries = [String(strip_nul(r)) for r in recs]
        v.categories[name] = entries
        longest = maximum(vcat([ncodeunits(e) for e in entries], [1]))
        ti.size > longest && report!(v, "W13", "/categories/$(name)",
            "stored in $(ti.size) bytes where $(longest) would do")
        end
    end
    return v
end

# ------------------------------------------------------------- keys

function collect_keys!(v::Validator)
    g = vroot(v, "keys")
    g === nothing && return v
    for name in vchildren!(v, g, "/keys")
        d = hard_child(g, name)
        d isa HDF5.Dataset || continue
        guard!(v, "/keys/$(name)") do
            a = own_attrs(d)
            haskey(a, "role") && a["role"].value isa AbstractString &&
                (v.keyroles[name] = a["role"].value)
            haskey(a, "category") && a["category"].value isa AbstractString &&
                (v.keycat[name] = a["category"].value)
            v.keyvals[name] = vec(safe_read(d;
                                            max_elements = v.max_elements))
        end
    end
    return v
end

roles_of(v::Validator, role) =
    sort([k for (k, r) in v.keyroles if r == role], by = codeunits)

function check_keys!(v::Validator)
    kg = vroot(v, "keys")
    kg === nothing && return v
    for role in ("time", "split", "id", "status")
        n = length(roles_of(v, role))
        n > 1 && report!(v, "E03", "/keys",
            "$(n) keys with the role $(role), where the role allows " *
            "at most one")
    end
    for name in vchildren!(v, kg, "/keys")
        d = vopen!(v, kg, name, "/keys/$(name)")
        path = "/keys/$(name)"
        d === nothing && continue
        if !(d isa HDF5.Dataset)
            report!(v, "E30", path, "a key must be a dataset")
            report!(v, "E41", path,
                    "this is a group, so there is no key column here to " *
                    "read at all")
            continue
        end
        guard!(v, path) do
        a = own_attrs(d)
        check_attr_types!(v, path, a)
        for n in keys(a)
            n in KEY_ATTRS || report!(v, "W11", path,
                "attribute `$(n)` is not one this reader knows")
        end
        role = get(v.keyroles, name, nothing)
        if role === nothing
            report!(v, "E02", path, "no `role` attribute")
            v.missing_public = true
            return
        end
        if !(Symbol(role) in KEY_ROLES)
            report!(v, "E02", path, "`$(role)` is not a role of section 3")
            return
        end
        kdims, _ = disk_shape(d)
        length(kdims) == 1 || report!(v, "E16", path,
            "a dataset under /keys has exactly one dimension, `row`, " *
            "and this one has $(length(kdims))")
        length(kdims) == 1 && kdims[1] != v.nrows && report!(v, "E16", path,
            "$(kdims[1]) values in a file of $(v.nrows) rows")
        ti = type_info(HDF5.datatype(d))
        check_key_dtype!(v, path, role, ti)
        if role in ("design", "condition", "time")
            if !haskey(a, "units")
                report!(v, "E39", path,
                        "a $(role) key requires `units` (section 19)")
                v.missing_public = true
            elseif a["units"].value isa AbstractString
                parse_units(a["units"].value) || report!(v, "W10", path,
                    "units `$(a["units"].value)` cannot be parsed")
            end
        end
        if role in ("categorical", "group", "split", "status")
            if !haskey(a, "category")
                report!(v, "E39", path,
                        "a $(role) key requires `category` (section 19)")
                v.missing_public = true
            end
        end
        if role == "time" && !isempty(roles_of(v, "group")) &&
           !haskey(a, "trajectory_group")
            report!(v, "E39", path,
                    "the time key requires `trajectory_group` when the " *
                    "file declares a group key")
            v.missing_public = true
        end
        check_key_categories!(v, path, name, role, a)
        check_key_bounds!(v, path, name, a)
        end
    end
    if !isempty(roles_of(v, "group")) && v.gen_group === nothing
        report!(v, "E39", "/",
                "`generalisation_group` is missing where the file " *
                "declares a group key")
        v.missing_public = true
    end
    check_time!(v)
    check_split!(v)
    check_status!(v)
    return v
end

function check_key_dtype!(v::Validator, path, role, ti::TypeInfo)
    if role in ("design", "condition", "time")
        (ti.class === :float && ti.size == 8) || report!(v, "E20", path,
            "a $(role) key must be float64")
    elseif role in ("categorical", "group", "split", "status")
        (ti.class === :int && ti.signed && ti.size in (4, 8)) ||
            report!(v, "E20", path, "a $(role) key must be int32 or int64")
    elseif role == "id"
        ok = (ti.class === :int && ti.signed && ti.size == 8) ||
             (ti.class === :string && !ti.vlen)
        ok || report!(v, "E20", path,
            "an id key must be int64 or a fixed-length UTF-8 string")
    end
    return v
end

function check_key_categories!(v::Validator, path, name, role, a)
    role in ("categorical", "group", "split", "status") || return v
    table = get(v.keycat, name, nothing)
    table === nothing && return v
    if !haskey(v.categories, table)
        report!(v, "E39", path, "no category table called `$(table)`")
        return v
    end
    entries = v.categories[table]
    vals = get(v.keyvals, name, Int[])
    for x in vals
        x isa Integer || continue
        (0 <= x < length(entries)) || report!(v, "E10", path,
            "value $(x) is outside a category table of $(length(entries)) " *
            "entries")
    end
    if role == "split"
        for e in entries
            e in SPLIT_CATEGORIES || report!(v, "E10", path,
                "split category `$(e)` is not one of train, validation, " *
                "test or holdout")
        end
    end
    if role == "group"
        used = Set(Int.(filter(x -> x isa Integer, vals)))
        for (i, e) in pairs(entries)
            (i - 1) in used || report!(v, "W07", path,
                "category `$(e)` is used by no row")
        end
    end
    return v
end

function check_key_bounds!(v::Validator, path, name, a)
    haskey(a, "lower") && haskey(a, "upper") || return v
    lo = a["lower"].value
    hi = a["upper"].value
    (lo isa Real && hi isa Real) || return v
    (isfinite(lo) && isfinite(hi)) || (report!(v, "E19", path,
        "a bound must be finite"); return v)
    vals = get(v.keyvals, name, nothing)
    vals === nothing && return v
    nums = Float64[x for x in vals if x isa Real && isfinite(x)]
    isempty(nums) && return v
    outside = any(x -> x < lo || x > hi, nums)
    if outside
        report!(v, "W04", path, "a value lies outside [$(lo), $(hi)]")
        return v
    end
    observed = maximum(nums) - minimum(nums)
    declared = hi - lo
    # Section 14: the rule does not apply when the observed width is
    # zero, which covers a file with no rows, a key with one distinct
    # value, and a key with no finite value at all.
    observed == 0 && return v
    if declared > 4 * observed
        report!(v, "W08", path,
                "declared bounds are wider than the observed range by " *
                "more than a factor of four")
    end
    return v
end

function check_time!(v::Validator)
    times = roles_of(v, "time")
    kg = vroot(v, "keys")
    kg === nothing && return v
    for t in times
        d = hard_child(kg, t)
        d === nothing && continue
        a = own_attrs(d)
        tg = haskey(a, "trajectory_group") &&
             a["trajectory_group"].value isa AbstractString ?
             a["trajectory_group"].value : nothing
        vals = get(v.keyvals, t, nothing)
        vals === nothing && continue
        groups = tg !== nothing && haskey(v.keyvals, tg) ?
                 v.keyvals[tg] : fill(0, length(vals))
        seen = Dict{Any,Float64}()
        for (i, g) in pairs(groups)
            i <= length(vals) || break
            x = vals[i]
            x isa Real || continue
            if haskey(seen, g) && !(x > seen[g])
                report!(v, "E09", "/keys/$(t)",
                        "time is not strictly increasing within " *
                        "trajectory $(g)")
            end
            seen[g] = Float64(x)
        end
    end
    return v
end

function check_split!(v::Validator)
    splits = roles_of(v, "split")
    isempty(splits) && return v
    v.gen_group === nothing && return v
    haskey(v.keyvals, v.gen_group) || return v
    units = v.keyvals[v.gen_group]
    sv = v.keyvals[splits[1]]
    bag = Dict{Any,Set{Any}}()
    for (i, u) in pairs(units)
        i <= length(sv) || break
        push!(get!(bag, u, Set{Any}()), sv[i])
    end
    for (u, s) in bag
        length(s) > 1 && report!(v, "W01", "/keys/$(splits[1])",
            "the split places rows of generalisation unit $(u) on both " *
            "sides")
    end
    return v
end

function check_status!(v::Validator)
    st = roles_of(v, "status")
    isempty(st) && return v
    name = st[1]
    table = get(v.keycat, name, nothing)
    table === nothing && return v
    entries = get(v.categories, table, String[])
    for x in get(v.keyvals, name, [])
        x isa Integer || continue
        (0 <= x < length(entries)) || continue
        entries[x + 1] == "converged" && continue
        report!(v, "W02", "/keys/$(name)",
                "a row has status `$(entries[x + 1])`")
        break
    end
    return v
end

# ---------------------------------------------------------- scalars

function check_scalars!(v::Validator)
    g = vroot(v, "scalars")
    g === nothing && return v
    for name in vchildren!(v, g, "/scalars")
        obj = vopen!(v, g, name, "/scalars/$(name)")
        obj === nothing && continue
        path = "/scalars/$(name)"
        guard!(v, path) do
        a = own_attrs(obj)
        check_attr_types!(v, path, a)
        for n in keys(a)
            n in SCALAR_ATTRS || report!(v, "W11", path,
                "attribute `$(n)` is not one this reader knows")
        end
        haskey(a, "units") || (report!(v, "E11", path,
            "a scalar requires `units`"); v.missing_public = true)
        haskey(a, "units") && a["units"].value isa AbstractString &&
            !parse_units(a["units"].value) &&
            report!(v, "W10", path, "units cannot be parsed")
        check_source!(v, path, obj, a)
        if obj isa HDF5.Dataset
            ti = type_info(HDF5.datatype(obj))
            (ti.class === :float && ti.size == 8) || report!(v, "E20", path,
                "a scalar must be float64")
            cdims, _ = disk_shape(obj)
            length(cdims) == 1 || report!(v, "E16", path,
                "a dataset under /scalars has exactly one dimension, " *
                "`row`, and this one has $(length(cdims))")
            isempty(cdims) || cdims[1] == v.nrows ||
                report!(v, "E16", path,
                    "$(cdims[1]) elements in a file of $(v.nrows) rows")
            if ti.class === :float && ti.size == 8
                guard!(v, path) do
                    x = vec(safe_read(obj; max_elements = v.max_elements))
                    any(y -> !isfinite(y), x) && report!(v, "W03", path,
                        "a non-finite value")
                end
            end
        end
        check_statistic!(v, path, a)
        end
    end
    return v
end

"""E14, E30 and E36: what `source` says and how the slot is stored."""
function check_source!(v::Validator, path, obj, a)
    if !haskey(a, "source")
        report!(v, "E39", path, "`source` is missing")
        v.missing_public = true
        return v
    end
    src = a["source"].value
    src isa AbstractString || return v
    if src == "data"
        obj isa HDF5.Group && report!(v, "E30", path,
            "a slot whose source is data is a dataset, not a group")
    elseif startswith(src, "callable:")
        id = src[10:end]
        obj isa HDF5.Dataset && report!(v, "E30", path,
            "a slot served by a callable is a group, not a dataset")
        ok = haskey(v.f, "callables") && v.f["callables"] isa HDF5.Group &&
             haskey(v.f["callables"], id)
        ok || report!(v, "E14", path, "no callable with id `$(id)`")
        haskey(a, "output") || (report!(v, "E39", path,
            "`output` is required when source is a callable");
            v.missing_public = true)
    else
        report!(v, "E36", path,
                "`source` is neither `data` nor `callable:<id>`")
    end
    return v
end

"""E12: a statistic and what it is a statistic of."""
function check_statistic!(v::Validator, path, a)
    haskey(a, "statistic") || return v
    st = a["statistic"].value
    st isa AbstractString || return v
    if st == "quantile" && !haskey(a, "quantile")
        report!(v, "E12", path, "a quantile statistic with no `quantile`")
    end
    if !(st in ("value", "draw")) && !haskey(a, "of")
        report!(v, "E12", path,
                "a statistic of `$(st)` does not say what it is of")
    end
    return v
end

# ------------------------------------------------------ row_support

function check_row_support!(v::Validator)
    rsobj = hard_child(v.f, "row_support")
    present = rsobj isa HDF5.Dataset
    if v.aligned && present
        report!(v, "E28", "/row_support",
                "present in a file with `aligned = true`")
    elseif !v.aligned && !present
        report!(v, "E28", "/",
                "absent in a file with `aligned = false`")
    end
    present || return v
    d = rsobj
    guard!(v, "/row_support") do
        ti = type_info(HDF5.datatype(d))
        (ti.class === :int && ti.signed && ti.size == 4) ||
            report!(v, "E20", "/row_support", "/row_support must be int32")
        v.row_support = Int.(vec(safe_read(d;
                                           max_elements = v.max_elements)))
    end
    n = length(v.supports)
    for x in v.row_support
        (0 <= x < n) || report!(v, "E06", "/row_support",
            "row references support $(x) where the file declares $(n)")
    end
    used = Set(v.row_support)
    for (i, s) in pairs(v.supports)
        (i - 1) in used || report!(v, "W15", "/supports/$(s)",
            "no row references this support")
    end
    return v
end

function rows_on_support(v::Validator, i::Int)
    isempty(v.row_support) && return v.nrows
    return count(==(i - 1), v.row_support)
end

# --------------------------------------------------------- supports

function check_supports!(v::Validator)
    sg = vroot(v, "supports")
    sg === nothing && return v
    for name in vchildren!(v, sg, "/supports")
        obj = hard_child(sg, name)
        if obj !== nothing && !(obj isa HDF5.Group)
            report!(v, "E30", "/supports/$(name)",
                    "a support is a group, not a dataset")
            report!(v, "E41", "/supports/$(name)",
                    "this is a dataset, so there is no support here to " *
                    "read at all")
        end
    end
    for (i, name) in pairs(v.supports)
        g = hard_child(sg, name)
        g isa HDF5.Group || continue
        path = "/supports/$(name)"
        guard!(v, path) do
        a = own_attrs(g)
        check_attr_types!(v, path, a)
        for n in keys(a)
            n in SUPPORT_ATTRS || report!(v, "W11", path,
                "attribute `$(n)` is not one this reader knows")
        end
        for req in ("kind", "n_nodes", "n_cells", "support_id")
            haskey(a, req) || (report!(v, "E39", path,
                "`$(req)` is missing"); v.missing_public = true)
        end
        kind = haskey(a, "kind") && a["kind"].value isa AbstractString ?
               a["kind"].value : ""
        n_nodes = haskey(a, "n_nodes") && a["n_nodes"].value isa Integer ?
                  Int(a["n_nodes"].value) : 0
        n_cells = haskey(a, "n_cells") && a["n_cells"].value isa Integer ?
                  Int(a["n_cells"].value) : 0
        kind in ("mesh", "axis", "none") || report!(v, "E39", path,
            "`kind` must be mesh, axis or none")
        types, offsets, conn = check_cells!(v, path, g, kind, n_nodes, n_cells)
        coords = check_coordinates!(v, path, g, kind, n_nodes)
        if haskey(a, "support_id") && a["support_id"].value isa AbstractString
            mesh = kind == "mesh"
            want = support_id(n_nodes;
                              cell_types = mesh ? types : UInt8[],
                              cell_offsets = mesh ? offsets : Int64[],
                              cell_connectivity = mesh ? conn : Int64[],
                              axis_coordinates = kind == "axis" ? coords :
                                                 nothing)
            want == a["support_id"].value || report!(v, "E08", path,
                "`support_id` does not match the stored arrays")
        end
        check_support_arrays!(v, path, g, name, i, kind, n_nodes, n_cells)
        for n in vchildren!(v, g, path)
            obj = hard_child(g, n)
            obj === nothing && continue
            if obj isa HDF5.Group
                n in ("node_arrays", "cell_arrays") || report!(v, "W11",
                    "$(path)/$(n)", "a group this reader does not know")
            elseif !is_scale(obj)
                n in SUPPORT_DATASETS || report!(v, "W11", "$(path)/$(n)",
                    "a dataset this reader does not know")
            end
        end
        end
    end
    return v
end

function check_cells!(v::Validator, path, g, kind, n_nodes, n_cells)
    has = [hard_child(g, n) isa HDF5.Dataset
           for n in ("cell_types", "cell_offsets", "cell_connectivity")]
    if kind == "mesh"
        all(has) || report!(v, "E38", path,
            "a mesh support needs cell_types, cell_offsets and " *
            "cell_connectivity")
    else
        cellscale = hard_child(g, "cell")
        if any(has) || cellscale isa HDF5.Dataset
            report!(v, "E38", path,
                    "an `$(kind)` support carries a cell dataset or a " *
                    "`cell` dimension")
        end
    end
    all(has) || return (UInt8[], Int64[], Int64[])
    read3 = guard!(v, path) do
        (UInt8.(vec(safe_read(g["cell_types"];
                              max_elements = v.max_elements))),
         Int64.(vec(safe_read(g["cell_offsets"];
                              max_elements = v.max_elements))),
         Int64.(vec(safe_read(g["cell_connectivity"];
                              max_elements = v.max_elements))))
    end
    read3 === nothing && return (UInt8[], Int64[], Int64[])
    types, offsets, conn = read3
    ti = type_info(HDF5.datatype(g["cell_types"]))
    (ti.class === :int && !ti.signed && ti.size == 1) ||
        report!(v, "E20", "$(path)/cell_types", "cell_types must be uint8")
    for n in ("cell_offsets", "cell_connectivity")
        t = type_info(HDF5.datatype(g[n]))
        (t.class === :int && t.signed && t.size == 8) ||
            report!(v, "E20", "$(path)/$(n)", "$(n) must be int64")
    end
    for t in types
        haskey(CELL_NODES, Int(t)) || report!(v, "E21", "$(path)/cell_types",
            "cell type code $(Int(t)) is not in the table of section 20")
    end
    ok_offsets = true
    if isempty(offsets) || offsets[1] != 0
        report!(v, "E23", "$(path)/cell_offsets", "does not start at 0")
        ok_offsets = false
    end
    if any(i -> offsets[i] > offsets[i + 1], 1:(length(offsets) - 1))
        report!(v, "E23", "$(path)/cell_offsets", "is not non-decreasing")
        ok_offsets = false
    end
    if !isempty(offsets) && offsets[end] != length(conn)
        report!(v, "E23", "$(path)/cell_offsets",
                "last value $(offsets[end]) is not the length of " *
                "cell_connectivity, $(length(conn))")
        ok_offsets = false
    end
    if ok_offsets && length(offsets) == length(types) + 1
        for j in 1:length(types)
            want = get(CELL_NODES, Int(types[j]), -1)
            want < 0 && continue
            got = offsets[j + 1] - offsets[j]
            if want == 0
                got >= 3 || report!(v, "E22", "$(path)/cell_offsets",
                    "polygon $(j - 1) has $(got) nodes, fewer than three")
            elseif got != want
                report!(v, "E22", "$(path)/cell_offsets",
                        "cell $(j - 1) has $(got) nodes where its type " *
                        "takes $(want)")
            end
        end
    end
    for x in conn
        (0 <= x < n_nodes) || report!(v, "E24", "$(path)/cell_connectivity",
            "value $(x) is outside [0, $(n_nodes))")
    end
    length(types) == n_cells || report!(v, "E05", "$(path)/cell_types",
        "$(length(types)) cells where the support declares $(n_cells)")
    return (types, offsets, conn)
end

function check_coordinates!(v::Validator, path, g, kind, n_nodes)
    have = hard_child(g, "coordinates")
    if kind in ("mesh", "axis")
        have === nothing && (report!(v, "E03", path,
            "a $(kind) support requires a coordinates array"); return nothing)
    else
        have === nothing || report!(v, "E03", path,
            "a support of kind none has no coordinates")
        return nothing
    end
    d = have
    a = own_attrs(d)
    if kind == "axis"
        vr = haskey(a, "varies") && a["varies"].value isa AbstractString ?
             a["varies"].value : ""
        vr == "none" || report!(v, "E35", "$(path)/coordinates",
            "an axis support's coordinates must have `varies = none`")
    end
    d isa HDF5.Dataset || return nothing
    # Section 24 hashes the stored bytes as they are, so that a file
    # whose axis coordinates wrongly vary breaks E35 and nothing else.
    return guard!(v, "$(path)/coordinates") do
        vec(safe_read(d; max_elements = v.max_elements))
    end
end

function check_support_arrays!(v::Validator, path, g, sname, sindex, kind,
                               n_nodes, n_cells)
    slots = Tuple{String,Symbol,Any}[]
    c = hard_child(g, "coordinates")
    c === nothing || push!(slots, ("$(path)/coordinates", :node, c))
    for (sub, loc) in (("node_arrays", :node), ("cell_arrays", :cell))
        sg = hard_child(g, sub)
        sg isa HDF5.Group || continue
        for n in vchildren!(v, sg, "$(path)/$(sub)")
            obj = vopen!(v, sg, n, "$(path)/$(sub)/$(n)")
            obj === nothing && continue
            push!(slots, ("$(path)/$(sub)/$(n)", loc, obj))
        end
    end
    nweight = Dict(:node => 0, :cell => 0)
    nnormal = Dict(:node => 0, :cell => 0)
    for (spath, loc, obj) in slots
        guard!(v, spath) do
        a = own_attrs(obj)
        check_attr_types!(v, spath, a)
        for n in keys(a)
            n in ARRAY_ATTRS || report!(v, "W11", spath,
                "attribute `$(n)` is not one this reader knows")
        end
        role = haskey(a, "role") && a["role"].value isa AbstractString ?
               a["role"].value : nothing
        if role === nothing
            report!(v, "E02", spath, "no `role` attribute")
            v.missing_public = true
        elseif !(Symbol(role) in ARRAY_ROLES)
            report!(v, "E02", spath, "`$(role)` is not a role of section 3")
            role = nothing
        end
        role == "weight" && (nweight[loc] += 1)
        role == "normal" && (nnormal[loc] += 1)
        check_source!(v, spath, obj, a)
        check_statistic!(v, spath, a)
        haskey(a, "varies") || (report!(v, "E39", spath,
            "`varies` is missing"); v.missing_public = true)
        haskey(a, "components") || (report!(v, "E39", spath,
            "`components` is missing"); v.missing_public = true)
        if role == "field" || role == "derived"
            if !haskey(a, "units")
                rule = role == "field" ? "E11" : "E39"
                report!(v, rule, spath, "a $(role) array requires `units`")
                v.missing_public = true
            end
        elseif role == "coordinates" && !haskey(a, "units")
            report!(v, "E39", spath, "coordinates require `units`")
            v.missing_public = true
        end
        haskey(a, "units") && a["units"].value isa AbstractString &&
            !parse_units(a["units"].value) &&
            report!(v, "W10", spath, "units cannot be parsed")
        if role == "derived" &&
           !(haskey(a, "derived_from") && haskey(a, "recipe"))
            report!(v, "E13", spath,
                    "a derived array needs `derived_from` and `recipe`")
            v.missing_public = true
        end
        if role in ("weight", "normal") && !haskey(a, "recomputed")
            report!(v, "W06", spath,
                    "not marked as recomputed from the connectivity")
        end
        check_label_categories!(v, spath, obj, a, role)
        obj isa HDF5.Dataset || return
        check_array_shape!(v, spath, obj, a, role, loc, sname, sindex,
                           n_nodes, n_cells)
        end
    end
    for loc in (:node, :cell)
        nweight[loc] > 1 && report!(v, "E03", path,
            "$(nweight[loc]) weight arrays on $(loc)s, where the role " *
            "allows at most one")
        nnormal[loc] > 1 && report!(v, "E03", path,
            "$(nnormal[loc]) normal arrays on $(loc)s, where the role " *
            "allows at most one")
    end
    return v
end

function check_label_categories!(v::Validator, spath, obj, a, role)
    role == "label" || return v
    haskey(a, "category") || return v          # its values are its own
    table = a["category"].value
    table isa AbstractString || return v
    if !haskey(v.categories, table)
        report!(v, "E39", spath, "no category table called `$(table)`")
        return v
    end
    obj isa HDF5.Dataset || return v
    n = length(v.categories[table])
    vals = guard!(v, spath) do
        vec(safe_read(obj; max_elements = v.max_elements))
    end
    vals === nothing && return v
    for x in vals
        x isa Integer || continue
        (0 <= x < n) || report!(v, "E10", spath,
            "label value $(x) is outside a table of $(n) entries")
    end
    return v
end

function check_array_shape!(v::Validator, spath, d, a, role, loc, sname,
                            sindex, n_nodes, n_cells)
    cdims, _ = disk_shape(d)
    names = axis_scale_names(d, v.idx)
    ti = type_info(HDF5.datatype(d))
    if role !== nothing && haskey(DTYPE_BY_ROLE, role)
        T = uint8_eltype(ti)
        T in DTYPE_BY_ROLE[role] || report!(v, "E20", spath,
            "a $(role) array may not be stored as $(T)")
    end
    varies = haskey(a, "varies") && a["varies"].value isa AbstractString ?
             a["varies"].value : nothing
    if varies !== nothing && startswith(varies, "group:")
        k = varies[7:end]
        get(v.keyroles, k, nothing) == "group" || report!(v, "E04", spath,
            "`varies = $(varies)` names a group key the file does not " *
            "declare")
    end
    lead = isempty(names) ? nothing : names[1]
    if varies !== nothing && lead !== nothing
        want = varies == "none" ? nothing :
               varies == "row" ? "row" :
               startswith(varies, "group:") ? "group_" * varies[7:end] :
               nothing
        if want === nothing && varies != "none"
            report!(v, "E04", spath, "`varies` is not none, row or group:<k>")
        elseif varies == "none"
            (lead == "row" || startswith(lead, "group_")) &&
                report!(v, "E04", spath,
                    "`varies = none` but the leading dimension is `$(lead)`")
        elseif lead != want
            report!(v, "E04", spath,
                    "`varies = $(varies)` but the leading dimension is " *
                    "`$(lead)`")
        end
    end
    # the component dimension is always last (section 19)
    comp = isempty(cdims) ? 0 : cdims[end]
    if haskey(a, "components") && a["components"].value isa Integer
        if Int(a["components"].value) != comp
            report!(v, "E31", spath,
                    "`components` is $(a["components"].value) over a " *
                    "component dimension of $(comp)")
            v.missing_public = true
        end
    end
    # the node or cell extent, found by the dimension's name
    axis = findfirst(n -> n == (loc === :cell ? "cell" : "node"), names)
    if axis !== nothing
        want = loc === :cell ? n_cells : n_nodes
        cdims[axis] == want || report!(v, "E05", spath,
            "$(cdims[axis]) $(loc)s where the support declares $(want)")
    end
    if lead == "row"
        want = v.aligned ? v.nrows : rows_on_support(v, sindex)
        cdims[1] == want || report!(v, "E16", spath,
            "a leading dimension of $(cdims[1]) where $(want) rows " *
            "reference this slot")
    elseif lead !== nothing && startswith(lead, "group_")
        k = lead[7:end]
        table = get(v.keycat, k, nothing)
        if table !== nothing && haskey(v.categories, table)
            n = length(v.categories[table])
            cdims[1] == n || report!(v, "E34", spath,
                "$(cdims[1]) instances over a group key of $(n) categories")
        end
    end
    if (role == "field" || role == "derived") && ti.class === :float &&
       ti.size == 8
        guard!(v, spath) do
            any(x -> !isfinite(x),
                safe_read(d; max_elements = v.max_elements)) &&
                report!(v, "W03", spath, "a non-finite value")
        end
    end
    return v
end

# -------------------------------------------------------- callables

function check_callables!(v::Validator)
    cg = vroot(v, "callables")
    cg === nothing && return v
    for id in vchildren!(v, cg, "/callables")
        g = vopen!(v, cg, id, "/callables/$(id)")
        g === nothing && continue
        path = "/callables/$(id)"
        g isa HDF5.Group || (report!(v, "E15", path,
            "a callable must be a group"); continue)
        guard!(v, path) do
            a = own_attrs(g)
            check_attr_types!(v, path, a)
            haskey(a, "type") || (report!(v, "E15", path,
                "no `type` attribute"); v.missing_public = true)
            check_dict!(v, path, g, true, 0)
        end
    end
    return v
end

"""E32: what a callable's dictionary may hold (section 25)."""
function check_dict!(v::Validator, path, g, toplevel::Bool, depth::Int)
    if depth >= MAX_DEPTH
        report!(v, "E41", path,
                "a dictionary nested deeper than $(MAX_DEPTH); this " *
                "validator stops there")
        return v
    end
    for name in attr_names(g)
        name in MACHINERY_ATTRS && continue
        reserved(name) && continue
        toplevel && name in ("type", "repr") && continue
        at = read_raw_attr(g, name)
        if !at.readable
            at.ti.vlen ?
                report!(v, "E19", "$(path)@$(name)",
                        "a variable-length string attribute") :
                report!(v, "E41", "$(path)@$(name)",
                        "this attribute could not be read")
            continue
        end
        if at.ti.class === :string
            at.ti.vlen && report!(v, "E19", path,
                "attribute `$(name)` is a variable-length string")
            at.raw == NULL_SENTINEL && continue
            check_string_bytes(at.raw) || report!(v, "E32", path,
                "attribute `$(name)` holds a NUL byte or is not UTF-8")
        elseif at.ti.class === :int
            at.ti.size in (1, 8) || report!(v, "E32", path,
                "attribute `$(name)` is neither int8 nor int64")
        elseif at.ti.class === :float
            at.ti.size == 8 || report!(v, "E32", path,
                "attribute `$(name)` is not float64")
        end
    end
    for name in vchildren!(v, g, path)
        reserved(name) && continue
        obj = hard_child(g, name)
        obj === nothing && continue
        p = "$(path)/$(name)"
        if obj isa HDF5.Group
            toplevel && name in ("type", "repr") && report!(v, "E32", p,
                "a dictionary may not have a top-level `$(name)`")
            check_dict!(v, p, obj, false, depth + 1)
            continue
        end
        is_scale(obj) && continue
        guard!(v, p) do
        cdims, _ = disk_shape(obj)
        if isempty(cdims)
            report!(v, "E32", p,
                    "a zero-dimensional dataset; section 25 says to write " *
                    "it as an attribute")
            return
        end
        ti = type_info(HDF5.datatype(obj))
        if ti.class === :string
            ti.vlen && report!(v, "E32", p, "a variable-length string")
            _, recs = read_string_records(obj;
                                          max_elements = v.max_elements)
            for r in recs
                check_string_bytes(r) || report!(v, "E32", p,
                    "a string that is not UTF-8 or holds a NUL byte")
            end
            longest = maximum(vcat([length(strip_nul(r)) for r in recs], [1]))
            ti.size > longest && report!(v, "W13", p,
                "stored in $(ti.size) bytes where $(longest) would do")
        else
            T = uint8_eltype(ti)
            T in (Int8, Int32, Int64, Float64) || report!(v, "E32", p,
                "a dtype the codec does not allow: $(T)")
        end
        end
    end
    return v
end

# --------------------------------------- every dataset, byte-level

function check_every_dataset!(v::Validator)
    walk_objects(v.f) do path, obj
        obj isa HDF5.Dataset || return
        is_scale(obj) && return
        guard!(v, path) do
        cdims, _ = disk_shape(obj)
        layout, chunk, filters = dataset_layout(obj)
        for (fid, cd) in filters
            if fid == 1
                lvl = isempty(cd) ? 0 : cd[1]
                (1 <= lvl <= 9) || report!(v, "E29", path,
                    "gzip at level $(lvl)")
            elseif fid != 2
                report!(v, "E29", path,
                        "filter $(fid) is neither gzip nor shuffle")
            end
        end
        names = axis_scale_names(obj, v.idx)
        for (axis, n) in pairs(names)
            k = num_scales(obj, axis - 1)
            if k < 0
                report!(v, "E41", path,
                        "axis $(axis - 1): the library would not say how " *
                        "many dimension scales are attached")
            elseif k == 0
                report!(v, "E25", path,
                        "axis $(axis - 1) carries no dimension scale")
            elseif k > 1
                report!(v, "E25", path,
                        "axis $(axis - 1) carries $(k) dimension scales")
            elseif n !== nothing && !known_dim_name(n)
                report!(v, "E25", path,
                        "axis $(axis - 1) carries a scale called `$(n)`, " *
                        "which section 21 does not name")
            elseif n !== nothing
                # Section 21 gives a scale both CLASS and NAME.  One
                # with only CLASS is half a scale, and the axis it is
                # attached to does not carry the thing the rule asks
                # for.
                got = attached_scale(obj, axis - 1, v.idx.all)
                if got !== nothing && !haskey(HDF5.attributes(got[2]), "NAME")
                    report!(v, "E25", path,
                            "axis $(axis - 1) carries a scale `$(n)` with " *
                            "CLASS and no NAME, which is half of what " *
                            "makes a dimension scale (section 21)")
                end
            end
        end
        if !isempty(names) && names[1] == "row"
            if layout !== :chunked
                report!(v, "E27", path,
                        "a row-dimensioned dataset must be chunked")
            elseif chunk !== nothing
                want = default_chunk_for(v, obj, cdims)
                want === nothing || chunk == want ||
                    report!(v, "W12", path,
                        "chunk $(Tuple(chunk)) is not the default " *
                        "$(Tuple(want)) of section 23")
            end
        end
        ti = type_info(HDF5.datatype(obj))
        if ti.class === :string && !ti.vlen &&
           !startswith(path, "/categories/") && !startswith(path, "/callables/")
            _, recs = read_string_records(obj;
                                          max_elements = v.max_elements)
            for r in recs
                check_string_bytes(r) || report!(v, "E26", path,
                    "a string that is not UTF-8 or holds a NUL byte " *
                    "before its trailing padding")
            end
            longest = maximum(vcat([length(strip_nul(r)) for r in recs], [1]))
            ti.size > longest && report!(v, "W13", path,
                "stored in $(ti.size) bytes where $(longest) would do")
        end
        ti.class === :float && ti.size == 4 && report!(v, "E20", path,
            "float32 is not allowed anywhere")
        ti.vlen && report!(v, "E19", path,
            "a variable-length type is never legal")
        end
    end
    return v
end

function known_dim_name(n::AbstractString)
    n in ("row", "node", "cell", "cell_plus_one", "index") && return true
    startswith(n, "component_") && return true
    startswith(n, "draw_") && return true
    startswith(n, "group_") && return true
    startswith(n, "category_") && return true
    startswith(n, "mestra_") && return true
    return false
end

function default_chunk_for(v::Validator, d::HDF5.Dataset, cdims::Vector{Int})
    ti = type_info(HDF5.datatype(d))
    nrows = 0
    sc = attached_scale_name(d, 0, v.idx.all)
    sc === nothing && return nothing
    for (name, s) in v.idx.all
        attached = try
            HDF5.API.h5ds_is_attached(d, s, 0)
        catch
            false
        end
        if attached
            sdims, _ = disk_shape(s)
            nrows = isempty(sdims) ? 0 : sdims[1]
            break
        end
    end
    rest = cdims[2:end]
    return vcat(default_chunk_rows(ti.size, rest, nrows), rest)
end

# ------------------------------------------------- unknown, private

function check_unknown!(v::Validator)
    a = own_attrs(v.f)
    for name in keys(a)
        name in ROOT_ATTRS || report!(v, "W11", "/",
            "root attribute `$(name)` is not one this reader knows")
    end
    for name in vchildren!(v, v.f, "")
        obj = hard_child(v.f, name)
        obj === nothing && continue
        if obj isa HDF5.Group
            name in ROOT_GROUPS || report!(v, "W11", "/$(name)",
                "a root group this reader does not know")
        elseif !is_scale(obj)
            name == "row_support" || report!(v, "W11", "/$(name)",
                "a root dataset this reader does not know")
        end
    end
    return v
end

"""E18: public information present only under /private.  Section 29
forbids a validator to interpret /private, so this is decided from the
public objects it can see are missing and from nothing else."""
function check_private!(v::Validator)
    hard_child(v.f, "private") === nothing && return v
    v.missing_public || return v
    report!(v, "E18", "/private",
            "a required public attribute is missing while the file " *
            "carries a /private group; public information may not live " *
            "only there")
    return v
end
