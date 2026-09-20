"""Time the C++ tool on a list of files.

    time_cpp.py CLI SLOT R0 R1 FILE [FILE ...]

Prints one line per file:

    <file> open=<s> validate=<s> rows=<s> full=<s> rss=<MiB>

Each measurement is one run of `mestra-cli`, so each includes the
process start and the file open; the `start` column of the report is
the same measurement on an empty command and is what to subtract.
`open` is `info`, `validate` is `validate`, `rows` is `rows SLOT R0
R1` and `full` is `rows SLOT 0 <row count>`. The peak resident size is
the child's, from getrusage. R1 may be `-` for the row count.
"""

from __future__ import annotations

import os
import re
import resource
import subprocess
import sys
import time

REPS = 3
LONG = 5.0
TIMEOUT = 7200


def run_once(cmd):
    t = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=TIMEOUT)
    return time.perf_counter() - t, p


def best(cmd):
    times, last = [], None
    for _ in range(REPS):
        dt, last = run_once(cmd)
        times.append(dt)
        if dt > LONG:
            break
    return min(times), last


def rss_mib():
    n = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    return n / (1024.0 * 1024.0) if sys.platform == "darwin" else n / 1024.0


def main(argv):
    cli, slot, r0, r1 = argv[1], argv[2], argv[3], argv[4]
    t_start, _ = best([cli, "callable-types"])
    print("start=%.4f  (one run of a command that opens no file)"
          % t_start)
    for path in argv[5:]:
        t_open, p = best([cli, "info", path])
        m = re.search(r"^rows (\d+)", p.stdout, re.M)
        n = m.group(1) if m else "0"
        end = n if r1 == "-" else r1
        t_val, _ = best([cli, "validate", path])
        t_rows, _ = best([cli, "rows", path, slot, r0, end])
        t_full, _ = best([cli, "rows", path, slot, "0", n])
        print("%s open=%.4f validate=%.4f rows=%.4f full=%.4f rss=%.1f"
              % (os.path.basename(path), t_open, t_val, t_rows, t_full,
                 rss_mib()))
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
