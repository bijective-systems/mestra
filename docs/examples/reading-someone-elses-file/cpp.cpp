// Reading someone else's file: ask the file what is in it, then take
// one value by name.  See README.md for the data and the output.
//
// The file to read is the one argument, and defaults to the committed
// `../mesh_two_rows.mes`, so running this from this directory reads
// what `python python.py` reads.
#include <cstdio>
#include <string>
#include <vector>

#include "mestra/mestra.hpp"

// Python's repr of a list or tuple of names, so that this prints what
// python.py prints.  `as_name` is what each thing is listed by.
static const std::string& as_name(const std::string& s) { return s; }
static const std::string& as_name(const mestra::Scalar& s) { return s.name; }
static const std::string& as_name(const mestra::ArraySlot& a) { return a.name; }

template <typename T>
static std::string names_of(const std::vector<T>& v, char open = '[') {
  std::string s;
  for (const T& e : v) s += (s.empty() ? "'" : ", '") + as_name(e) + "'";
  return std::string(1, open) + s + (open == '[' ? "]" : ")");
}

int main(int argc, char** argv) {
  const std::string path = argc > 1 ? argv[1] : "../mesh_two_rows.mes";
  std::printf("valid: %s\n", mestra::validate(path).ok() ? "True" : "False");

  const mestra::Dataset d = mestra::read(path);
  std::printf("%lld rows, aligned: %s\n", static_cast<long long>(d.n_rows),
              d.aligned ? "True" : "False");
  std::string keys;
  for (const mestra::Key& k : d.keys)
    keys += (keys.empty() ? "('" : ", ('") + k.name + "', '" + k.role + "')";
  std::printf("keys: [%s]\n", keys.c_str());
  std::printf("scalars: %s\n", names_of(d.scalars).c_str());
  for (const mestra::Support& s : d.supports) {
    std::printf("support %s %s %lld nodes %lld cells\n", s.name.c_str(),
                s.kind.c_str(), static_cast<long long>(s.n_nodes),
                static_cast<long long>(s.n_cells));
    std::printf("  node arrays: %s\n", names_of(s.node_arrays).c_str());
    std::printf("  cell arrays: %s\n", names_of(s.cell_arrays).c_str());
  }
  const mestra::ArraySlot* p = d.support("s0")->node_array("pressure");
  std::printf("pressure %s %s %s\n", names_of(p->data.dims, '(').c_str(),
              p->units->c_str(), p->varies.c_str());
  std::printf("pressure at row 1 node 3: %.1f\n", p->data.at_f64({1, 3, 0}));
  // One slot for one row range, reading no other slot and no other row.
  const mestra::Array one =
      mestra::read_slot_rows(path, "/supports/s0/node_arrays/pressure", 0, 1);
  std::printf("row 0 alone: (%zu, %zu, %zu)\n", one.shape[0], one.shape[1],
              one.shape[2]);
  const mestra::ArraySlot* region = d.support("s0")->cell_array("region");
  std::printf("region is a %s over %s\n", region->role.c_str(),
              names_of(d.category(*region->category)->entries).c_str());
}
