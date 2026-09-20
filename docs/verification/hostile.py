"""Run every reader over every hostile file, each under a timeout.

Section 29 asks a reader to treat a file as untrusted input, and
section 30 gives the shared subset its contract: the required rule
ids must appear, more are allowed, and the run must finish cleanly.
This drives the three entry points the contract names -- validate,
open for metadata (`info`), and a read of the data -- and records for
each whether the process exited cleanly, died on a signal, or had to
be killed on the timeout.

Python and C++ get one process per entry point. Julia and MATLAB pay
several seconds of start-up per process, so they get one process per
file that runs all three and times each one inside; the outer timeout
still catches a hang, at the cost of not saying which of the three
hung. That is recorded in the report.

  python docs/verification/hostile.py run      [SET ...]
  python docs/verification/hostile.py report
"""

from __future__ import annotations

import glob
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SCRATCH = os.environ.get(
    "MESTRA_SCRATCH",
    os.path.join(tempfile.gettempdir(), "mestra-phase3"))
OUT = os.path.join(SCRATCH, "hostile")

PY = os.environ.get("MESTRA_PYTHON", sys.executable)

JULIA = os.environ.get("MESTRA_JULIA", "julia")
MATLAB = os.environ.get("MESTRA_MATLAB", "matlab")
CLI = os.path.join(REPO, "cpp", "build", "mestra-cli")

LANGS = ("py", "ml", "cpp", "jl")
NAMES = {"py": "Python", "ml": "MATLAB", "cpp": "C++", "jl": "Julia"}

# A generous wall clock: the contract's ten seconds is about the work,
# and Julia and MATLAB spend several seconds starting up before any of
# it. Anything that reaches these is a hang by any reading.
WALL = {"py": 60, "cpp": 60, "jl": 150, "ml": 300}


def sets():
    out = {}
    shared = []
    for d in sorted(glob.glob(os.path.join(REPO, "vectors", "hostile", "*"))):
        f = os.path.join(d, "case.mes")
        if os.path.exists(f):
            shared.append((os.path.basename(d), f))
    out["shared"] = shared
    out["own_py"] = [(os.path.basename(f), f) for f in sorted(
        glob.glob(os.path.join(REPO, "python", "tests", "hostile", "*.mes")))]
    out["own_ml"] = [(os.path.basename(f), f) for f in sorted(
        glob.glob(os.path.join(REPO, "matlab", "tests", "hostile", "cases",
                               "*.mes")))]
    out["own_cpp"] = [(os.path.basename(f), f) for f in sorted(
        glob.glob(os.path.join(REPO, "cpp", "tests", "hostile", "*.mes")))]
    out["own_jl"] = [(os.path.basename(f), f) for f in sorted(
        glob.glob(os.path.join(REPO, "julia", "test", "hostile", "*.mes")))]
    adv = os.path.join(SCRATCH, "adv", "index.json")
    if os.path.exists(adv):
        out["adversarial"] = [(k, v["file"])
                              for k, v in sorted(json.load(open(adv)).items())]
    return out


def required(name):
    p = os.path.join(REPO, "vectors", "hostile", name, "expected.json")
    if os.path.exists(p):
        return json.load(open(p))["required_errors"]
    adv = os.path.join(SCRATCH, "adv", "index.json")
    if os.path.exists(adv):
        entry = json.load(open(adv)).get(name)
        if entry is not None:
            return entry["required_errors"]
    return None


def spawn(cmd, timeout):
    start = time.time()
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                             start_new_session=True)
        try:
            so, se = p.communicate(timeout=timeout)
            code = p.returncode
            hung = False
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            so, se = p.communicate()
            code = None
            hung = True
    except Exception as exc:
        return {"outcome": "spawn failed", "why": str(exc), "seconds": 0}
    elapsed = time.time() - start
    text = (so or b"").decode("utf-8", "replace") + \
           (se or b"").decode("utf-8", "replace")
    if hung:
        outcome = "hang"
    elif code is not None and code < 0:
        outcome = "signal %d" % (-code)
    else:
        outcome = "clean"
    return {"outcome": outcome, "code": code, "seconds": round(elapsed, 2),
            "ids": sorted(set(find_ids(text))), "text": text[-40000:]}


def find_ids(text):
    import re
    return re.findall(r"\b([EW](?:0[1-9]|[1-3][0-9]|4[01]))\b", text)


PYPKG = os.path.join(REPO, "python")
PRELUDE = "import sys; sys.path.insert(0, %r); " % PYPKG


def run_py(name, path):
    # `python -m mestra.cli` with the path pinned, rather than the
    # console script, because the shared environment's editable
    # install is repointed by whichever worktree installed last.
    return {
        "validate": spawn([PY, "-c", PRELUDE +
                           "from mestra.cli import main; "
                           "sys.exit(main(['validate', sys.argv[1]]))",
                           path], WALL["py"]),
        "info": spawn([PY, "-c", PRELUDE +
                       "from mestra.cli import main; "
                       "sys.exit(main(['info', sys.argv[1]]))",
                       path], WALL["py"]),
        "read": spawn([PY, "-c", PRELUDE + "import mestra;"
                       "ds=mestra.read(sys.argv[1], lazy=False);"
                       "print(ds);"
                       "print('problems:', [str(x) for x in ds.problems])",
                       path], WALL["py"]),
    }


def run_cpp(name, path):
    return {
        "validate": spawn([CLI, "validate", path], WALL["cpp"]),
        "info": spawn([CLI, "info", path], WALL["cpp"]),
        "read": spawn([CLI, "read", path], WALL["cpp"]),
    }


JULIA_ONE = r"""
using Mestra
path = ARGS[1]
for (what, f) in (("validate", () -> Mestra.validate(path)),
                  ("info", () -> Mestra.read(path)),
                  ("read", () -> (d = Mestra.read(path);
                                  Mestra.materialise!(d); d)))
    t0 = time()
    try
        r = f()
        if r isa Mestra.ValidationReport
            println("$(what) OK ", join(r.errors, " "), " ",
                    join(r.warnings, " "))
        else
            ids = String[]
            for fd in r.findings
                push!(ids, fd.rule)
            end
            println("$(what) OK ", join(sort(unique(ids)), " "))
        end
    catch e
        println("$(what) REFUSED ", sprint(showerror, e))
    end
    println("$(what) seconds ", round(time() - t0; digits = 2))
end
"""




def split_one(result):
    """One process that ran all three, split into three records."""
    out = {}
    text = result.get("text", "")
    for what in ("validate", "info", "read"):
        lines = [ln for ln in text.splitlines() if ln.startswith(what + " ")]
        seconds = None
        body = []
        for ln in lines:
            if ln.startswith("%s seconds " % what):
                try:
                    seconds = float(ln.split()[-1])
                except ValueError:
                    pass
            else:
                body.append(ln)
        joined = "\n".join(body)
        if result["outcome"] != "clean":
            out[what] = {"outcome": result["outcome"],
                         "seconds": result.get("seconds"),
                         "ids": [], "text": text[-4000:],
                         "note": "one process ran all three"}
        else:
            out[what] = {"outcome": "clean" if body else "no output",
                         "seconds": seconds,
                         "ids": sorted(set(find_ids(joined))),
                         "text": joined[-4000:]}
    return out


def run_jl(name, path):
    script = os.path.join(SCRATCH, "hostile_one.jl")
    with open(script, "w") as fh:
        fh.write(JULIA_ONE)
    r = spawn([JULIA, "--project=" + os.path.join(REPO, "julia"), script,
               path], WALL["jl"])
    return split_one(r)


def run_ml(name, path):
    # `matlab -batch` takes one line only, so the three entry points
    # live in a helper beside this file.
    code = ("addpath('%s'); addpath('%s'); mestraHostileOne('%s')"
            % (os.path.join(REPO, "matlab"), HERE, path))
    r = spawn([MATLAB, "-nodisplay", "-batch", code], WALL["ml"])
    return split_one(r)


RUNNERS = {"py": run_py, "ml": run_ml, "cpp": run_cpp, "jl": run_jl}


def phase_run(which):
    os.makedirs(OUT, exist_ok=True)
    groups = sets()
    todo = which or list(groups)
    for group in todo:
        for lang in LANGS:
            results = {}
            for name, path in groups[group]:
                results[name] = RUNNERS[lang](name, path)
                print("  %-6s %-10s %-28s %s" % (
                    lang, group, name,
                    " ".join("%s:%s" % (k, v["outcome"])
                             for k, v in results[name].items())))
            with open(os.path.join(OUT, "%s_%s.json" % (group, lang)),
                      "w") as fh:
                json.dump(results, fh, indent=1)


def phase_report():
    groups = sets()
    print("hostile files: outcome of validate, info and read, each under "
          "a timeout")
    print()
    for group in sorted(groups):
        names = [n for n, _ in groups[group]]
        if not names:
            continue
        print("%s (%d files)" % (group, len(names)))
        print("  %-8s %8s %8s %8s %8s %s"
              % ("", "clean", "signal", "hang", "no out", "missing ids"))
        for lang in LANGS:
            p = os.path.join(OUT, "%s_%s.json" % (group, lang))
            if not os.path.exists(p):
                print("  %-8s not run" % NAMES[lang])
                continue
            data = json.load(open(p))
            clean = sig = hang = noout = 0
            missing = []
            for name, entries in sorted(data.items()):
                for what, r in entries.items():
                    o = r["outcome"]
                    if o == "clean":
                        clean += 1
                    elif o == "hang":
                        hang += 1
                    elif o.startswith("signal"):
                        sig += 1
                    else:
                        noout += 1
                req = required(name)
                if req:
                    for what, r in entries.items():
                        got = set(r.get("ids") or [])
                        lack = [i for i in req if i not in got]
                        if lack:
                            missing.append("%s/%s lacks %s"
                                           % (name, what, ",".join(lack)))
            print("  %-8s %8d %8d %8d %8d %s"
                  % (NAMES[lang], clean, sig, hang, noout,
                     "; ".join(missing) if missing else "-"))
        print()


def main(argv):
    if len(argv) > 1 and argv[1] == "report":
        phase_report()
    else:
        phase_run(argv[2:] if len(argv) > 2 else None)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
