Validating
==========

Every rule has an identifier that never changes: an error means the
file is rejected, a warning means it is accepted and the reader must
say so. The builder refuses at build time, naming the rule and the
argument to change, anything the validator would refuse in the file,
and `write` validates before it writes. A warning does not stop a
file, so the split that leaks a member is written and reported.

The data
--------

The six rows and the leaking split of `../groups-and-splits`, with one
deliberate mistake: `cl` is added the first time with no units, which
is E11.

    mach    key, role condition, units "1"
            0.4, 0.8, 0.4, 0.8, 0.4, 0.8
    member  key, role group, categories ["wing_a", "wing_b", "wing_c"]
            0, 0, 1, 1, 2, 2
            declared the unit of generalisation
    cl      scalar, units "1"
            0.21, 0.25, 0.30, 0.36, 0.41, 0.48
    split   key, role split, categories ["train", "test"]
            0, 0, 0, 1, 1, 1

Run it
------

    python python.py
    matlab -nodisplay -batch "addpath('<repo>/matlab'); run('matlab.m')"
    ../../../cpp/build/examples/validating
    julia --project=../../../julia julia.jl

It writes `family.mes` in the working directory and validates it.

Run from this directory. The C++ programs are CMake targets: build
them once with `cmake -S cpp -B cpp/build` and
`cmake --build cpp/build -j`.

Expected output
---------------

    refused: E11: cl: a scalar carries units; pass units= ("1" for a dimensionless one)
    ok: True
    errors: [] warnings: ['W01']
    W01 /keys/split: the rows of member wing_b are on both sides of the split, so this is not a generalisation test

`mestra validate family.mes` prints the same finding and the summary
line `0 error(s), 1 warning(s)`, and exits 0 because a warning is not
an error. The rules are listed in SPEC.md section 14.
