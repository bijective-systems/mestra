#!/usr/bin/env python3
"""Run the C++ port of each worked example and compare what it prints
to the "Expected output" block of the README beside it.

    python3 run_examples.py --bin-dir ../build/examples \\
                            --examples ../../docs/examples

The README is the contract: it states the toy data and the output, in
one place, for all four languages.  So this script reads the block out
of the README rather than holding a copy, and a change to this API
that the documents did not follow fails here.

Each program runs in a directory of its own, because most of them
write a file and read it back; nothing is left behind.

Two examples do not print the whole block, and the reason is in
DIFFERENCES below, beside the lines it applies to.  A difference has
to be written down here to be allowed: anything else is a failure.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

# What the C++ program prints instead of the README's block, and why.
# `lines` is how many of the block's lines it prints at all, and
# `replace` gives the text of a line it prints differently, by index.
DIFFERENCES = {
    "groups-and-splits": {
        # C++ has no `grouped_split`, by the decision cpp/README.md
        # states, so the two lines that show a split are not printed.
        # What the format itself decides -- the declared unit of
        # generalisation, and whether the stored split leaks one -- is.
        "lines": 2,
    },
    "validating": {
        # The builder refusal names the object path, `/scalars/cl`, as
        # every other C++ builder message does, and names the argument
        # the way C++ has arguments.  Python's `cl` and `units=` are
        # that language's spelling of the same refusal, under the same
        # rule identifier, which is what conventions section 6 fixes.
        "replace": {
            0: 'refused: E11: /scalars/cl: a scalar carries units; '
               'pass units ("1" for a dimensionless one)',
        },
    },
}

# The one example that reads a committed file rather than writing one.
ARGUMENTS = {
    "reading-someone-elses-file": ["../mesh_two_rows.mes"],
}


def expected_block(readme):
    """The indented block under the "Expected output" heading."""
    lines = readme.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "Expected output" and lines[i + 1].startswith("---"):
            break
    else:
        raise SystemExit("no Expected output heading")
    out = []
    for line in lines[i + 2:]:
        if line.startswith("    "):
            out.append(line[4:])
        elif not line.strip():
            if out:
                break
        else:
            break
    return out


def expected_for(name, block):
    difference = DIFFERENCES.get(name, {})
    out = list(block[:difference.get("lines", len(block))])
    for index, text in difference.get("replace", {}).items():
        out[index] = text
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bin-dir", required=True)
    p.add_argument("--examples", required=True)
    args = p.parse_args()

    names = sorted(d for d in os.listdir(args.examples)
                   if os.path.isfile(os.path.join(args.examples, d, "cpp.cpp")))
    if not names:
        raise SystemExit("no examples found under " + args.examples)

    failures = 0
    for name in names:
        directory = os.path.join(args.examples, name)
        with open(os.path.join(directory, "README.md"), encoding="utf-8") as f:
            block = expected_block(f.read())
        want = expected_for(name, block)

        binary = os.path.join(args.bin_dir, name)
        arguments = [os.path.abspath(os.path.join(directory, a))
                     for a in ARGUMENTS.get(name, [])]
        work = tempfile.mkdtemp(prefix="mestra-example-")
        try:
            run = subprocess.run([os.path.abspath(binary)] + arguments,
                                 cwd=work, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, timeout=300)
        finally:
            shutil.rmtree(work, ignore_errors=True)

        got = run.stdout.decode("utf-8").splitlines()
        if run.returncode != 0:
            print("FAIL %s: exit %d\n%s"
                  % (name, run.returncode, run.stderr.decode("utf-8")))
            failures += 1
        elif got != want:
            print("FAIL %s: output is not the README's" % name)
            for line in want:
                print("  want: " + line)
            for line in got:
                print("  got:  " + line)
            failures += 1
        else:
            note = " (a stated difference)" if name in DIFFERENCES else ""
            print("ok   %s: %d line(s)%s" % (name, len(got), note))

    print("%d example(s), %d failed" % (len(names), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
