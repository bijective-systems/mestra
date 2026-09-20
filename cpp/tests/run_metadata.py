#!/usr/bin/env python3
"""The metadata open against the whole read, file by file.

docs/api-conventions.md section 7: a metadata open reads attributes,
dataspaces, link types and dimension-scale structure, and of datasets
only a category table in full (and `/row_support`, which is the other
dataset that is not a slot); it never reads a slot's data and never a
dataset inside a callable's dictionary.  The nine structural rules are
decided from exactly that, so the open and the read name the same rule
for the same file.

This checks that claim on every file there is: the whole conformance
corpus, its hostile subset, and this implementation's own hostile
files.  For each one, two things must hold.

  - The open invents nothing: every identifier the restricted pass
    names, the whole pass names too.  A pass that decided a rule from
    an array it never read would say E23 of a mesh that is not wrong
    and E08 of every support in the file, so this is the check that
    matters.
  - The two passes name the same structural rules, which are the nine
    a strict read refuses on -- E01, E16, E19, E25, E26, E29, E30,
    E40, E41 -- so that `read_header` and `read` agree about every
    file, and `info` with them.

    python3 run_metadata.py --cli ../build/mestra-cli --vectors ../../vectors

Nothing here is a mestra implementation; it drives `mestra-cli`.
"""

import argparse
import os
import re
import subprocess
import sys

FINDING = re.compile(r"^([EW]) ([EW][0-9]{2})$")

# The rules a strict read refuses on (docs/api-conventions.md section
# 2), which are the ones the open must agree with the read about.
STRUCTURAL = ("E01", "E16", "E19", "E25", "E26", "E29", "E30", "E40",
              "E41")

TIMEOUT_SECONDS = 120


def ids(cli, path, metadata):
    command = [cli, "validate", "--ids"]
    if metadata:
        command.append("--metadata")
    command.append(path)
    done = subprocess.run(command, capture_output=True, text=True,
                          timeout=TIMEOUT_SECONDS)
    errors = set()
    warnings = set()
    for line in done.stdout.splitlines():
        match = FINDING.match(line)
        if match is None:
            continue
        (warnings if match.group(1) == "W" else errors).add(match.group(2))
    return errors, warnings


def files(vectors, own):
    out = []
    for group in ("cases", "hostile"):
        directory = os.path.join(vectors, group)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            case = os.path.join(directory, name, "case.mes")
            if os.path.exists(case):
                out.append(case)
    if os.path.isdir(own):
        for name in sorted(os.listdir(own)):
            if name.endswith(".mes"):
                out.append(os.path.join(own, name))
    return out


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--vectors", required=True)
    arguments = parser.parse_args(argv[1:])
    own = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "hostile")

    paths = files(arguments.vectors, own)
    if not paths:
        print("no files to compare under %s" % arguments.vectors)
        return 1

    problems = []
    for path in paths:
        name = os.path.relpath(path, os.path.dirname(arguments.vectors))
        whole_e, whole_w = ids(arguments.cli, path, False)
        open_e, open_w = ids(arguments.cli, path, True)

        invented = (open_e - whole_e) | (open_w - whole_w)
        if invented:
            problems.append(
                "%s: the metadata open names %s, which the whole read does "
                "not" % (name, ", ".join(sorted(invented))))

        mine = set(i for i in open_e if i in STRUCTURAL)
        theirs = set(i for i in whole_e if i in STRUCTURAL)
        if mine != theirs:
            problems.append(
                "%s: the open refuses on %s and the read on %s"
                % (name, ", ".join(sorted(mine)) or "nothing",
                   ", ".join(sorted(theirs)) or "nothing"))

    print("files compared       %d" % len(paths))
    if problems:
        print("\n%d problems:" % len(problems))
        for problem in problems:
            print("  " + problem)
        return 1
    print("\nthe metadata open invents nothing and refuses on exactly what "
          "the read refuses on")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
