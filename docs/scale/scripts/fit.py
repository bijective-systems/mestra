"""Turn the timing logs into tables, and say whether a curve is linear.

    fit.py LOG [LOG ...]

Each log is what one of the timing drivers printed: lines of

    n01000_default.mes open=1.14 validate=0.76 rows=0.08 full=0.09 ...

For each layout it prints the times against N and, beside each one,
the local exponent p between that size and the one before it, where

    t(N2) / t(N1) = (N2 / N1) ** p

so p near 1 is linear, p near 2 is the square, and p below 1 means the
fixed cost still dominates. The verdict for a curve is taken from the
largest pair of sizes that differ by at least half again, which is the
one that decides whether a real file can be opened; a pair like 4000
and 4085 says nothing and is not used for it.
"""

from __future__ import annotations

import math
import os
import re
import sys

FIELDS = ("open", "validate", "rows", "full")
LINE = re.compile(r"^n(\d+)_([a-z0-9-]+)\.mes\s+(.*)$")


def read(path):
    rows = []
    for line in open(path):
        m = LINE.match(line.strip())
        if not m:
            continue
        n, layout, rest = int(m.group(1)), m.group(2), m.group(3)
        got = dict(re.findall(r"(\w+)=([-\d.]+)", rest))
        rows.append((layout, n, {k: float(got[k]) for k in FIELDS
                                 if k in got}))
    return rows


def exponent(n1, t1, n2, t2):
    if t1 <= 0 or t2 <= 0 or n1 == n2:
        return float("nan")
    return math.log(t2 / t1) / math.log(float(n2) / n1)


def verdict(p):
    if p != p:                                     # nan
        return "too fast to measure"
    if p < 1.15:
        return "linear"
    if p < 1.6:
        return "worse than linear"
    return "quadratic"


def main(argv):
    for path in argv[1:]:
        print("== %s" % os.path.basename(path))
        rows = read(path)
        layouts = []
        for layout, _, _ in rows:
            if layout not in layouts:
                layouts.append(layout)
        for layout in layouts:
            here = sorted((n, t) for l, n, t in rows if l == layout)
            print("   layout %s" % layout)
            print("   %8s %s" % ("N", "".join("%18s" % f
                                              for f in FIELDS)))
            last = None
            for n, t in here:
                cells = ""
                for f in FIELDS:
                    if f not in t:
                        cells += "%18s" % "-"
                        continue
                    p = (exponent(last[0], last[1].get(f, 0), n, t[f])
                         if last else float("nan"))
                    cells += "%12.3f%6s" % (
                        t[f], "" if p != p else "p%.2f" % p)
                print("   %8d %s" % (n, cells))
                last = (n, t)
            pairs = [(here[i], here[i + 1]) for i in range(len(here) - 1)
                     if here[i + 1][0] >= 1.5 * here[i][0]]
            if pairs:
                (n1, t1), (n2, t2) = pairs[-1]
                for f in FIELDS:
                    if f in t1 and f in t2:
                        p = exponent(n1, t1[f], n2, t2[f])
                        print("   %s from %d to %d: p = %.2f, %s"
                              % (f, n1, n2, p, verdict(p)))
        print("")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
