# Validating: a mistake refused while building, and a warning that is
# reported but does not stop a file. See README.md for the output.
using Mestra

cl = [0.21, 0.25, 0.30, 0.36, 0.41, 0.48]
ds = Mestra.Dataset(writer = "mestra examples 1")
Mestra.add_key!(ds, "mach", [0.4, 0.8, 0.4, 0.8, 0.4, 0.8];
                role = :condition, units = "1")
Mestra.add_category_table!(ds, "member", ["wing_a", "wing_b", "wing_c"])
Mestra.add_key!(ds, "member", [0, 0, 1, 1, 2, 2]; role = :group,
                category = "member")
Mestra.set_generalisation_group!(ds, "member")
try
    Mestra.add_scalar!(ds, "cl", cl)
catch refusal
    refusal isa MestraError || rethrow()
    println("refused: ", sprint(showerror, refusal))
end
Mestra.add_scalar!(ds, "cl", cl; units = "1")
Mestra.add_category_table!(ds, "split", ["train", "test"])
Mestra.add_key!(ds, "split", [0, 0, 0, 1, 1, 1]; role = :split,
                category = "split")
Mestra.write(ds, "family.mes")

report = Mestra.validate("family.mes")
println("ok: ", isvalid(report))
println("errors: ", report.errors, " warnings: ", report.warnings)
for finding in report.findings
    println(finding)
end
