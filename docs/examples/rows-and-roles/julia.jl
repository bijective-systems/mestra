# Rows and roles: six rows of a three-member family, no support.
# See README.md in this directory for the data and the output.
using Mestra

ds = Mestra.Dataset(writer = "mestra examples 1")
Mestra.add_key!(ds, "mach", [0.4, 0.8, 0.4, 0.8, 0.4, 0.8];
                role = :condition, units = "1")
Mestra.add_category_table!(ds, "member", ["wing_a", "wing_b", "wing_c"])
Mestra.add_key!(ds, "member", [0, 0, 1, 1, 2, 2]; role = :group,
                category = "member")
Mestra.set_generalisation_group!(ds, "member")
Mestra.add_scalar!(ds, "cl", [0.21, 0.25, 0.30, 0.36, 0.41, 0.48];
                   units = "1")
Mestra.write(ds, "family.mes")

d = Mestra.read("family.mes")
println(d.nrows, " rows, ", length(Mestra.key_order(d)), " keys")
for name in Mestra.key_order(d)
    key = d.keys[name]
    println(name, " ", key.role, " ",
            key.units === nothing ? key.category : key.units)
end
println("generalisation unit: ", d.generalisation_group)
# The corpus counts rows from zero and Julia counts from one, so the
# README's row 3 is this one.
println("cl at row 3: ",
        Mestra.at(Mestra.values(d, d.scalars["cl"]); row = 4))
println("cl units: ", d.scalars["cl"].units)
