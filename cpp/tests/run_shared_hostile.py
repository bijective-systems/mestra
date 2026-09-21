#!/usr/bin/env python3
"""Run the corpus's own hostile subset, vectors/hostile.

Section 30 gives this subset a looser contract than the corpus's: the
required rule identifiers must appear, more are allowed, and the run
must finish cleanly inside the timeout the case states. Opening the
file for its metadata alone, and any operation that reads a slot, must
refuse with the same identifiers rather than return something.

    python3 run_shared_hostile.py --cli ../build/mestra-cli \
                                  --vectors ../../vectors

Two of the files are generated rather than committed, because they are
31 MB each. Run this first:

    python3 vectors/generate.py --on-demand

A case whose file is missing is reported and the run fails, rather
than being passed over quietly.
"""

import argparse
import json
import os
import re
import subprocess
import sys

# A finding, in the form docs/api-conventions.md section 5 fixes:
# "<id> <path>: <message>".  A "! " line carries no identifier and is
# not one.
FINDING = re.compile(r"^([EW][0-9]{2}) (\S+): (.*)$")


def ids_from(text):
    """The rule identifiers the tool printed."""
    out = set()
    for line in text.splitlines():
        match = FINDING.match(line)
        if match:
            out.add(match.group(1))
    return out


def run(cli, command, path, timeout):
    try:
        done = subprocess.run([cli, command, path], capture_output=True,
                              text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "", ""
    return done.returncode, done.stdout, done.stderr


def check(cli, directory, name, problems):
    case = os.path.join(directory, name)
    with open(os.path.join(case, "expected.json"), encoding="utf-8") as fh:
        expected = json.load(fh)
    required = set(expected["required_errors"])
    timeout = expected["timeout_seconds"]
    path = os.path.join(case, "case.mes")
    if not os.path.exists(path):
        problems.append("%s: case.mes is not there; run "
                        "`python vectors/generate.py --on-demand`"
                        % (name,))
        return

    for command in ("validate", "info", "read"):
        code, out, err = run(cli, command, path, timeout)
        if code is None:
            problems.append("%s: %s did not finish within %d seconds"
                            % (name, command, timeout))
            continue
        if code < 0:
            problems.append("%s: %s was killed by signal %d"
                            % (name, command, -code))
            continue
        if code not in (0, 1):
            problems.append("%s: %s exited %d, which is neither an answer "
                            "nor a refusal" % (name, command, code))
            continue
        found = ids_from(out)
        missing = sorted(required - found)
        if missing:
            problems.append("%s: %s reported %s and not %s"
                            % (name, command,
                               ",".join(sorted(found)) or "nothing",
                               ",".join(missing)))
            continue
        # `allow_extra` is true throughout the subset, so more is fine.
        if command != "validate" and code != 1:
            problems.append("%s: %s returned something instead of refusing"
                            % (name, command))
        if command != "validate" and not (out.strip() or err.strip()):
            problems.append("%s: %s refused and said nothing" % (name,
                                                                 command))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True,
                        help="the mestra-cli executable")
    parser.add_argument("--vectors", required=True,
                        help="the vectors/ directory of the corpus")
    arguments = parser.parse_args(argv[1:])

    directory = os.path.join(arguments.vectors, "hostile")
    names = sorted(n for n in os.listdir(directory)
                   if os.path.isdir(os.path.join(directory, n)))
    problems = []
    for name in names:
        check(arguments.cli, directory, name, problems)

    print("shared hostile cases %d" % len(names))
    print("commands run         %d" % (len(names) * 3))
    if problems:
        print("\n%d problems:" % len(problems))
        for problem in problems:
            print("  " + problem)
        return 1
    print("\nevery case refused with at least the identifiers it requires")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
