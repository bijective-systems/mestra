#!/usr/bin/env python3
"""Name, for CMake, the two paths an activated conda-forge environment has.

The C++ build wants `HDF5_ROOT`, the prefix `find_package(HDF5)` searches
for `hdf5.h`, `hdf5_hl.h` and the libraries beside them, and it wants
`Python3_EXECUTABLE`, the interpreter the conformance drivers of
`cpp/tests` run under, which has to be the one with h5py in it.  Neither
is in the same place on all three runners: a conda-forge environment puts
its headers and libraries under `Library/` on Windows and directly under
the prefix everywhere else, and its interpreter is `python.exe` at the
top of the prefix on Windows and `bin/python` under it everywhere else.

So this works the prefix out once, checks that the four things the build
actually opens are there, and writes the two paths into `$GITHUB_ENV` as
`HDF5_ROOT` and `MESTRA_PYTHON`.

    python .github/scripts/hdf5_env.py [environment-name]

When it cannot find something it says what it looked for and lists what
is there instead, and exits 1.  That is the whole point of it: the
alternative is a `find_package(HDF5 REQUIRED)` failure three steps later,
which names neither the prefix it searched nor what was in it.
"""

import os
import sys


def prefix(environment):
    """The environment's prefix, however the shell was initialised.

    `micromamba activate` sets CONDA_PREFIX.  When a runner's shell has
    not been initialised the way the job expects, MAMBA_ROOT_PREFIX and
    the environment's name still give the answer, so try that before
    giving up: a missing activation is worth reporting as itself rather
    than as a missing header.
    """
    found = os.environ.get("CONDA_PREFIX")
    if found:
        return found, "CONDA_PREFIX"
    root = os.environ.get("MAMBA_ROOT_PREFIX")
    if root and environment:
        return os.path.join(root, "envs", environment), \
            "MAMBA_ROOT_PREFIX/envs/%s" % environment
    return None, None


def listing(directory, limit=40):
    """What is in a directory, for a message that has to explain itself."""
    try:
        names = sorted(os.listdir(directory))
    except OSError as exc:
        return "    (cannot be listed: %s)" % exc
    if not names:
        return "    (empty)"
    shown = names[:limit]
    out = "    " + ", ".join(shown)
    if len(names) > limit:
        out += ", and %d more" % (len(names) - limit)
    return out


def hdf5_root(base):
    """The prefix that holds `include/hdf5.h`, Windows or not."""
    candidates = [base, os.path.join(base, "Library")]
    for candidate in candidates:
        header = os.path.join(candidate, "include", "hdf5.h")
        if os.path.isfile(header):
            return candidate, candidates
    return None, candidates


def interpreter(base):
    """The environment's own python, Windows or not."""
    candidates = [os.path.join(base, "bin", "python"),
                  os.path.join(base, "python.exe"),
                  os.path.join(base, "bin", "python3")]
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate, candidates
    return None, candidates


def libraries(root):
    """The library files under a prefix, for the report.

    This does not decide anything -- CMake's FindHDF5 has its own rules
    and its own names for these on each platform.  It is here so that a
    build that fails to link says what was there to link against.
    """
    out = []
    for where in ("lib", "bin", os.path.join("lib", "x64")):
        directory = os.path.join(root, where)
        if not os.path.isdir(directory):
            continue
        try:
            names = sorted(n for n in os.listdir(directory)
                           if n.startswith("libhdf5") or
                           n.startswith("hdf5"))
        except OSError:
            continue
        if names:
            out.append((directory, names))
    return out


def fail(message, detail=()):
    sys.stderr.write("hdf5_env: %s\n" % message)
    for line in detail:
        sys.stderr.write("%s\n" % line)
    return 1


def main(argv):
    environment = argv[1] if len(argv) > 1 else ""

    base, how = prefix(environment)
    if base is None:
        return fail(
            "no environment is activated",
            ["    CONDA_PREFIX is unset and MAMBA_ROOT_PREFIX gives no",
             "    fallback.  The job's steps have to run in the shell the",
             "    environment was initialised for: `shell: bash -el {0}`",
             "    with `init-shell: bash` on setup-micromamba."])
    sys.stdout.write("prefix          %s (from %s)\n" % (base, how))
    if not os.path.isdir(base):
        return fail("the prefix does not exist", [listing(
            os.path.dirname(base))])

    root, tried = hdf5_root(base)
    if root is None:
        return fail(
            "no hdf5.h under the environment",
            ["    looked for include/hdf5.h under each of:"] +
            ["      %s" % t for t in tried] +
            ["    the prefix holds:", listing(base)])

    include = os.path.join(root, "include")
    missing = [h for h in ("hdf5.h", "hdf5_hl.h")
               if not os.path.isfile(os.path.join(include, h))]
    if missing:
        return fail(
            "%s is missing from %s" % (" and ".join(missing), include),
            ["    hdf5_hl.h is the high-level H5DS dimension-scale API,",
             "    which this implementation requires: the conda-forge",
             "    `hdf5` package carries it, a `libhdf5` that carries",
             "    only the C library does not.",
             "    the include directory holds:", listing(include)])

    python, tried = interpreter(base)
    if python is None:
        return fail(
            "no interpreter in the environment",
            ["    looked for:"] + ["      %s" % t for t in tried] +
            ["    the prefix holds:", listing(base)])

    sys.stdout.write("HDF5_ROOT       %s\n" % root)
    sys.stdout.write("MESTRA_PYTHON   %s\n" % python)
    for directory, names in libraries(root):
        sys.stdout.write("libraries       %s: %s\n"
                         % (directory, ", ".join(names[:12])))

    destination = os.environ.get("GITHUB_ENV")
    if not destination:
        sys.stdout.write("GITHUB_ENV is unset, so nothing was exported\n")
        return 0
    with open(destination, "a", encoding="utf-8") as fh:
        fh.write("HDF5_ROOT=%s\n" % root)
        fh.write("MESTRA_PYTHON=%s\n" % python)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
