"""Who can read a file, and what they call its dimensions.

    readable.py NCDUMP CLI REPO MATLAB FILE [FILE ...]

REPO is the checkout the four implementations are read from.

For each file it reports, one line per reader:

    netcdf-c   ncdump -h: does it parse, how many variables and
               dimensions does it see, and what does it call the
               dimension of the first row-dimensioned variable
    h5netcdf   the same three, through h5netcdf
    netCDF4    the same three, through the netCDF4 python package
    mestra-*   the four implementations: the validator's finding
               counts and the row count the metadata open reports

Pass `-` for any tool that is not available; that reader is skipped.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

TIMEOUT = 1800


def run(cmd, timeout=TIMEOUT):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout after %d s" % timeout


def by_ncdump(ncdump, path):
    code, out, err = run([ncdump, "-h", path])
    if code != 0:
        return "refused: " + (err.strip().splitlines() or [""])[0][:70]
    dims = len(re.findall(r"^\s+\w+ = ", out, re.M))
    vars_ = len(re.findall(r"^\s+[\w ]+ \w+\(", out, re.M))
    first = re.search(r"^\s+[\w ]+ cl\(([^)]*)\)", out, re.M)
    return "ok  dims=%d vars=%d cl(%s)" % (
        dims, vars_, first.group(1) if first else "?")


def walk_nc(group):
    """Every variable and dimension of a netCDF-4 file, groups and all."""
    nvar = len(group.variables)
    ndim = len(group.dimensions)
    for sub in group.groups.values():
        a, b = walk_nc(sub)
        nvar, ndim = nvar + a, ndim + b
    return nvar, ndim


def by_h5netcdf(path):
    try:
        import h5netcdf
        with h5netcdf.File(path, "r") as f:
            nvar, ndim = walk_nc(f)
            first = f["scalars"].variables["cl"].dimensions
            return "ok  dims=%d vars=%d cl(%s)" % (
                ndim, nvar, ",".join(first))
    except Exception as exc:                       # noqa: BLE001
        return "refused: %s: %s" % (type(exc).__name__,
                                    str(exc).strip()[:60])


def by_netcdf4(path):
    try:
        import netCDF4
        with netCDF4.Dataset(path, "r") as f:
            nvar, ndim = walk_nc(f)
            first = f.groups["scalars"].variables["cl"].dimensions
            return "ok  dims=%d vars=%d cl(%s)" % (
                ndim, nvar, ",".join(first))
    except Exception as exc:                       # noqa: BLE001
        return "refused: %s: %s" % (type(exc).__name__,
                                    str(exc).strip()[:60])


def by_cpp(cli, path):
    code, out, err = run([cli, "validate", path])
    tail = out.strip().splitlines()[-1] if out.strip() else err[:60]
    code2, out2, err2 = run([cli, "info", path])
    m = re.search(r"^rows (\d+)", out2, re.M)
    rows = m.group(1) if m else "?"
    return "%s  info rows=%s" % (tail, rows)


def by_python(pkg, path):
    code, out, err = run([
        sys.executable, "-c",
        "import sys; sys.path.insert(0, %r)\n"
        "import mestra\n"
        "r = mestra.validate(%r)\n"
        "ds = mestra.read(%r)\n"
        "print('%%d error(s), %%d warning(s)  info rows=%%d'\n"
        "      %% (len(r.error_ids), len(r.warning_ids), ds.n_rows))"
        % (pkg, path, path)])
    return (out.strip() or err.strip().splitlines()[-1][:70]) if (
        out.strip() or err.strip()) else "no output"


def by_julia(proj, path):
    code, out, err = run([
        "julia", "--project=" + proj, "-e",
        "using Mestra\n"
        "r = Mestra.validate(\"%s\")\n"
        "ds = Mestra.read(\"%s\")\n"
        "println(length(r.errors), \" error(s), \", length(r.warnings),"
        " \" warning(s)  info rows=\", ds.nrows)" % (path, path)])
    return (out.strip() or err.strip().splitlines()[-1][:70]) if (
        out.strip() or err.strip()) else "no output"


def by_matlab(matlab, mdir, path):
    code = ("addpath('%s'); r = mestra.validate('%s'); "
            "d = mestra.open('%s'); "
            "fprintf('%%d error(s), %%d warning(s)  info rows=%%d\\n', "
            "numel(r.errors), numel(r.warnings), d.nRows);"
            % (mdir, path, path))
    rc, out, err = run([matlab, "-nodisplay", "-batch", code])
    lines = [l for l in out.splitlines() if "error(s)" in l]
    return lines[-1] if lines else (err.strip()[:70] or "no output")


def main(argv):
    argv = list(argv)
    skip = set()
    if "--skip" in argv:
        i = argv.index("--skip")
        skip = set(argv[i + 1].split(","))
        argv = argv[:i] + argv[i + 2:]
    ncdump, cli, repo, matlab = argv[1:5]
    pkg = os.path.join(repo, "python")
    proj = os.path.join(repo, "julia")
    mdir = os.path.join(repo, "matlab")
    for path in argv[5:]:
        print("== %s (%d bytes)" % (os.path.basename(path),
                                    os.path.getsize(path)))
        if ncdump != "-" and "netcdf-c" not in skip:
            print("   %-10s %s" % ("netcdf-c", by_ncdump(ncdump, path)))
        if "h5netcdf" not in skip:
            print("   %-10s %s" % ("h5netcdf", by_h5netcdf(path)))
        if "netCDF4" not in skip:
            print("   %-10s %s" % ("netCDF4", by_netcdf4(path)))
        if cli != "-" and "C++" not in skip:
            print("   %-10s %s" % ("C++", by_cpp(cli, path)))
        if "Python" not in skip:
            print("   %-10s %s" % ("Python", by_python(pkg, path)))
        if "Julia" not in skip:
            print("   %-10s %s" % ("Julia", by_julia(proj, path)))
        if matlab != "-" and "MATLAB" not in skip:
            print("   %-10s %s" % ("MATLAB",
                                   by_matlab(matlab, mdir, path)))
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
