#!/usr/bin/env python3
"""Run the hostile corpus: every file under tests/hostile/ through
`validate`, `info` and `read`.

These files are not conformance cases and this script checks nothing
about what they mean.  It checks the one thing a reader of an open
format owes anybody who hands it a file: that the answer is an answer.
For each file and each command:

  - the tool exits, within a timeout: never a hang;
  - it exits with a status and not a signal: never a crash;
  - `validate` comes back with at least one finding, on a line in the
    form "<id> <path>: <message>" or "! <path>: <why>";
  - `info` and `read` either succeed or fail with a message, and say
    which file and why.

    python3 run_hostile.py --cli ../build/mestra-cli [--dir hostile]

tests/hostile/make_hostile.py writes the files and says how each one
was made.
"""

import argparse
import os
import re
import subprocess
import sys

FINDING = re.compile(r"^([EW][0-9]{2}|!) (\S+): (.*)$")

# Long enough that a slow machine under a sanitizer is not mistaken
# for a hang, short enough that a hang is not mistaken for patience.
TIMEOUT_SECONDS = 120


def run(cli, command, path):
    try:
        done = subprocess.run([cli, command, path], capture_output=True,
                              text=True, timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return None, "", ""
    return done.returncode, done.stdout, done.stderr


def check(cli, path, problems):
    name = os.path.basename(path)
    for command in ("validate", "info", "read"):
        code, out, err = run(cli, command, path)
        if code is None:
            problems.append("%s: %s did not finish within %d seconds"
                            % (name, command, TIMEOUT_SECONDS))
            continue
        if code < 0:
            problems.append("%s: %s was killed by signal %d"
                            % (name, command, -code))
            continue
        if code not in (0, 1):
            problems.append("%s: %s exited %d, which is neither a clean "
                            "answer nor a refusal" % (name, command, code))
            continue
        if command == "validate":
            findings = [line for line in out.splitlines()
                        if FINDING.match(line)]
            if not findings:
                problems.append("%s: validate found nothing to say"
                                % (name,))
        elif code == 1 and not (out.strip() or err.strip()):
            problems.append("%s: %s refused the file and said nothing"
                            % (name, command))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True,
                        help="the mestra-cli executable")
    parser.add_argument("--dir", default=None,
                        help="the directory of hostile files")
    arguments = parser.parse_args(argv[1:])

    directory = arguments.dir or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "hostile")
    names = sorted(n for n in os.listdir(directory) if n.endswith(".mes"))
    if not names:
        print("no hostile files under %s" % directory)
        return 1

    problems = []
    for name in names:
        check(arguments.cli, os.path.join(directory, name), problems)

    print("hostile files        %d" % len(names))
    print("commands run         %d" % (len(names) * 3))
    if problems:
        print("\n%d problems:" % len(problems))
        for problem in problems:
            print("  " + problem)
        return 1
    print("\nevery file answered for, none crashed and none hung")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
