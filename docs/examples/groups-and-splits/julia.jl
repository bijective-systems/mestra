# Groups and splits: whole members move together, never single rows.
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
Mestra.add_category_table!(ds, "split", ["train", "test"])
Mestra.add_key!(ds, "split", [0, 0, 0, 1, 1, 1]; role = :split,
                category = "split")
Mestra.write(ds, "family.mes")

d = Mestra.read("family.mes")
member = Mestra.values(d, d.keys["member"])
names = d.categories["member"].entries
println("unit of generalisation: ", d.generalisation_group)
println("the split in the file leaks: ",
        sort(String.(collect(keys(Mestra.split_leaks(d))))))
parts = Mestra.grouped_split(d, ["train" => 0.67, "test" => 0.33]; seed = 0)
for part in ("train", "test")
    rows = parts[part]
    # The rows come back one based; the file numbers them from zero.
    println(part, " rows ", rows .- 1, " members ",
            sort(unique([names[member[r] + 1] for r in rows])))
end
