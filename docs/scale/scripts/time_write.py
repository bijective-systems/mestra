"""How long each writer takes to write one file, and how big it is.

    time_write.py REPO CLI MATLAB IN.mes OUTDIR [--langs a,b]

Every implementation is asked to read IN.mes and write it again,
through the Phase 3 driver it already has, so what is timed is the
same work in four languages. The time therefore includes the eager
read and, for MATLAB and Julia, the interpreter's start; the `empty`
row is the same call on a file of two rows and is what to subtract
for the start.

For each writer it prints the wall time, the size of what it wrote,
and whether the C++ validator accepts it.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time

LANGS = ("Python", "MATLAB", "C++", "Julia")
TIMEOUT = 14400


def jobs_file(src, dst):
    out = tempfile.mktemp(suffix=".json")
    path = tempfile.NamedTemporaryFile("w", suffix=".json",
                                       delete=False)
    json.dump([{"op": "write", "src": src, "dst": dst, "out": out}],
              path)
    path.close()
    return path.name, out


def command(lang, repo, cli, matlab, jobs):
    ver = os.path.join(repo, "docs", "verification")
    if lang == "Python":
        return [sys.executable, os.path.join(ver, "driver.py"), "batch",
                jobs]
    if lang == "C++":
        return [sys.executable, os.path.join(ver, "cppdrv.py"), cli,
                "batch", jobs]
    if lang == "Julia":
        return ["julia", "--project=" + os.path.join(repo, "julia"),
                os.path.join(ver, "driver.jl"), "batch", jobs]
    if lang == "MATLAB":
        code = ("addpath('%s'); addpath('%s'); "
                "mestraVerifyDriver('batch','%s')"
                % (os.path.join(repo, "matlab"), ver, jobs))
        return [matlab, "-nodisplay", "-batch", code]
    raise ValueError(lang)


def one(lang, repo, cli, matlab, src, dst):
    jobs, out = jobs_file(src, dst)
    t = time.perf_counter()
    p = subprocess.run(command(lang, repo, cli, matlab, jobs),
                       capture_output=True, text=True, timeout=TIMEOUT)
    dt = time.perf_counter() - t
    ok = os.path.exists(dst)
    size = os.path.getsize(dst) if ok else 0
    note = ""
    if not ok:
        note = (p.stderr or p.stdout).strip().splitlines()[-1][:70] \
            if (p.stderr or p.stdout).strip() else "no file written"
    for tmp in (jobs, out):
        if os.path.exists(tmp):
            os.unlink(tmp)
    return dt, size, note


def main(argv):
    argv = list(argv)
    langs = list(LANGS)
    if "--langs" in argv:
        i = argv.index("--langs")
        langs = argv[i + 1].split(",")
        argv = argv[:i] + argv[i + 2:]
    repo, cli, matlab, src, outdir = argv[1:6]
    os.makedirs(outdir, exist_ok=True)
    empty = os.path.join(repo, "vectors", "cases", "mesh_two_rows",
                         "case.mes")
    print("%-8s %10s %14s  %s" % ("writer", "seconds", "bytes", "note"))
    for lang in langs:
        dst = os.path.join(outdir, "empty_%s.mes" % lang)
        dt, size, note = one(lang, repo, cli, matlab, empty, dst)
        print("%-8s %10.1f %14d  empty file, the start-up cost"
              % (lang, dt, size))
        if os.path.exists(dst):
            os.unlink(dst)
        sys.stdout.flush()
    for lang in langs:
        dst = os.path.join(outdir, "big_%s.mes" % lang)
        dt, size, note = one(lang, repo, cli, matlab, src, dst)
        check = ""
        if size:
            p = subprocess.run([cli, "validate", dst],
                               capture_output=True, text=True)
            check = p.stdout.strip().splitlines()[-1]
        print("%-8s %10.1f %14d  %s" % (lang, dt, size, note or check))
        if os.path.exists(dst):
            os.unlink(dst)
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
