# The five datasets of docs/mappings.md, built from julia/README.md
# alone.  Run:  julia --project=julia build_all.jl OUTDIR

using Mestra
using Random

const OUT = length(ARGS) >= 1 ? ARGS[1] : "."

function report(path)
    r = Mestra.validate(path)
    println("  validate: errors=", r.errors, " warnings=", r.warnings)
    for f in r.findings
        println("      ", f.rule, " ", f.path, " ", f.message)
    end
end

# ---------------------------------------------------------------- 1 ---
function d1_family(path)
    ds = Mestra.Dataset(writer = "ergonomics review 1")
    Mestra.add_category_table!(ds, "member", ["cone_a", "cone_b", "cone_c"])
    Mestra.add_category_table!(ds, "status", ["converged", "failed"])

    Mestra.add_key!(ds, "total_length", [2.0, 2, 3, 3, 4, 4];
                    role = :design, units = "m")
    Mestra.add_key!(ds, "half_angle", [10.0, 10, 15, 15, 20, 20];
                    role = :design, units = "degree")
    Mestra.add_key!(ds, "nose_radius", [.05, .05, .08, .08, .11, .11];
                    role = :design, units = "m")
    Mestra.add_key!(ds, "mach", [.5, .8, .5, .8, .5, .8];
                    role = :condition, units = "1")
    Mestra.add_key!(ds, "altitude", [1000.0, 1000, 5000, 5000, 9000, 9000];
                    role = :condition, units = "m")
    Mestra.add_key!(ds, "member", [0, 0, 1, 1, 2, 2];
                    role = :group, category = "member")
    Mestra.add_key!(ds, "status", [0, 0, 0, 0, 0, 1];
                    role = :status, category = "status")
    # julia/README.md never says how to name the unit of generalisation.
    ds.generalisation_group = "member"

    base = [0.0 0.0 0.0; 1.0 0.0 0.0; 2.0 0.0 0.0;
            0.0 1.0 0.0; 1.0 1.0 0.0; 2.0 1.0 0.0]
    coords = zeros(3, 6, 3)                      # instance, node, component
    for (i, s) in enumerate((1.0, 1.5, 2.0))
        coords[i, :, :] = base .* [s 1.0 1.0]
    end

    s = Mestra.add_mesh_support!(ds, "s0";
            coordinates = coords,
            dims = (Symbol("group:member"), :node, :component),
            units = "m",
            cell_types = UInt8[9, 9],
            cell_offsets = Int64[0, 4, 8],
            cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])

    Random.seed!(0)
    Mestra.add_node_array!(ds, s, "pressure", 1000 .+ rand(6, 6) .* 10;
                           units = "Pa", dims = (:row, :node))
    Mestra.add_node_array!(ds, s, "heat_flux", 500 .+ rand(6, 6) .* 10;
                           units = "W/m^2", dims = (:row, :node))
    Mestra.add_node_array!(ds, s, "cad_edge_t", collect(range(0, 1, 6));
                           units = "1", dims = (:node,))
    Mestra.add_node_array!(ds, s, "cad_face_id", Int32[11, 11, 12, 12, 13, 13];
                           role = :label, dims = (:node,))
    Mestra.add_cell_array!(ds, s, "topo_face_id", Int32[1, 2];
                           role = :label, dims = (:cell,))

    Mestra.write(ds, path); println("wrote ", path); report(path)
end

# ---------------------------------------------------------------- 2 ---
function d2_cascade(path)
    n_rows, n_nodes = 8, 6
    ds = Mestra.Dataset(writer = "ergonomics review 2")
    Mestra.add_category_table!(ds, "split", ["train", "validation", "test"])
    Mestra.add_category_table!(ds, "status", ["converged", "partial"])
    Mestra.add_category_table!(ds, "case",
                               ["c0$(i)" for i in 0:n_rows-1])

    Mestra.add_key!(ds, "angle_in", collect(30.0:2:44);
                    role = :condition, units = "degree")
    Mestra.add_key!(ds, "mach_out", collect(0.70:0.05:1.05);
                    role = :condition, units = "1")
    Mestra.add_key!(ds, "split", [0, 0, 0, 0, 1, 1, 2, 2];
                    role = :split, category = "split")
    Mestra.add_key!(ds, "case", collect(0:n_rows-1);
                    role = :group, category = "case")
    Mestra.add_key!(ds, "status", [0, 0, 0, 0, 0, 0, 1, 1];
                    role = :status, category = "status")
    ds.generalisation_group = "case"

    Mestra.add_scalar!(ds, "power",
                       [100.0, 110, 120, 130, 140, 150, NaN, NaN];
                       units = "W")
    Mestra.add_scalar!(ds, "angle_out",
                       [-60.0, -61, -62, -63, -64, -65, NaN, NaN];
                       units = "degree")

    Random.seed!(1)
    base = [0.0 0.0; 1.0 0.0; 2.0 0.0; 0.0 1.0; 1.0 1.0; 2.0 1.0]
    coords = zeros(n_rows, n_nodes, 2)
    for i in 1:n_rows
        coords[i, :, :] = base .+ randn(n_nodes, 2) .* 0.02
    end
    s = Mestra.add_mesh_support!(ds, "s0";
            coordinates = coords, dims = (:row, :node, :component),
            units = "m",
            cell_types = UInt8[9, 9], cell_offsets = Int64[0, 4, 8],
            cell_connectivity = Int64[0, 1, 4, 3, 1, 2, 5, 4])

    Mestra.add_node_array!(ds, s, "mach", 0.5 .+ rand(n_rows, n_nodes);
                           units = "1", dims = (:row, :node))
    Mestra.add_node_array!(ds, s, "nut", 1e-5 .* rand(n_rows, n_nodes);
                           units = "m^2/s", dims = (:row, :node))

    Mestra.write(ds, path); println("wrote ", path); report(path)
end

# ---------------------------------------------------------------- 3 ---
function d3_scalars(path)
    geom = repeat([0, 1, 2], inner = 4)
    inc = repeat([0.0, 4, 8, 12], outer = 3)
    ds = Mestra.Dataset(writer = "ergonomics review 3")
    Mestra.add_category_table!(ds, "geometry", ["g0", "g1", "g2"])
    Mestra.add_key!(ds, "camber", 0.02 .+ 0.01 .* geom;
                    role = :design, units = "1")
    Mestra.add_key!(ds, "thickness", 0.10 .+ 0.02 .* geom;
                    role = :design, units = "1")
    Mestra.add_key!(ds, "incidence", inc; role = :condition, units = "degree")
    Mestra.add_key!(ds, "geometry", geom; role = :group, category = "geometry")
    ds.generalisation_group = "geometry"

    Random.seed!(3)
    Mestra.add_scalar!(ds, "CL", 0.1 .* inc .+ rand(12) .* 0.01; units = "1")
    Mestra.add_scalar!(ds, "CD", 0.01 .+ 0.0005 .* inc .^ 2; units = "1")
    Mestra.add_scalar!(ds, "CM", -0.05 .- 0.001 .* inc; units = "1")

    Mestra.write(ds, path); println("wrote ", path); report(path)
end

# ---------------------------------------------------------------- 4 ---
function d4_transient(path)
    steps = [4, 3, 5]
    diffusivity = [0.10, 0.25, 0.40]
    amplitude = [1.0, 2.0, 3.0]
    run_of_row = Int[]; t_of_row = Float64[]
    diff_of_row = Float64[]; amp_of_row = Float64[]
    for (ri, n) in enumerate(steps), s in 1:n
        push!(run_of_row, ri - 1); push!(t_of_row, 0.1 * s)
        push!(diff_of_row, diffusivity[ri]); push!(amp_of_row, amplitude[ri])
    end
    n_rows = length(run_of_row); n_nodes = 5
    x = collect(range(0.0, 1.0, n_nodes))
    u = [amp_of_row[r] * exp(-diff_of_row[r] * t_of_row[r]) * sin(pi * xi)
         for r in 1:n_rows, xi in x]

    ds = Mestra.Dataset(writer = "ergonomics review 4")
    Mestra.add_category_table!(ds, "run", ["r000", "r001", "r002"])
    Mestra.add_key!(ds, "diffusivity", diff_of_row;
                    role = :design, units = "m^2/s")
    Mestra.add_key!(ds, "amplitude", amp_of_row; role = :design, units = "K")
    Mestra.add_key!(ds, "t", t_of_row; role = :time, units = "s",
                    trajectory_group = "run")
    Mestra.add_key!(ds, "run", run_of_row; role = :group, category = "run")
    ds.generalisation_group = "run"

    s = Mestra.add_mesh_support!(ds, "s0";
            coordinates = reshape(x, n_nodes, 1), dims = (:node, :component),
            units = "m",
            cell_types = UInt8[3, 3, 3, 3],
            cell_offsets = Int64[0, 2, 4, 6, 8],
            cell_connectivity = Int64[0, 1, 1, 2, 2, 3, 3, 4])
    Mestra.add_node_array!(ds, s, "u", u; units = "K", dims = (:row, :node))

    Mestra.write(ds, path); println("wrote ", path); report(path)
end

# ---------------------------------------------------------------- 5 ---
function d5_axis(path)
    n_rows, n_samples = 6, 8
    ground_time = collect(range(0.0, 0.35, n_samples))
    Random.seed!(5)
    amps = [50.0, 55, 60, 65, 70, 75]
    overpressure = [amps[i] * sin(2pi * ground_time[j] / 0.35) +
                    randn() * 0.5 for i in 1:n_rows, j in 1:n_samples]

    ds = Mestra.Dataset(writer = "ergonomics review 5")
    Mestra.add_category_table!(ds, "design", ["d0", "d1", "d2"])
    Mestra.add_key!(ds, "area_1", [.10, .10, .15, .15, .20, .20];
                    role = :design, units = "m^2")
    Mestra.add_key!(ds, "area_2", [.30, .30, .35, .35, .40, .40];
                    role = :design, units = "m^2")
    Mestra.add_key!(ds, "mach", [1.4, 1.6, 1.4, 1.6, 1.4, 1.6];
                    role = :condition, units = "1")
    Mestra.add_key!(ds, "altitude",
                    [12000.0, 12000, 14000, 14000, 16000, 16000];
                    role = :condition, units = "m")
    Mestra.add_key!(ds, "design", [0, 0, 1, 1, 2, 2];
                    role = :group, category = "design")
    ds.generalisation_group = "design"
    Mestra.add_scalar!(ds, "loudness", [78.0, 80, 82, 84, 86, 88];
                       units = "dB")

    s = Mestra.add_axis_support!(ds, "s0";
            coordinates = ground_time, units = "s")
    Mestra.add_node_array!(ds, s, "overpressure", overpressure;
                           units = "Pa", dims = (:row, :node))

    Mestra.write(ds, path); println("wrote ", path); report(path)
end

for (name, fn) in [("d1_family", d1_family), ("d2_cascade", d2_cascade),
                   ("d3_scalars", d3_scalars), ("d4_transient", d4_transient),
                   ("d5_axis", d5_axis)]
    println("########## ", name, " ##########")
    try
        fn(joinpath(OUT, name * ".mes"))
    catch err
        println("  FAILED: ", sprint(showerror, err))
    end
end
