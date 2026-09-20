"""Phase 3 verification driver for the C++ implementation.

The C++ side has no JSON, so this wrapper drives `mestra-cli` and
speaks the same JSON as the other three drivers. It is a wrapper and
nothing else: every answer comes out of the tool.

  cppdrv.py CLI check FILE PROBES.json
  cppdrv.py CLI write IN.mes OUT.mes
  cppdrv.py CLI eval  FILE SPEC.json
  cppdrv.py CLI evalw FILE SPEC.json OUT.mes
  cppdrv.py CLI codec FILE
"""

from __future__ import annotations

import csv
import json
import os
import subprocess
import sys
import tempfile

AXES = ("row", "instance", "draw", "node", "cell", "cell_plus_one",
        "component", "index")
TIMEOUT = 60


def run(cli, *args, timeout=TIMEOUT):
    p = subprocess.run([cli, *args], capture_output=True, text=True,
                       timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def do_check(cli, path, probes_path):
    out = {"errors": [], "warnings": [], "support_ids": {}, "probes": [],
           "trouble": []}
    code, so, se = run(cli, "validate", path)
    for line in so.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "E":
            out["errors"].append(parts[1])
        elif len(parts) >= 2 and parts[0] == "W":
            out["warnings"].append(parts[1])
        elif line.strip():
            out["trouble"].append("validate: " + line.strip())
    if se.strip():
        out["trouble"].append("validate stderr: " + se.strip()[:200])
    out["errors"] = sorted(set(out["errors"]))
    out["warnings"] = sorted(set(out["warnings"]))

    code, so, se = run(cli, "info", path)
    names = [ln.split()[1] for ln in so.splitlines() if ln.startswith("support ")]
    for name in names:
        code, so2, se2 = run(cli, "support-id", path, name)
        if code == 0 and so2.strip():
            out["support_ids"][name] = so2.strip()
        else:
            out["trouble"].append("support-id %s: %s" % (name, se2.strip()[:120]))

    probes = json.load(open(probes_path))
    for p in probes:
        args = ["probe", path, p["slot"]]
        args += ["%s=%d" % (a, p[a]) for a in AXES if a in p]
        code, so2, se2 = run(cli, *args)
        if code == 0 and so2.strip():
            out["probes"].append(so2.strip())
        else:
            out["probes"].append(None)
            out["trouble"].append("probe %s: %s" % (p["slot"],
                                                    (se2 or so2).strip()[:200]))
    return out


def do_write(cli, src, dst):
    code, so, se = run(cli, "roundtrip", src, dst)
    if code != 0:
        raise SystemExit("roundtrip failed: %s %s" % (so.strip(), se.strip()))
    return {"ok": True}


def do_eval(cli, path, spec_path, out_path=None):
    spec = json.load(open(spec_path))
    names = sorted(spec["keys"])
    nrows = len(spec["keys"][names[0]])
    tmp = tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False,
                                      newline="")
    w = csv.writer(tmp)
    w.writerow(names)
    for i in range(nrows):
        w.writerow([spec["keys"][n][i] for n in names])
    tmp.close()
    keep = out_path or tempfile.mktemp(suffix=".mes")
    out = {"probes": [], "trouble": []}
    code, so, se = run(cli, "evaluate", path, tmp.name, keep)
    if code != 0:
        out["trouble"].append("evaluate: %s %s" % (so.strip(), se.strip()))
        out["probes"] = [None] * len(spec["probes"])
        return out
    for p in spec["probes"]:
        args = ["probe", keep, p["slot"]]
        args += ["%s=%d" % (a, p[a]) for a in AXES if a in p]
        code, so2, se2 = run(cli, *args)
        if code == 0 and so2.strip():
            out["probes"].append(so2.strip())
        else:
            out["probes"].append(None)
            out["trouble"].append("probe %s: %s" % (p["slot"],
                                                    (se2 or so2).strip()[:200]))
    os.unlink(tmp.name)
    if out_path is None and os.path.exists(keep):
        os.unlink(keep)
    return out


def unescape(text):
    """The dump escapes anything outside printable ASCII, and `%`."""
    out = bytearray()
    i = 0
    while i < len(text):
        if text[i] == "%":
            if i + 2 < len(text) and all(
                    c in "0123456789abcdefABCDEF" for c in text[i + 1:i + 3]):
                out.append(int(text[i + 1:i + 3], 16))
                i += 3
                continue
            i += 1
            continue
        out.append(ord(text[i]))
        i += 1
    return out.decode("utf-8", "replace")


def parse_dump(lines):
    """The `dict-dump` lines back into the tagged form of section 30."""
    root = {"t": "dict", "v": {}}

    def place(path, value):
        parts = [p for p in path.split("/")[1:] if p != ""]
        node = root
        for part in parts[:-1]:
            node = node["v"][unescape(part)]
        node["v"][unescape(parts[-1])] = value

    for line in lines:
        if not line.strip():
            continue
        fields = line.split(" ")
        kind, path = fields[0], fields[1]
        rest = fields[2:]
        if kind == "D":
            if path == ".":
                continue
            place(path, {"t": "dict", "v": {}})
        elif kind == "N":
            place(path, {"t": "null"})
        elif kind == "B":
            place(path, {"t": "bool", "v": rest[0] == "1"})
        elif kind == "I":
            place(path, {"t": "i64", "v": int(rest[0])})
        elif kind == "F":
            place(path, {"t": "f64", "v": rest[0]})
        elif kind == "S":
            place(path, {"t": "str", "v": unescape(rest[0]) if rest else ""})
        elif kind == "A":
            dtype = rest[0]
            rank = int(rest[1])
            shape = [int(x) for x in rest[2:2 + rank]]
            data = rest[2 + rank:]
            if dtype == "float64":
                values = list(data)
            elif dtype == "int8":
                dtype = "bool"
                values = [x == "1" for x in data]
            else:
                values = [int(x) for x in data]
            place(path, {"t": "array", "dtype": dtype, "shape": shape,
                         "data": values})
        elif kind == "T":
            rank = int(rest[0])
            shape = [int(x) for x in rest[1:1 + rank]]
            data = [unescape(x) for x in rest[1 + rank:]]
            place(path, {"t": "strings", "shape": shape, "data": data})
        else:
            raise ValueError("unknown dump kind %r" % kind)
    return root


def do_codec(cli, path):
    code, so, se = run(cli, "info", path)
    ids = []
    code, so2, se2 = run(cli, "dict-dump", path, "?")
    # `info` does not list callables, so read the ids from the file.
    import h5py
    with h5py.File(path, "r") as f:
        if "callables" in f:
            ids = sorted(f["callables"].keys())
            types = {i: f["callables"][i].attrs.get("type") for i in ids}
    out = {}
    for i in ids:
        code, so3, se3 = run(cli, "dict-dump", path, i)
        if code != 0:
            out[i] = {"type": None, "dict": None,
                      "trouble": (se3 or so3).strip()[:200]}
            continue
        t = types.get(i)
        if isinstance(t, bytes):
            t = t.decode()
        out[i] = {"type": t, "dict": parse_dump(so3.splitlines())}
    return out


def run_job(cli, job):
    op = job["op"]
    if op == "check":
        return do_check(cli, job["file"], job["probes"])
    if op == "write":
        return do_write(cli, job["src"], job["dst"])
    if op == "eval":
        return do_eval(cli, job["file"], job["spec"])
    if op == "evalw":
        return do_eval(cli, job["file"], job["spec"], job["mes"])
    if op == "codec":
        return do_codec(cli, job["file"])
    raise ValueError("unknown op %s" % op)


def do_batch(cli, jobs_path):
    jobs = json.load(open(jobs_path))
    for job in jobs:
        try:
            result = run_job(cli, job)
        except Exception as exc:
            result = {"failed": "%s: %s" % (type(exc).__name__, exc)}
        with open(job["out"], "w") as fh:
            json.dump(result, fh)
    return {"jobs": len(jobs)}


def main(argv):
    cli, mode = argv[1], argv[2]
    if mode == "batch":
        result = do_batch(cli, argv[3])
    elif mode == "check":
        result = do_check(cli, argv[3], argv[4])
    elif mode == "write":
        result = do_write(cli, argv[3], argv[4])
    elif mode == "eval":
        result = do_eval(cli, argv[3], argv[4])
    elif mode == "evalw":
        result = do_eval(cli, argv[3], argv[4], argv[5])
    elif mode == "codec":
        result = do_codec(cli, argv[3])
    else:
        raise SystemExit("unknown mode %s" % mode)
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
