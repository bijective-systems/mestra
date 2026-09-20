// Time the C++ reader on a list of files, in one process.
//
//     time_open SLOT R0 R1 FILE [FILE ...]
//
// Prints one line per file:
//
//     <file> open=<s> validate=<s> rows=<s> full=<s> rss=<MiB>
//
// `open` is mestra::read_header, the metadata open of section 29;
// `validate` is mestra::validate; `rows` is mestra::read_slot_rows
// over the half-open row range [R0, R1); and `full` is the same call
// over every row. R1 may be `-` for the file's row count. Each is
// timed three times and the smallest is kept, unless the first
// attempt took more than five seconds.
//
// This exists because `mestra-cli info` validates the file before it
// prints anything, so timing the tool measures a validation and not
// an open. Build it against the library the tool is built from:
//
//     c++ -std=c++17 -O2 -I $REPO/cpp/include -I $HDF5_ROOT/include \
//         docs/scale/scripts/time_open.cpp -o $SCRATCH/time_open \
//         $SCRATCH/build/libmestra.a -L $HDF5_ROOT/lib -lhdf5 -lhdf5_hl

#include <sys/resource.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>

#include "mestra/io.hpp"
#include "mestra/validate.hpp"

namespace {

const int kReps = 3;
const double kLong = 5.0;

double best(const std::function<void()>& fn) {
  double smallest = 0.0;
  for (int i = 0; i < kReps; ++i) {
    const auto start = std::chrono::steady_clock::now();
    fn();
    const std::chrono::duration<double> took =
        std::chrono::steady_clock::now() - start;
    if (i == 0 || took.count() < smallest) smallest = took.count();
    if (took.count() > kLong) break;
  }
  return smallest;
}

double rss_mib() {
  struct rusage usage;
  getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
  return static_cast<double>(usage.ru_maxrss) / (1024.0 * 1024.0);
#else
  return static_cast<double>(usage.ru_maxrss) / 1024.0;
#endif
}

std::string base(const std::string& path) {
  const std::size_t cut = path.find_last_of('/');
  return cut == std::string::npos ? path : path.substr(cut + 1);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 5) {
    std::fprintf(stderr, "time_open SLOT R0 R1 FILE [FILE ...]\n");
    return 2;
  }
  const std::string slot = argv[1];
  const std::size_t r0 = std::strtoul(argv[2], nullptr, 10);
  const std::string r1 = argv[3];
  for (int i = 4; i < argc; ++i) {
    const std::string path = argv[i];
    std::size_t rows = 0;
    const double open = best([&]() {
      const mestra::Dataset d = mestra::read_header(path);
      rows = static_cast<std::size_t>(d.n_rows);
    });
    const double check = best([&]() { mestra::validate(path); });
    const std::size_t end = r1 == "-" ? rows : std::strtoul(
        r1.c_str(), nullptr, 10);
    const double range = best(
        [&]() { mestra::read_slot_rows(path, slot, r0, end); });
    const double full = best(
        [&]() { mestra::read_slot_rows(path, slot, 0, rows); });
    std::printf("%s open=%.4f validate=%.4f rows=%.4f full=%.4f "
                "rss=%.1f\n", base(path).c_str(), open, check, range,
                full, rss_mib());
    std::fflush(stdout);
  }
  return 0;
}
