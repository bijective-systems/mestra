# The post-processing helpers of julia/README.md, spelled as the README
# spells them.  Run: julia --project=julia post_checks.jl DIR

using Mestra

const D = length(ARGS) >= 1 ? ARGS[1] : "."

function attempt(label, f)
    print("--- ", label, "\n    ")
    try
        println(f())
    catch err
        println(typeof(err), ": ", sprint(showerror, err))
    end
end

ds1 = Mestra.read(joinpath(D, "d1_family.mes"))
ds2 = Mestra.read(joinpath(D, "d2_cascade.mes"))
ds3 = Mestra.read(joinpath(D, "d3_scalars.mes"))
ds4 = Mestra.read(joinpath(D, "d4_transient.mes"))
ds5 = Mestra.read(joinpath(D, "d5_axis.mes"))

attempt("field_statistics(ds1, ds1[\"pressure\"])",
        () -> Mestra.field_statistics(ds1, ds1["pressure"]))
attempt("field_statistics(ds1, ds1[\"pressure\"], by = \"cad_face_id\")",
        () -> Mestra.field_statistics(ds1, ds1["pressure"],
                                      by = "cad_face_id"))
# the README's own line, with the weight it names
attempt("integrate(ds1, ds1[\"pressure\"]; weight = \"measure\")",
        () -> Mestra.integrate(ds1, ds1["pressure"]; weight = "measure"))
attempt("integrate(ds1, ds1[\"pressure\"])",
        () -> Mestra.integrate(ds1, ds1["pressure"]))
attempt("time_series(ds4, ds4[\"u\"]; node = 3, trajectory = \"r001\")",
        () -> Mestra.time_series(ds4, ds4["u"]; node = 3,
                                 trajectory = "r001"))
attempt("grouped_split(ds3; fractions = [\"train\" => .8, \"test\" => .2])",
        () -> Mestra.grouped_split(ds3;
                  fractions = ["train" => 0.8, "test" => 0.2]))
attempt("split_leaks(ds2)", () -> Mestra.split_leaks(ds2))
attempt("field_statistics(ds5, ds5[\"overpressure\"])",
        () -> Mestra.field_statistics(ds5, ds5["overpressure"]))
attempt("field_statistics(ds3, ds3[\"CL\"])  # a scalar",
        () -> Mestra.field_statistics(ds3, ds3["CL"]))
