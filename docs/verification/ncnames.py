"""Check that netCDF-C reads a file's dimension names as HDF5 does.

Section 21: the dimension's name is the scale dataset's HDF5 link
name. This runs `ncdump -h` over a file, parses the dimension list of
every variable it prints, and compares it against the link names of
the scales attached to that dataset's axes, taken through the bounded
address map of docs/verification/structural.py.

  python docs/verification/ncnames.py NCDUMP FILE [FILE ...]
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import structural as st  # noqa: E402

VAR = re.compile(r"^\s*(\w[\w ]*?)\s+([A-Za-z0-9_.+-]+)\s*\(([^)]*)\)\s*;")
BARE = re.compile(r"^\s*(\w[\w ]*?)\s+([A-Za-z0-9_.+-]+)\s*;")
GROUP = re.compile(r"^\s*group:\s*([A-Za-z0-9_.+-]+)\s*\{")


def from_ncdump(ncdump, path):
    """Variable path -> tuple of dimension names, as netCDF-C sees it."""
    p = subprocess.run([ncdump, "-h", path], capture_output=True, text=True,
                       timeout=120)
    if p.returncode != 0:
        raise RuntimeError("ncdump failed: %s" % p.stderr.strip()[:300])
    out = {}
    stack = []
    section = None
    for line in p.stdout.splitlines():
        g = GROUP.match(line)
        if g:
            stack.append(g.group(1))
            section = None
            continue
        if line.strip().startswith("}"):
            if stack:
                stack.pop()
            section = None
            continue
        s = line.strip()
        if s in ("dimensions:", "variables:", "data:"):
            section = s[:-1]
            continue
        if s.startswith("// global attributes") or s.startswith("//"):
            section = None
            continue
        if section != "variables":
            continue
        if ":" in s.split("(")[0] and not s.startswith("//"):
            continue          # an attribute line, `var:attr = ...`
        m = VAR.match(line)
        if m:
            dims = tuple(d.strip() for d in m.group(3).split(",") if d.strip())
            out["/" + "/".join(stack + [m.group(2)])] = dims
            continue
        m = BARE.match(line)
        if m and "=" not in line:
            out["/" + "/".join(stack + [m.group(2)])] = ()
    return out, p.stdout


def from_hdf5(path):
    """Dataset path -> tuple of attached scale link names, per axis."""
    f, objects, scales, _problems = st.walk(path)
    out = {}
    try:
        for p, (kind, obj) in objects.items():
            if kind != "dataset":
                continue
            if p.lstrip("/") in scales.values() and "CLASS" in obj.attrs:
                continue      # a dimension scale is not a variable
            names = st.attached_scale_names(obj, scales)
            out[p] = tuple(n[0] if len(n) == 1 else str(n) for n in names)
    finally:
        f.close()
    return out, scales


def check(ncdump, path):
    nc, raw = from_ncdump(ncdump, path)
    h5, scales = from_hdf5(path)
    scale_paths = set()
    f, objects, _s, _p = st.walk(path)
    try:
        for p, (kind, obj) in objects.items():
            if kind == "dataset" and "CLASS" in obj.attrs:
                scale_paths.add(p)
    finally:
        f.close()
    bad = []
    for p, dims in sorted(h5.items()):
        if p in scale_paths:
            continue
        if p not in nc:
            bad.append("%s: netCDF-C does not list it as a variable" % p)
            continue
        if nc[p] != dims:
            bad.append("%s: netCDF-C says %s, the scales say %s"
                       % (p, nc[p], dims))
    return bad, len(h5) - len(scale_paths & set(h5)), raw


def main(argv):
    ncdump = argv[1]
    total = 0
    failed = 0
    for path in argv[2:]:
        try:
            bad, n, _raw = check(ncdump, path)
        except Exception as exc:
            print("%s: %s: %s" % (path, type(exc).__name__, exc))
            failed += 1
            continue
        total += n
        if bad:
            failed += 1
            for b in bad:
                print("%s  %s" % (os.path.basename(path), b))
        else:
            print("%s: %d variables, every dimension name agrees"
                  % (os.path.basename(path), n))
    print("%d variables checked, %d file(s) with a difference"
          % (total, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
