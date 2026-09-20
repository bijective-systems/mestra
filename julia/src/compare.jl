# Structural equality, the normative comparison of section 30.
#
# Byte identity across HDF5 versions is not required and must not be
# tested, because the library decides the superblock and the object
# header layout.  What two files that should be the same must share is
# below, and nothing else.

"""
    structural_diff(a, b) -> Vector{String}

Every way in which two files differ under the rule of section 30: the
same set of object paths; at each path the same kind; for a dataset
the same dtype including byte order, character set and padding, the
same shape, maximum shape, chunk shape and filters, and equal contents
compared as bytes so that NaN equals NaN; at each path the same
attributes excluding the machinery names of section 18; and the same
dimension scale attached to each axis, compared by the scale's name.

An empty result means the two files are structurally equal.
"""
function structural_diff(a::AbstractString, b::AbstractString)
    out = String[]
    HDF5.h5open(String(a), "r") do fa
        HDF5.h5open(String(b), "r") do fb
            ia = ScaleIndex(fa)
            ib = ScaleIndex(fb)
            pa = object_paths(fa)
            pb = object_paths(fb)
            for p in setdiff(keys(pa), keys(pb))
                push!(out, "only in $(a): $(p)")
            end
            for p in setdiff(keys(pb), keys(pa))
                push!(out, "only in $(b): $(p)")
            end
            for p in sort(collect(intersect(keys(pa), keys(pb))))
                pa[p] == pb[p] ||
                    (push!(out, "$(p): $(pa[p]) here, $(pb[p]) there");
                     continue)
                oa = p == "/" ? fa : fa[p]
                ob = p == "/" ? fb : fb[p]
                compare_attrs!(out, p, oa, ob)
                oa isa HDF5.Dataset || continue
                compare_dataset!(out, p, oa, ob, ia, ib)
            end
        end
    end
    return out
end

"""
    structurally_equal(a, b) -> Bool

True when `structural_diff` finds nothing, which is what section 30
means by two files being the same.
"""
structurally_equal(a, b) = isempty(structural_diff(a, b))

function object_paths(f::HDF5.File)
    out = Dict{String,Symbol}("/" => :group)
    walk_objects(f) do path, obj
        out[path] = obj isa HDF5.Group ? :group : :dataset
    end
    return out
end

function compare_attrs!(out, path, oa, ob)
    na = sort([n for n in keys(HDF5.attributes(oa))
               if !(n in MACHINERY_ATTRS)])
    nb = sort([n for n in keys(HDF5.attributes(ob))
               if !(n in MACHINERY_ATTRS)])
    na == nb || (push!(out, "$(path): attributes $(na) against $(nb)");
                 return)
    for n in na
        aa = read_raw_attr(oa, n)
        ab = read_raw_attr(ob, n)
        aa.ti == ab.ti ||
            push!(out, "$(path)@$(n): dtype $(aa.ti) against $(ab.ti)")
        aa.raw == ab.raw ||
            push!(out, "$(path)@$(n): value $(aa.value) against $(ab.value)")
    end
    return out
end

function compare_dataset!(out, path, da, db, ia, ib)
    ta = type_info(HDF5.datatype(da))
    tb = type_info(HDF5.datatype(db))
    ta == tb || push!(out, "$(path): dtype $(ta) against $(tb)")
    sa, ma = disk_shape(da)
    sb, mb = disk_shape(db)
    sa == sb || push!(out, "$(path): shape $(sa) against $(sb)")
    ma == mb || push!(out, "$(path): max shape $(ma) against $(mb)")
    la, ca, fa_ = dataset_layout(da)
    lb, cb, fb_ = dataset_layout(db)
    ca == cb || push!(out, "$(path): chunk $(ca) against $(cb)")
    la == lb || push!(out, "$(path): layout $(la) against $(lb)")
    sort(fa_) == sort(fb_) ||
        push!(out, "$(path): filters $(fa_) against $(fb_)")
    if !is_scale(da) && sa == sb
        _, ra, _ = read_raw_dataset(da)
        _, rb, _ = read_raw_dataset(db)
        ra == rb || push!(out, "$(path): contents differ")
    end
    axa = axis_scales(da, ia)
    axb = axis_scales(db, ib)
    for axis in 0:(length(sa) - 1)
        nsa = axis + 1 <= length(axa) ? axa[axis + 1][1] : 0
        nsb = axis + 1 <= length(axb) ? axb[axis + 1][1] : 0
        if nsa != nsb
            push!(out, "$(path): axis $(axis) has $(nsa) scales against " *
                       "$(nsb)")
            continue
        end
        nsa == 1 || continue
        va = axa[axis + 1][2]
        vb = axb[axis + 1][2]
        va == vb || push!(out, "$(path): axis $(axis) scale $(va) against " *
                               "$(vb)")
    end
    return out
end
