"""Run the MATLAB timing driver on a list of files.

    time_ml.py MATLAB MATLAB_DIR SLOT R0 R1 FILE [FILE ...]

A thin wrapper: it builds the one-line `-batch` call for
`timeMestra.m` and prints what MATLAB prints, so that the four
languages are driven the same way from the shell. R1 may be `-` for
the row count.
"""

from __future__ import annotations

import os
import subprocess
import sys

TIMEOUT = 28800


def main(argv):
    matlab, mdir, slot, r0, r1 = argv[1:6]
    files = argv[6:]
    here = os.path.dirname(os.path.abspath(__file__))
    args = ", ".join("'%s'" % f for f in files)
    code = ("addpath('%s'); addpath('%s'); timeMestra('%s', %s, %s, %s)"
            % (mdir, here, slot, r0, "-1" if r1 == "-" else r1, args))
    # Line by line, not captured and printed at the end: a sweep over
    # the larger files takes long enough that a caller needs to see it
    # get there.
    p = subprocess.Popen([matlab, "-nodisplay", "-batch", code],
                         stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    for line in p.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
    return p.wait()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
