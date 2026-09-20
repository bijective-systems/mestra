// Rows and roles: six rows of a three-member family, no support.
// See README.md in this directory for the data and the output.
#include <cstdio>
#include <string>

#include "mestra/mestra.hpp"

int main() {
  mestra::Dataset ds;
  ds.writer = "mestra examples 1";
  ds.created = "2026-09-19T00:00:00Z";
  ds.add_key("mach", {0.4, 0.8, 0.4, 0.8, 0.4, 0.8}, "condition", "1");
  ds.add_category_table("member", {"wing_a", "wing_b", "wing_c"});
  ds.add_category_key("member", {0, 0, 1, 1, 2, 2}, "group", "member");
  ds.set_generalisation_group("member");
  ds.add_scalar("cl", {0.21, 0.25, 0.30, 0.36, 0.41, 0.48}, "1");
  mestra::write(ds, "family.mes");

  const mestra::Dataset d = mestra::read("family.mes");
  std::printf("%lld rows, %zu keys\n", static_cast<long long>(d.n_rows),
              d.keys.size());
  for (const std::string& name : d.key_order()) {
    const mestra::Key* k = d.key(name);
    // A key carries units or names a category table, never both.
    const std::string& what = k->units ? *k->units : *k->category;
    std::printf("%s %s %s\n", name.c_str(), k->role.c_str(), what.c_str());
  }
  std::printf("generalisation unit: %s\n", d.generalisation_group->c_str());
  const mestra::Scalar* cl = d.scalar("cl");
  std::printf("cl at row 3: %.2f\n", cl->values[3]);
  std::printf("cl units: %s\n", cl->units.c_str());
}
