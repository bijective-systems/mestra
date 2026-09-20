"""The command line: `mestra validate FILE` and `mestra info FILE`.

    $ mestra validate run.mes
    run.mes: no error and no warning

    $ mestra info run.mes
    ... one screen: the keys with their roles and bounds, the
    supports with their ids, every slot with its shape, units and
    source, and the callables with their types.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from typing import Any

from .errors import MestraError
from .model import ArraySlot, Dataset
from .reader import read
from .validator import validate

__all__ = ["main"]


def main(argv: Sequence[str] | None = None) -> int:
    """Run the command line. Returns the exit status."""
    parser = argparse.ArgumentParser(
        prog="mestra", description="Read and check mestra files.")
    commands = parser.add_subparsers(dest="command")
    check = commands.add_parser(
        "validate", help="report every rule of section 14 a file "
                         "breaks")
    check.add_argument("file", nargs="+")
    check.add_argument("--quiet", action="store_true",
                       help="print the summary line only")
    show = commands.add_parser(
        "info", help="one screen about a file")
    show.add_argument("file", nargs="+")
    args = parser.parse_args(list(argv) if argv is not None
                             else sys.argv[1:])
    if args.command == "validate":
        return _validate(args.file, args.quiet)
    if args.command == "info":
        return _info(args.file)
    parser.print_help()
    return 2


def _validate(paths: Sequence[str], quiet: bool) -> int:
    status = 0
    for path in paths:
        try:
            report = validate(path)
        except (OSError, MestraError) as exc:
            print("%s: cannot be read: %s" % (path, exc))
            status = 1
            continue
        if not quiet:
            for finding in report.findings:
                print("  %s" % finding)
        if report.errors or report.unclassified:
            status = 1
            print("%s: %d error(s), %d warning(s), %d unclassified: %s"
                  % (path, len(report.errors), len(report.warnings),
                     len(report.unclassified),
                     " ".join(report.error_ids + report.warning_ids)))
        elif report.warnings:
            print("%s: valid, %d warning(s): %s"
                  % (path, len(report.warnings),
                     " ".join(report.warning_ids)))
        else:
            print("%s: no error and no warning" % path)
    return status


def _info(paths: Sequence[str]) -> int:
    status = 0
    for at, path in enumerate(paths):
        if at:
            print("")
        try:
            with read(path) as ds:
                _print_dataset(path, ds)
        except (OSError, MestraError) as exc:
            print("%s: cannot be read: %s" % (path, exc))
            status = 1
    return status


def _print_dataset(path: str, ds: Dataset) -> None:
    print(path)
    for finding in ds.problems:
        print("  %s" % finding)
    print("  %s written by %r on %s" % (ds.format, ds.writer,
                                        ds.created))
    line = "  %d row(s), %s" % (
        ds.n_rows, "aligned" if ds.aligned else "not aligned")
    if ds.generalisation_group:
        line += ", generalisation unit %s" % ds.generalisation_group
    print(line)

    if ds.keys:
        print("  keys")
        for name in ds.key_names():
            key = ds.keys[name]
            print("    %-16s %-12s %s" % (name, key.role,
                                          _key_detail(ds, key)))
    if ds.scalars:
        print("  scalars")
        for name in sorted(ds.scalars):
            slot = ds.scalars[name]
            print("    %-16s (row)%s %s" % (
                name, " " * 26, _slot_detail(slot)))
    for sname in ds.support_names():
        support = ds.supports[sname]
        print("  support %s  %s, %d node(s), %d cell(s)"
              % (sname, support.kind, support.n_nodes, support.n_cells))
        print("    id %s" % support.support_id)
        for where, array in support.arrays().items():
            print("    %-16s %-30s %s"
                  % (where.rsplit("/", 1)[-1], _dims(array),
                     _slot_detail(array)))
    if ds.callables:
        print("  callables")
        for name in sorted(ds.callables):
            obj = ds.callables[name]
            print("    %-16s %-12s %s"
                  % (name, getattr(obj, "type", "?"), repr(obj)))
    if ds.notes:
        print("  notes")
        for name in sorted(ds.notes):
            print("    %-16s %s" % (name, ds.notes[name]))


def _key_detail(ds: Dataset, key: Any) -> str:
    out = []
    if key.units:
        out.append("units %s" % key.units)
    if key.lower is not None or key.upper is not None:
        out.append("bounds [%s, %s]" % (key.lower, key.upper))
    if key.category:
        table = ds.categories.get(key.category)
        entries = ", ".join(table[:4]) if table else "?"
        if table and len(table) > 4:
            entries += ", ..."
        out.append("categories %s (%s)" % (key.category, entries))
    if key.trajectory_group:
        out.append("trajectory %s" % key.trajectory_group)
    return "  ".join(out)


def _dims(slot: ArraySlot) -> str:
    shape = ""
    if slot.data is not None:
        shape = "x".join(str(n) for n in slot.data.shape)
    return "(%s) %s" % (", ".join(slot.dims), shape)


def _slot_detail(slot: Any) -> str:
    out = []
    role = getattr(slot, "role", "scalar")
    out.append(role)
    if slot.units:
        out.append("units %s" % slot.units)
    out.append(slot.source)
    if slot.output:
        out.append("output %s" % slot.output)
    if slot.statistic:
        out.append("statistic %s" % slot.statistic)
    if slot.of:
        out.append("of %s" % slot.of)
    return "  ".join(out)


if __name__ == "__main__":                           # pragma: no cover
    sys.exit(main())
