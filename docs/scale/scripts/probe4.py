"""Run all four implementations over one file and compare.

Uses the Phase 3 drivers as they stand, so that what each language is
asked is the same thing the verification asked it:

    probe4.py REPO CLI MATLAB PROBES.json FILE [FILE ...]

PROBES.json is the `probes` list of a corpus case's expected.json, or
any list of {"slot": ..., "row": ..., ...} objects. For each file each
language prints its validator's error and warning ids and the value it
returns for every probe, and the probes are compared across the four.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

LANGS = ("Python", "MATLAB", "C++", "Julia")
TIMEOUT = 7200


def run(cmd, timeout=TIMEOUT):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout after %d s" % timeout


def driver_cmd(lang, repo, cli, matlab, here, out, path, probes):
    job = [{"op": "check", "file": path, "probes": probes, "out": out}]
    jobs = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(job, jobs)
    jobs.close()
    ver = os.path.join(repo, "docs", "verification")
    if lang == "Python":
        return [sys.executable, os.path.join(ver, "driver.py"), "batch",
                jobs.name]
    if lang == "C++":
        return [sys.executable, os.path.join(ver, "cppdrv.py"), cli,
                "batch", jobs.name]
    if lang == "Julia":
        return ["julia", "--project=" + os.path.join(repo, "julia"),
                os.path.join(ver, "driver.jl"), "batch", jobs.name]
    if lang == "MATLAB":
        code = ("addpath('%s'); addpath('%s'); "
                "mestraVerifyDriver('batch','%s')"
                % (os.path.join(repo, "matlab"), ver, jobs.name))
        return [matlab, "-nodisplay", "-batch", code]
    raise ValueError(lang)


def check(lang, repo, cli, matlab, path, probes_path):
    here = os.path.dirname(os.path.abspath(__file__))
    out = tempfile.mktemp(suffix=".json")
    cmd = driver_cmd(lang, repo, cli, matlab, here, out, path,
                     probes_path)
    code, so, se = run(cmd)
    if not os.path.exists(out):
        return {"failed": (se or so).strip().splitlines()[-1][:80]
                if (se or so).strip() else "no output"}
    with open(out) as fh:
        result = json.load(fh)
    os.unlink(out)
    return result


def main(argv):
    repo, cli, matlab, probes_path = argv[1:5]
    probes = json.load(open(probes_path))
    for path in argv[5:]:
        print("== %s" % os.path.basename(path))
        table = {}
        for lang in LANGS:
            r = check(lang, repo, cli, matlab, path, probes_path)
            table[lang] = r
            if "failed" in r:
                print("   %-8s FAILED  %s" % (lang, r["failed"]))
                continue
            print("   %-8s errors=%s warnings=%s trouble=%s"
                  % (lang, ",".join(r.get("errors", [])) or "-",
                     ",".join(r.get("warnings", [])) or "-",
                     "; ".join(r.get("trouble", []))[:60] or "-"))
            sys.stdout.flush()
        for i, p in enumerate(probes):
            vals = []
            for lang in LANGS:
                got = table[lang].get("probes") or []
                vals.append(got[i] if i < len(got) else None)
            same = "same" if len(set(map(str, vals))) == 1 else "DIFFER"
            print("   probe %-46s %s  %s"
                  % (p["slot"], same, vals[0]))
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
