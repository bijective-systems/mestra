# Groups and splits: whole members move together, never single rows.
# See README.md in this directory for the data and the output.
import mestra
from mestra import post

ds = mestra.Dataset(writer="mestra examples 1")
ds.add_key("mach", [0.4, 0.8, 0.4, 0.8, 0.4, 0.8],
           role="condition", units="1")
ds.add_category_table("member", ["wing_a", "wing_b", "wing_c"])
ds.add_key("member", [0, 0, 1, 1, 2, 2],
           role="group", category="member")
ds.set_generalisation_group("member")
ds.add_scalar("cl", [0.21, 0.25, 0.30, 0.36, 0.41, 0.48], units="1")
ds.add_category_table("split", ["train", "test"])
ds.add_key("split", [0, 0, 0, 1, 1, 1], role="split", category="split")
mestra.write(ds, "family.mes")

with mestra.read("family.mes") as d:
    member = d.keys["member"].values
    names = d.categories["member"]
    print("unit of generalisation:", d.generalisation_group)
    print("the split in the file leaks:", sorted(post.split_leaks(d)))
    parts = post.grouped_split(d, {"train": 0.67, "test": 0.33}, seed=0)
    for part in ("train", "test"):
        rows = [int(r) for r in parts[part]]
        print(part, "rows", rows, "members",
              sorted({names[int(member[r])] for r in rows}))
