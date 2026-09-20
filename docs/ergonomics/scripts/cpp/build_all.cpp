// The five datasets of docs/mappings.md, built from cpp/README.md.
//
// Attempt 1 of this file used only what cpp/README.md shows.  Every
// line marked "header only" is something the README does not mention
// at all and that had to be found by reading
// cpp/include/mestra/mestra.hpp.
//
// Build (see docs/ergonomics/scripts/cpp/build.sh) and run:
//     build_all OUTDIR

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "mestra/mestra.hpp"

namespace {

void report(const std::string& path) {
    const mestra::Report r = mestra::validate(path);
    std::printf("  validate: %zu error(s), %zu warning(s)\n",
                r.errors.size(), r.warnings.size());
    for (const mestra::Finding& f : r.errors)
        std::printf("      E %s %s: %s\n", f.id.c_str(), f.where.c_str(),
                    f.message.c_str());
    for (const mestra::Finding& f : r.warnings)
        std::printf("      W %s %s: %s\n", f.id.c_str(), f.where.c_str(),
                    f.message.c_str());
}

double frand(unsigned& s) {
    s = s * 1103515245u + 12345u;
    return static_cast<double>((s >> 16) & 0x7fffu) / 32768.0;
}

// ------------------------------------------------------------- 1 ---
void d1_family(const std::string& path) {
    mestra::Dataset d;
    d.writer = "ergonomics review 1";
    d.created = "2026-09-20T00:00:00Z";
    d.generalisation_group = "member";

    d.add_categories("member", {"cone_a", "cone_b", "cone_c"});
    d.add_categories("status", {"converged", "failed"});

    d.add_key("total_length", "design", {2, 2, 3, 3, 4, 4}, "m");
    d.add_key("half_angle", "design", {10, 10, 15, 15, 20, 20}, "degree");
    d.add_key("nose_radius", "design",
              {.05, .05, .08, .08, .11, .11}, "m");
    d.add_key("mach", "condition", {.5, .8, .5, .8, .5, .8}, "1");
    d.add_key("altitude", "condition",
              {1000, 1000, 5000, 5000, 9000, 9000}, "m");
    d.add_category_key("member", "group", {0, 0, 1, 1, 2, 2}, "member");
    d.add_category_key("status", "status", {0, 0, 0, 0, 0, 1}, "status");

    const double base[6][3] = {{0, 0, 0}, {1, 0, 0}, {2, 0, 0},
                               {0, 1, 0}, {1, 1, 0}, {2, 1, 0}};
    const double scale[3] = {1.0, 1.5, 2.0};
    std::vector<double> coords;               // instance, node, component
    for (int i = 0; i < 3; ++i)
        for (int n = 0; n < 6; ++n) {
            coords.push_back(base[n][0] * scale[i]);
            coords.push_back(base[n][1]);
            coords.push_back(base[n][2]);
        }

    mestra::Support& s = d.add_mesh_support(
        "s0", 6, {9, 9}, {0, 4, 8}, {0, 1, 4, 3, 1, 2, 5, 4});
    mestra::set_coordinates(s, coords, 3, "m", "group:member");

    unsigned seed = 7;
    std::vector<double> pressure, heat_flux;
    for (int i = 0; i < 36; ++i) pressure.push_back(1000 + frand(seed) * 10);
    for (int i = 0; i < 36; ++i) heat_flux.push_back(500 + frand(seed) * 10);
    mestra::add_field(s, mestra::Location::Node, "pressure", "Pa", pressure);
    mestra::add_field(s, mestra::Location::Node, "heat_flux", "W/m^2",
                      heat_flux);

    // attempt 2.  Attempt 1 set `et.varies = "none"` on the ArraySlot
    // that add_field returns, because the README's add_field takes no
    // varies.  write() IGNORED IT and produced a file the validator
    // rejects with E04, E16 and E27.  add_field really has two further
    // defaulted parameters, components and varies, that the README does
    // not mention.
    std::vector<double> edge_t;
    for (int i = 0; i < 6; ++i) edge_t.push_back(i / 5.0);
    mestra::add_field(s, mestra::Location::Node, "cad_edge_t", "1",
                      edge_t, 1, "none");

    // header only: the README never shows how to add a label at all.
    // add_label does default varies to "none", unlike add_field.
    mestra::add_label(s, mestra::Location::Node, "cad_face_id",
                      std::vector<int64_t>{11, 11, 12, 12, 13, 13});
    mestra::add_label(s, mestra::Location::Cell, "topo_face_id",
                      std::vector<int64_t>{1, 2});

    mestra::write(d, path);
    std::printf("wrote %s\n", path.c_str());
    report(path);
}

// ------------------------------------------------------------- 2 ---
void d2_cascade(const std::string& path) {
    const int n_rows = 8, n_nodes = 6;
    mestra::Dataset d;
    d.writer = "ergonomics review 2";
    d.created = "2026-09-20T00:00:00Z";
    d.generalisation_group = "case";

    std::vector<std::string> cases;
    for (int i = 0; i < n_rows; ++i) cases.push_back("c0" + std::to_string(i));
    d.add_categories("case", cases);
    d.add_categories("split", {"train", "validation", "test"});
    d.add_categories("status", {"converged", "partial"});

    d.add_key("angle_in", "condition",
              {30, 32, 34, 36, 38, 40, 42, 44}, "degree");
    d.add_key("mach_out", "condition",
              {.70, .75, .80, .85, .90, .95, 1.00, 1.05}, "1");
    d.add_category_key("split", "split", {0, 0, 0, 0, 1, 1, 2, 2}, "split");
    d.add_category_key("case", "group", {0, 1, 2, 3, 4, 5, 6, 7}, "case");
    d.add_category_key("status", "status", {0, 0, 0, 0, 0, 0, 1, 1},
                       "status");

    const double nan_ = std::nan("");
    d.add_scalar("power", "W", {100, 110, 120, 130, 140, 150, nan_, nan_});
    d.add_scalar("angle_out", "degree",
                 {-60, -61, -62, -63, -64, -65, nan_, nan_});

    const double base[6][2] = {{0, 0}, {1, 0}, {2, 0}, {0, 1}, {1, 1}, {2, 1}};
    unsigned seed = 11;
    std::vector<double> coords;
    for (int r = 0; r < n_rows; ++r)
        for (int n = 0; n < n_nodes; ++n) {
            coords.push_back(base[n][0] + (frand(seed) - .5) * .04);
            coords.push_back(base[n][1] + (frand(seed) - .5) * .04);
        }

    mestra::Support& s = d.add_mesh_support(
        "s0", n_nodes, {9, 9}, {0, 4, 8}, {0, 1, 4, 3, 1, 2, 5, 4});
    mestra::set_coordinates(s, coords, 2, "m", "row");

    std::vector<double> mach, nut;
    for (int i = 0; i < n_rows * n_nodes; ++i) mach.push_back(.5 + frand(seed));
    for (int i = 0; i < n_rows * n_nodes; ++i)
        nut.push_back(1e-5 * frand(seed));
    mestra::add_field(s, mestra::Location::Node, "mach", "1", mach);
    mestra::add_field(s, mestra::Location::Node, "nut", "m^2/s", nut);

    mestra::write(d, path);
    std::printf("wrote %s\n", path.c_str());
    report(path);
}

// ------------------------------------------------------------- 3 ---
void d3_scalars(const std::string& path) {
    mestra::Dataset d;
    d.writer = "ergonomics review 3";
    d.created = "2026-09-20T00:00:00Z";
    d.generalisation_group = "geometry";
    d.add_categories("geometry", {"g0", "g1", "g2"});

    std::vector<double> camber, thickness, inc, cl, cd, cm;
    std::vector<int64_t> geom;
    unsigned seed = 13;
    for (int g = 0; g < 3; ++g)
        for (double a : {0., 4., 8., 12.}) {
            geom.push_back(g);
            camber.push_back(0.02 + 0.01 * g);
            thickness.push_back(0.10 + 0.02 * g);
            inc.push_back(a);
            cl.push_back(0.1 * a + frand(seed) * 0.01);
            cd.push_back(0.01 + 0.0005 * a * a);
            cm.push_back(-0.05 - 0.001 * a);
        }

    d.add_key("camber", "design", camber, "1");
    d.add_key("thickness", "design", thickness, "1");
    d.add_key("incidence", "condition", inc, "degree");
    d.add_category_key("geometry", "group", geom, "geometry");
    d.add_scalar("CL", "1", cl);
    d.add_scalar("CD", "1", cd);
    d.add_scalar("CM", "1", cm);

    mestra::write(d, path);
    std::printf("wrote %s\n", path.c_str());
    report(path);
}

// ------------------------------------------------------------- 4 ---
void d4_transient(const std::string& path) {
    const int steps[3] = {4, 3, 5};
    const double diffusivity[3] = {0.10, 0.25, 0.40};
    const double amplitude[3] = {1, 2, 3};
    std::vector<int64_t> run_of_row;
    std::vector<double> t_of_row, diff_of_row, amp_of_row;
    for (int r = 0; r < 3; ++r)
        for (int k = 1; k <= steps[r]; ++k) {
            run_of_row.push_back(r);
            t_of_row.push_back(0.1 * k);
            diff_of_row.push_back(diffusivity[r]);
            amp_of_row.push_back(amplitude[r]);
        }
    const size_t n_rows = run_of_row.size();
    const int n_nodes = 5;

    std::vector<double> x, u;
    for (int n = 0; n < n_nodes; ++n) x.push_back(n / 4.0);
    for (size_t r = 0; r < n_rows; ++r)
        for (int n = 0; n < n_nodes; ++n)
            u.push_back(amp_of_row[r] *
                        std::exp(-diff_of_row[r] * t_of_row[r]) *
                        std::sin(M_PI * x[static_cast<size_t>(n)]));

    mestra::Dataset d;
    d.writer = "ergonomics review 4";
    d.created = "2026-09-20T00:00:00Z";
    d.generalisation_group = "run";
    d.add_categories("run", {"r000", "r001", "r002"});
    d.add_key("diffusivity", "design", diff_of_row, "m^2/s");
    d.add_key("amplitude", "design", amp_of_row, "K");
    // header only: add_key has no trajectory_group parameter, so the
    // time key has to be fetched back by name and the field assigned.
    d.add_key("t", "time", t_of_row, "s");
    d.key("t")->trajectory_group = "run";
    d.add_category_key("run", "group", run_of_row, "run");

    mestra::Support& s = d.add_mesh_support(
        "s0", n_nodes, {3, 3, 3, 3}, {0, 2, 4, 6, 8},
        {0, 1, 1, 2, 2, 3, 3, 4});
    mestra::set_coordinates(s, x, 1, "m", "none");
    mestra::add_field(s, mestra::Location::Node, "u", "K", u);

    mestra::write(d, path);
    std::printf("wrote %s\n", path.c_str());
    report(path);
}

// ------------------------------------------------------------- 5 ---
void d5_axis(const std::string& path) {
    const int n_rows = 6, n_samples = 8;
    std::vector<double> ground_time;
    for (int j = 0; j < n_samples; ++j)
        ground_time.push_back(0.35 * j / (n_samples - 1));

    const double amps[6] = {50, 55, 60, 65, 70, 75};
    unsigned seed = 17;
    std::vector<double> overpressure;
    for (int i = 0; i < n_rows; ++i)
        for (int j = 0; j < n_samples; ++j)
            overpressure.push_back(
                amps[i] * std::sin(2 * M_PI * ground_time[
                    static_cast<size_t>(j)] / 0.35) +
                (frand(seed) - .5));

    mestra::Dataset d;
    d.writer = "ergonomics review 5";
    d.created = "2026-09-20T00:00:00Z";
    d.generalisation_group = "design";
    d.add_categories("design", {"d0", "d1", "d2"});
    d.add_key("area_1", "design", {.10, .10, .15, .15, .20, .20}, "m^2");
    d.add_key("area_2", "design", {.30, .30, .35, .35, .40, .40}, "m^2");
    d.add_key("mach", "condition", {1.4, 1.6, 1.4, 1.6, 1.4, 1.6}, "1");
    d.add_key("altitude", "condition",
              {12000, 12000, 14000, 14000, 16000, 16000}, "m");
    d.add_category_key("design", "group", {0, 0, 1, 1, 2, 2}, "design");
    d.add_scalar("loudness", "dB", {78, 80, 82, 84, 86, 88});

    // header only: the README shows add_mesh_support and nothing else.
    mestra::Support& s = d.add_axis_support("s0", ground_time, "s");
    mestra::add_field(s, mestra::Location::Node, "overpressure", "Pa",
                      overpressure);

    mestra::write(d, path);
    std::printf("wrote %s\n", path.c_str());
    report(path);
}

}  // namespace

int main(int argc, char** argv) {
    const std::string out = argc > 1 ? argv[1] : ".";
    struct { const char* name; void (*fn)(const std::string&); } cases[] = {
        {"d1_family", d1_family}, {"d2_cascade", d2_cascade},
        {"d3_scalars", d3_scalars}, {"d4_transient", d4_transient},
        {"d5_axis", d5_axis}};
    for (const auto& c : cases) {
        std::printf("########## %s ##########\n", c.name);
        try {
            c.fn(out + "/" + c.name + ".mes");
        } catch (const std::exception& e) {
            std::printf("  FAILED: %s\n", e.what());
        }
    }
    return 0;
}
