"""Where the Python reader spends the time.

    profile_py.py PACKAGE_DIR open|validate FILE [TOP]

Runs the operation once under cProfile and prints the functions with
the largest total time, with the call counts beside them, which is
what says whether a function is being called once per dataset or once
per dataset per dataset.
"""

from __future__ import annotations

import cProfile
import pstats
import sys


def main(argv):
    pkg, op, path = argv[1], argv[2], argv[3]
    top = int(argv[4]) if len(argv) > 4 else 15
    sys.path.insert(0, pkg)
    import mestra

    if op == "open":
        fn = lambda: mestra.read(path)             # noqa: E731
    elif op == "validate":
        fn = lambda: mestra.validate(path)         # noqa: E731
    else:
        raise SystemExit("open or validate")

    pr = cProfile.Profile()
    pr.enable()
    fn()
    pr.disable()
    stats = pstats.Stats(pr)
    stats.sort_stats("tottime").print_stats(top)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
