# Validating: a mistake refused while building, and a warning that is
# reported but does not stop a file. See README.md for the output.
import mestra

ds = mestra.Dataset(writer="mestra examples 1")
ds.add_key("mach", [0.4, 0.8, 0.4, 0.8, 0.4, 0.8],
           role="condition", units="1")
ds.add_category_table("member", ["wing_a", "wing_b", "wing_c"])
ds.add_key("member", [0, 0, 1, 1, 2, 2],
           role="group", category="member")
ds.set_generalisation_group("member")
try:
    ds.add_scalar("cl", [0.21, 0.25, 0.30, 0.36, 0.41, 0.48])
except mestra.MestraError as refusal:
    print("refused:", refusal)
ds.add_scalar("cl", [0.21, 0.25, 0.30, 0.36, 0.41, 0.48], units="1")
ds.add_category_table("split", ["train", "test"])
ds.add_key("split", [0, 0, 0, 1, 1, 1], role="split", category="split")
mestra.write(ds, "family.mes")

report = mestra.validate("family.mes")
print("ok:", report.ok)
print("errors:", report.error_ids, "warnings:", report.warning_ids)
for finding in report.findings:
    print(finding)
