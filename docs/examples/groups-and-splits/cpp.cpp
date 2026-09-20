// Groups and splits: whole members move together, never single rows.
// See README.md in this directory for the data and the output.
//
// This program stops where the README's first two lines stop.  C++ has
// no `grouped_split`, by decision: the split itself is a Python,
// MATLAB or Julia helper, and cpp/README.md says why.  What the format
// decides -- which unit of generalisation a file declares, and whether
// the split it stores leaks one -- is here, read off the file.
#include <algorithm>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

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
  ds.add_category_table("split", {"train", "test"});
  ds.add_category_key("split", {0, 0, 0, 1, 1, 1}, "split", "split");
  mestra::write(ds, "family.mes");

  const mestra::Dataset d = mestra::read("family.mes");
  const mestra::Key* unit = d.key(*d.generalisation_group);
  const mestra::Key* split = nullptr;
  for (const mestra::Key& k : d.keys)
    if (k.role == "split") split = &k;
  // A unit leaks when its rows carry more than one split value.
  std::map<std::int64_t, std::set<std::int64_t>> sides;
  for (std::size_t r = 0; r < unit->i64.size(); ++r)
    sides[unit->i64[r]].insert(split->i64[r]);
  const mestra::CategoryTable* table = d.category(*unit->category);
  std::vector<std::string> leaked;
  for (const auto& side : sides)
    if (side.second.size() > 1)
      leaked.push_back(table->entries[static_cast<std::size_t>(side.first)]);
  std::sort(leaked.begin(), leaked.end());
  std::string names;
  for (const std::string& n : leaked)
    names += (names.empty() ? "'" : ", '") + n + "'";
  std::printf("unit of generalisation: %s\n", unit->name.c_str());
  std::printf("the split in the file leaks: [%s]\n", names.c_str());
}
