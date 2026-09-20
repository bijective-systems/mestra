# Rows and roles: six rows of a three-member family, no support.
# See README.md in this directory for the data and the output.
import mestra

ds = mestra.Dataset(writer="mestra examples 1")
ds.add_key("mach", [0.4, 0.8, 0.4, 0.8, 0.4, 0.8],
           role="condition", units="1")
ds.add_category_table("member", ["wing_a", "wing_b", "wing_c"])
ds.add_key("member", [0, 0, 1, 1, 2, 2],
           role="group", category="member")
ds.set_generalisation_group("member")
ds.add_scalar("cl", [0.21, 0.25, 0.30, 0.36, 0.41, 0.48], units="1")
mestra.write(ds, "family.mes")

with mestra.read("family.mes") as d:
    print(d.n_rows, "rows,", len(d.key_names()), "keys")
    for name in d.key_names():
        key = d.keys[name]
        print(name, key.role, key.units or key.category)
    print("generalisation unit:", d.generalisation_group)
    print("cl at row 3:", d.scalars["cl"].values.at(row=3))
    print("cl units:", d.scalars["cl"].units)
