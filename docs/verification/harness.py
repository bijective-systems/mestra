"""The Phase 3 cross-language harness.

It drives the four per-language drivers, which all speak the same
JSON, and reports matrices of counts. It knows nothing about any
implementation beyond how to start its driver.

  harness.py write     write every valid case with every writer
  harness.py check     read every written file with every reader
  harness.py report    the matrices and the failures
  harness.py evaluate  the affine cases, in every language
  harness.py determinism
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SCRATCH = os.environ.get(
    "MESTRA_SCRATCH",
    os.path.join(tempfile.gettempdir(), "mestra-phase3"))

PY = os.environ.get("MESTRA_PYTHON", sys.executable)
JULIA = os.environ.get("MESTRA_JULIA", "julia")
MATLAB = os.environ.get("MESTRA_MATLAB", "matlab")
CLI = os.path.join(REPO, "cpp", "build", "mestra-cli")

LANGS = ("py", "ml", "cpp", "jl")
NAMES = {"py": "Python", "ml": "MATLAB", "cpp": "C++", "jl": "Julia"}


def case_names():
    m = json.load(open(os.path.join(REPO, "vectors", "manifest.json")))
    return [c["name"] for c in m["cases"]]


def expected(name):
    return json.load(
        open(os.path.join(REPO, "vectors", "cases", name, "expected.json")))


def valid_cases():
    return [n for n in case_names() if not expected(n)["validator"]["errors"]]


def golden(name):
    return os.path.join(REPO, "vectors", "cases", name, "case.mes")


def probes_file(name):
    d = os.path.join(SCRATCH, "probes")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name + ".json")
    if not os.path.exists(p):
        with open(p, "w") as fh:
            json.dump(expected(name)["probes"], fh)
    return p


def run_batch(lang, jobs, tag, timeout=1800):
    d = os.path.join(SCRATCH, "jobs")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "%s_%s.json" % (lang, tag))
    with open(path, "w") as fh:
        json.dump(jobs, fh)
    if lang == "py":
        cmd = [PY, os.path.join(HERE, "driver.py"), "batch", path]
    elif lang == "cpp":
        cmd = [PY, os.path.join(HERE, "cppdrv.py"), CLI, "batch", path]
    elif lang == "jl":
        cmd = [JULIA, "--project=" + os.path.join(REPO, "julia"),
               os.path.join(HERE, "driver.jl"), "batch", path]
    elif lang == "ml":
        code = ("addpath('%s'); addpath('%s'); mestraVerifyDriver('batch','%s')"
                % (os.path.join(REPO, "matlab"), HERE, path))
        cmd = [MATLAB, "-nodisplay", "-batch", code]
    else:
        raise ValueError(lang)
    with open(os.devnull) as devnull:
        p = subprocess.run(cmd, stdin=devnull, capture_output=True, text=True,
                           timeout=timeout)
    log = os.path.join(SCRATCH, "logs", "%s_%s.log" % (lang, tag))
    os.makedirs(os.path.dirname(log), exist_ok=True)
    with open(log, "w") as fh:
        fh.write("exit %d\n--- stdout ---\n%s\n--- stderr ---\n%s"
                 % (p.returncode, p.stdout, p.stderr))
    return p.returncode


# ------------------------------------------------------------- phases

def phase_write():
    cases = valid_cases()
    for lang in LANGS:
        out = os.path.join(SCRATCH, "xwrite", lang)
        os.makedirs(out, exist_ok=True)
        jobs = [{"op": "write", "src": golden(c),
                 "dst": os.path.join(out, c + ".mes"),
                 "out": os.path.join(out, c + ".write.json")}
                for c in cases]
        code = run_batch(lang, jobs, "write")
        wrote = sum(1 for c in cases
                    if os.path.exists(os.path.join(out, c + ".mes")))
        print("%-6s exit %d, %d of %d files written"
              % (lang, code, wrote, len(cases)))


def phase_check():
    cases = valid_cases()
    for c in cases:
        probes_file(c)
    for reader in LANGS:
        jobs = []
        for writer in LANGS:
            res = os.path.join(SCRATCH, "results", reader, writer)
            os.makedirs(res, exist_ok=True)
            for c in cases:
                src = os.path.join(SCRATCH, "xwrite", writer, c + ".mes")
                if not os.path.exists(src):
                    continue
                jobs.append({"op": "check", "file": src,
                             "probes": probes_file(c),
                             "out": os.path.join(res, c + ".json")})
        res = os.path.join(SCRATCH, "results", reader, "golden")
        os.makedirs(res, exist_ok=True)
        for c in cases:
            jobs.append({"op": "check", "file": golden(c),
                         "probes": probes_file(c),
                         "out": os.path.join(res, c + ".json")})
        code = run_batch(reader, jobs, "check")
        print("%-6s exit %d, %d jobs" % (reader, code, len(jobs)))


def load(reader, writer, case):
    p = os.path.join(SCRATCH, "results", reader, writer, case + ".json")
    if not os.path.exists(p):
        return None
    try:
        with open(p) as fh:
            return json.load(fh)
    except Exception:
        return None


def float_bits(text):
    import struct
    if text == "nan":
        return b"nan"
    if text in ("inf", "-inf"):
        return text.encode()
    return struct.pack("<d", float(text))


def compare_probe(want, got):
    if got is None:
        return "missing"
    if "e" in want or "." in want or want in ("nan", "inf", "-inf"):
        try:
            if float_bits(want) == float_bits(got):
                return None
        except ValueError:
            return "unparseable %r" % got
        return "%s vs %s" % (want, got)
    return None if want == got else "%s vs %s" % (want, got)


def assess(case, result):
    """Every axis this case must agree on. Returns a list of failures."""
    if result is None:
        return ["no result"]
    if "failed" in result:
        return ["driver: " + str(result["failed"])[:160]]
    want = expected(case)
    bad = []
    if sorted(result.get("errors", [])) != want["validator"]["errors"]:
        bad.append("validator errors %s, want %s"
                   % (sorted(result.get("errors", [])),
                      want["validator"]["errors"]))
    if sorted(result.get("warnings", [])) != want["validator"]["warnings"]:
        bad.append("validator warnings %s, want %s"
                   % (sorted(result.get("warnings", [])),
                      want["validator"]["warnings"]))
    if result.get("support_ids", {}) != want["support_ids"]:
        bad.append("support_ids %s, want %s"
                   % (result.get("support_ids"), want["support_ids"]))
    got = result.get("probes", [])
    for i, p in enumerate(want["probes"]):
        g = got[i] if i < len(got) else None
        why = compare_probe(p["value"], g)
        if why:
            bad.append("probe %s %s: %s"
                       % (p["slot"],
                          {k: v for k, v in p.items()
                           if k not in ("slot", "value")}, why))
    return bad


def structural(case, writer):
    sys.path.insert(0, HERE)
    import structural as st
    a = golden(case)
    b = os.path.join(SCRATCH, "xwrite", writer, case + ".mes")
    if not os.path.exists(b):
        return ["not written"]
    try:
        return st.compare(a, b)
    except Exception as exc:
        return ["comparator: %s: %s" % (type(exc).__name__, exc)]


def phase_report():
    cases = valid_cases()
    out = {"cross": {}, "golden": {}, "structural": {}}
    for reader in LANGS:
        for writer in list(LANGS) + ["golden"]:
            key = "%s<-%s" % (reader, writer)
            fails = {}
            for c in cases:
                bad = assess(c, load(reader, writer, c))
                if bad:
                    fails[c] = bad
            if writer == "golden":
                out["golden"][reader] = fails
            else:
                out["cross"][key] = fails
    for writer in LANGS:
        fails = {}
        for c in cases:
            d = structural(c, writer)
            if d:
                fails[c] = d
        out["structural"][writer] = fails
    with open(os.path.join(SCRATCH, "report.json"), "w") as fh:
        json.dump(out, fh, indent=1)

    n = len(cases)
    print("cross-write: readers down, writers across (pass of %d)" % n)
    print("%-8s %s" % ("", " ".join("%8s" % NAMES[w] for w in LANGS)))
    for reader in LANGS:
        row = []
        for writer in LANGS:
            row.append("%8d" % (n - len(out["cross"]["%s<-%s" % (reader, writer)])))
        print("%-8s %s" % (NAMES[reader], " ".join(row)))
    print()
    print("baseline, each reader on the golden file (pass of %d)" % n)
    for reader in LANGS:
        print("  %-8s %d" % (NAMES[reader], n - len(out["golden"][reader])))
    print()
    print("structural equality of the written file against the golden")
    for writer in LANGS:
        print("  %-8s %d of %d" % (NAMES[writer],
                                   n - len(out["structural"][writer]), n))
    print()
    for key, fails in sorted(out["cross"].items()):
        for c, bad in sorted(fails.items()):
            for b in bad:
                print("CROSS %-10s %-26s %s" % (key, c, b[:150]))
    for reader, fails in sorted(out["golden"].items()):
        for c, bad in sorted(fails.items()):
            for b in bad:
                print("GOLDEN %-6s %-26s %s" % (reader, c, b[:150]))
    for writer, fails in sorted(out["structural"].items()):
        for c, bad in sorted(fails.items()):
            for b in bad:
                print("STRUCT %-6s %-26s %s" % (writer, c, b[:150]))


EVAL_CASES = ("affine_zero_rows", "affine_with_rows", "callable_two_slots")


def phase_evaluate():
    d = os.path.join(SCRATCH, "eval")
    os.makedirs(d, exist_ok=True)
    specs = {}
    for c in EVAL_CASES:
        e = expected(c)
        for entry in e["evaluation"]:
            p = os.path.join(d, "%s_%s.json" % (c, entry["callable"]))
            with open(p, "w") as fh:
                json.dump({"callable": entry["callable"],
                           "keys": entry["keys"],
                           "probes": entry["probes"]}, fh)
            specs[c] = (p, entry)
    for lang in LANGS:
        os.makedirs(os.path.join(d, lang), exist_ok=True)
        jobs = []
        for c in EVAL_CASES:
            spec, _ = specs[c]
            jobs.append({"op": "evalw", "file": golden(c), "spec": spec,
                         "mes": os.path.join(d, lang, c + ".mes"),
                         "out": os.path.join(d, lang, c + ".json")})
        code = run_batch(lang, jobs, "eval")
        print("%-6s evaluate exit %d" % (lang, code))


def phase_evalcheck():
    """Cross-read the evaluated files, and compare outputs across
    languages bit for bit."""
    d = os.path.join(SCRATCH, "eval")
    print("evaluation outputs, compared against expected.json and "
          "across languages")
    ref = {}
    for c in EVAL_CASES:
        want = [p["value"] for p in expected(c)["evaluation"][0]["probes"]]
        line = []
        for lang in LANGS:
            p = os.path.join(d, lang, c + ".json")
            got = None
            if os.path.exists(p):
                got = json.load(open(p)).get("probes")
            ref[(c, lang)] = got
            if got is None:
                line.append("%s:no result" % lang)
                continue
            bad = [i for i, w in enumerate(want)
                   if compare_probe(w, got[i] if i < len(got) else None)]
            line.append("%s:%d/%d" % (lang, len(want) - len(bad), len(want)))
        print("  %-22s %s" % (c, "  ".join(line)))
        base = ref[(c, "py")]
        for lang in LANGS[1:]:
            other = ref[(c, lang)]
            if base is not None and other is not None and base != other:
                for i, (a, b) in enumerate(zip(base, other)):
                    if a != b:
                        print("    differs from Python at probe %d: %s vs %s"
                              % (i, a, b))

    # now cross-read the written evaluated files
    cases = EVAL_CASES
    for reader in LANGS:
        jobs = []
        for writer in LANGS:
            res = os.path.join(d, "read", reader, writer)
            os.makedirs(res, exist_ok=True)
            for c in cases:
                src = os.path.join(d, writer, c + ".mes")
                if not os.path.exists(src):
                    continue
                jobs.append({"op": "check", "file": src,
                             "probes": probes_file(c),
                             "out": os.path.join(res, c + ".json")})
        run_batch(reader, jobs, "evalread")
    print()
    print("evaluated files: validator outcome when read back "
          "(readers down, writers across)")
    print("%-8s %s" % ("", " ".join("%10s" % NAMES[w] for w in LANGS)))
    for reader in LANGS:
        cells = []
        for writer in LANGS:
            ok = 0
            for c in cases:
                p = os.path.join(d, "read", reader, writer, c + ".json")
                if not os.path.exists(p):
                    continue
                r = json.load(open(p))
                if not r.get("errors") and "failed" not in r:
                    ok += 1
            cells.append("%10s" % ("%d/%d" % (ok, len(cases))))
        print("%-8s %s" % (NAMES[reader], " ".join(cells)))
    for reader in LANGS:
        for writer in LANGS:
            for c in cases:
                p = os.path.join(d, "read", reader, writer, c + ".json")
                if not os.path.exists(p):
                    print("  MISSING %s<-%s %s" % (reader, writer, c))
                    continue
                r = json.load(open(p))
                if r.get("errors"):
                    print("  ERRORS %s<-%s %s: %s"
                          % (reader, writer, c, r["errors"]))
                if "failed" in r:
                    print("  FAILED %s<-%s %s: %s"
                          % (reader, writer, c, str(r["failed"])[:120]))


CODEC_DIR = os.path.join(SCRATCH, "codec")


def shape_of(node):
    """A one-element shape can come back from a language as a scalar."""
    sh = node.get("shape", [])
    if isinstance(sh, (int, float)):
        return [int(sh)]
    return [int(x) for x in sh]


def canon(node):
    """The tagged form with every float replaced by its bits, so that
    a string comparison of two dumps is a bit comparison."""
    import struct
    if not isinstance(node, dict):
        return node
    t = node.get("t")
    if t == "dict":
        return {"t": "dict",
                "v": {k: canon(v) for k, v in sorted(node["v"].items())}}
    if t == "f64":
        return {"t": "f64", "v": bits(node["v"])}
    if t == "array" and node.get("dtype") == "float64":
        return {"t": "array", "dtype": "float64", "shape": shape_of(node),
                "data": [bits(x) for x in listof(node["data"])]}
    if t == "array":
        return {"t": "array", "dtype": node["dtype"],
                "shape": shape_of(node),
                "data": [bool(x) if node["dtype"] == "bool" else int(x)
                         for x in listof(node["data"])]}
    if t == "strings":
        return {"t": "strings", "shape": shape_of(node),
                "data": [str(x) for x in listof(node["data"])]}
    return node


def listof(v):
    if v is None:
        return []
    if isinstance(v, (list, tuple)):
        return list(v)
    return [v]


def bits(text):
    import struct
    if isinstance(text, (int, float)):
        text = "%.17e" % float(text)
    if text in ("nan", "inf", "-inf"):
        return text
    return struct.pack("<d", float(text)).hex()


def dumps(node):
    return json.dumps(node, sort_keys=True, separators=(",", ":"))


def phase_codec():
    os.makedirs(CODEC_DIR, exist_ok=True)
    src = os.path.join(CODEC_DIR, "source.mes")
    ref = os.path.join(CODEC_DIR, "reference.json")
    if not os.path.exists(src):
        subprocess.run([PY, os.path.join(HERE, "codec_source.py"), src, ref],
                       check=True, cwd=REPO)
    for lang in LANGS:
        jobs = [{"op": "write", "src": src,
                 "dst": os.path.join(CODEC_DIR, lang + ".mes"),
                 "out": os.path.join(CODEC_DIR, lang + ".write.json")}]
        code = run_batch(lang, jobs, "codecwrite")
        print("%-6s write exit %d, file %s" % (
            lang, code,
            "yes" if os.path.exists(os.path.join(CODEC_DIR, lang + ".mes"))
            else "NO"))
    for reader in LANGS:
        jobs = []
        for writer in list(LANGS) + ["source"]:
            f = os.path.join(CODEC_DIR, writer + ".mes")
            if not os.path.exists(f):
                continue
            d = os.path.join(CODEC_DIR, "dump", reader)
            os.makedirs(d, exist_ok=True)
            jobs.append({"op": "codec", "file": f,
                         "out": os.path.join(d, writer + ".json")})
        run_batch(reader, jobs, "codecdump")


def phase_codecreport():
    ref = canon(json.load(open(os.path.join(CODEC_DIR, "reference.json"))))
    want = dumps(ref)
    print("codec: every leaf of section 17, written by each language "
          "and read by each")
    print("rows are readers, columns writers; `src` is the file built "
          "from the spec")
    cols = list(LANGS) + ["source"]
    print("%-8s %s" % ("", " ".join("%8s" % c for c in cols)))
    bad = []
    for reader in LANGS:
        cells = []
        for writer in cols:
            p = os.path.join(CODEC_DIR, "dump", reader, writer + ".json")
            if not os.path.exists(p):
                cells.append("%8s" % "-")
                bad.append((reader, writer, "no dump"))
                continue
            d = json.load(open(p))
            if "failed" in d or "m1" not in d:
                cells.append("%8s" % "fail")
                bad.append((reader, writer, str(d)[:200]))
                continue
            got = dumps(canon(d["m1"]["dict"]))
            if got == want:
                cells.append("%8s" % "same")
            else:
                cells.append("%8s" % "DIFF")
                bad.append((reader, writer, diff_tagged(ref,
                                                        canon(d["m1"]["dict"]))))
        print("%-8s %s" % (NAMES[reader], " ".join(cells)))
    for reader, writer, why in bad:
        print("  %s reading %s: %s" % (NAMES.get(reader, reader), writer,
                                       str(why)[:400]))


def diff_tagged(a, b, path="."):
    out = []
    if isinstance(a, dict) and a.get("t") == "dict" and \
            isinstance(b, dict) and b.get("t") == "dict":
        for k in sorted(set(a["v"]) | set(b["v"])):
            if k not in a["v"]:
                out.append("%s/%s only in the read-back" % (path, k))
            elif k not in b["v"]:
                out.append("%s/%s missing from the read-back" % (path, k))
            else:
                out += diff_tagged(a["v"][k], b["v"][k], "%s/%s" % (path, k))
        return out
    if dumps(a) != dumps(b):
        out.append("%s: %s vs %s" % (path, dumps(a)[:120], dumps(b)[:120]))
    return out


def phase_determinism():
    cases = valid_cases()
    import hashlib
    for lang in LANGS:
        d1 = os.path.join(SCRATCH, "det", lang, "a")
        d2 = os.path.join(SCRATCH, "det", lang, "b")
        os.makedirs(d1, exist_ok=True)
        os.makedirs(d2, exist_ok=True)
        jobs = []
        for c in cases:
            for out in (d1, d2):
                jobs.append({"op": "write", "src": golden(c),
                             "dst": os.path.join(out, c + ".mes"),
                             "out": os.path.join(out, c + ".w.json")})
        run_batch(lang, jobs, "det")
        same = diff = missing = 0
        names = []
        for c in cases:
            a = os.path.join(d1, c + ".mes")
            b = os.path.join(d2, c + ".mes")
            if not (os.path.exists(a) and os.path.exists(b)):
                missing += 1
                continue
            ha = hashlib.sha256(open(a, "rb").read()).hexdigest()
            hb = hashlib.sha256(open(b, "rb").read()).hexdigest()
            if ha == hb:
                same += 1
            else:
                diff += 1
                names.append(c)
        print("%-8s identical %d, different %d, missing %d  %s"
              % (NAMES[lang], same, diff, missing, names[:6]))


def main(argv):
    phase = argv[1] if len(argv) > 1 else "report"
    {"write": phase_write, "check": phase_check, "report": phase_report,
     "evaluate": phase_evaluate, "evalcheck": phase_evalcheck,
     "codec": phase_codec, "codecreport": phase_codecreport,
     "determinism": phase_determinism}[phase]()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
