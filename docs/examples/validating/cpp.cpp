// Validating: a mistake refused while building, and a warning that is
// reported but does not stop a file.  See README.md for the output.
#include <cstdio>
#include <string>
#include <vector>

#include "mestra/mestra.hpp"

// Python's repr of a list of identifiers, so that this prints what
// python.py prints.
static std::string names_of(const std::vector<std::string>& v) {
  std::string s;
  for (const std::string& n : v) s += (s.empty() ? "'" : ", '") + n + "'";
  return "[" + s + "]";
}

int main() {
  const std::vector<double> cl = {0.21, 0.25, 0.30, 0.36, 0.41, 0.48};
  mestra::Dataset ds;
  ds.writer = "mestra examples 1";
  ds.created = "2026-09-19T00:00:00Z";
  ds.add_key("mach", {0.4, 0.8, 0.4, 0.8, 0.4, 0.8}, "condition", "1");
  ds.add_category_table("member", {"wing_a", "wing_b", "wing_c"});
  ds.add_category_key("member", {0, 0, 1, 1, 2, 2}, "group", "member");
  ds.set_generalisation_group("member");
  try {
    // C++ has no keyword arguments, so the mistake python.py makes by
    // leaving `units` out is made here by passing it empty.
    ds.add_scalar("cl", cl, "");
  } catch (const mestra::Error& refusal) {
    std::printf("refused: %s\n", refusal.what());
  }
  ds.add_scalar("cl", cl, "1");
  ds.add_category_table("split", {"train", "test"});
  ds.add_category_key("split", {0, 0, 0, 1, 1, 1}, "split", "split");
  mestra::write(ds, "family.mes");

  const mestra::Report report = mestra::validate("family.mes");
  std::printf("ok: %s\n", report.ok() ? "True" : "False");
  std::printf("errors: %s warnings: %s\n",
              names_of(report.error_ids()).c_str(),
              names_of(report.warning_ids()).c_str());
  for (const mestra::Finding& f : report.errors)
    std::printf("%s %s: %s\n", f.id.c_str(), f.where.c_str(),
                f.message.c_str());
  for (const mestra::Finding& f : report.warnings)
    std::printf("%s %s: %s\n", f.id.c_str(), f.where.c_str(),
                f.message.c_str());
}
