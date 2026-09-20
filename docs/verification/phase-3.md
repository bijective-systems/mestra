Phase 3: independent verification of the four implementations
=============================================================

Date: 2026-09-20. Branch `phase3/verification`. Nothing outside
`docs/verification/` was changed.

This is the report of the Phase 3 verifier named in `docs/plan.md`. I
wrote none of the four implementations and none of the corpus. What
follows is what the four did when they were made to disagree with
each other, with the specification and with the golden files, and
what could be proved about each disagreement.

Everything here was produced by the helper scripts committed beside
this file:

    structural.py            section 30 structural equality
    driver.py                the Python driver
    driver.jl                the Julia driver
    mestraVerifyDriver.m     the MATLAB driver
    mestraHostileOne.m       one hostile file in MATLAB
    cppdrv.py                a wrapper around mestra-cli
    harness.py               the cross-language harness
    ncnames.py               ncdump against the scale link names
    hostile.py               every reader over every hostile file
    codec_source.py          a dictionary of every leaf of section 17
    adversarial.py           seventeen files of my own

The comparator is mine. `structural.py` implements section 30's
structural equality from the text, with h5py and the HDF5 low-level
API only, and shares no code with any implementation or with
`vectors/check.py`. It was checked against three deliberate
corruptions of a golden file -- one changed value, one deleted
dataset, one deleted attribute -- and caught each of them.

Conventions. `$REPO` is the repository root, `$SCRATCH` a scratch
directory, `$HDF5_ROOT` the HDF5 installation, and `$PY`, `$JULIA`
and `$MATLAB` the three interpreters. The C++ tool is
`cpp/build/mestra-cli`, configured with `-DHDF5_ROOT=$HDF5_ROOT`.


1. Baseline: each implementation's own suite
--------------------------------------------

Each suite was run once, unmodified, before anything else.

    language   result                                      time
    Python     714 passed, 0 failed                        92 s
    MATLAB     568 tests, 568 passed, 0 failed              21 s
    C++        4 of 4 ctest cases passed                     8 s
    Julia      797 passed of 797                            39 s

The C++ cases are `unit`, `corpus`, `shared_hostile` and `hostile`.
The MATLAB run reports its own coverage: 70 corpus cases of which 30
valid, 64 probes, 75 support ids, 5 codec round trips, 45 evaluation
probes, 30 read-write-compare, 20 own hostile files, 15 shared.

Every suite passes. Nothing below was found by running a suite.


2. Cross-write: 30 valid cases, 4 writers, 4 readers
-----------------------------------------------------

Each of the 30 corpus cases that must validate cleanly was read from
its golden file and written again by each writer, giving 120 files.
Each of those was read by each reader and judged on four axes at
once: the reading language's validator must report no error and
exactly the warnings `expected.json` states; every probe of the case
must be bit-equal after permutation by name; every `support_id` must
match; and the written file must be structurally equal to the golden
file under section 30, judged by my comparator.

Cross-write passes, out of 30. Readers down, writers across.

                Python   MATLAB      C++    Julia
    Python          30       30       30       30
    MATLAB          30       30       30       30
    C++             30       30       30       30
    Julia           30       30       30       30

Baseline, each reader against the golden file, out of 30: Python 30,
MATLAB 30, C++ 30, Julia 30.

Structural equality of each written file against the golden file, out
of 30: Python 30, MATLAB 30, C++ 30, Julia 30.

There is no failure to list. Sixteen directions, 480 read-backs, four
axes each. This is the strongest single result in the report: the
byte layout of sections 18 to 25 is pinned tightly enough that four
independent writers produce the same file and four independent
readers agree on every value in it.

    $PY docs/verification/harness.py write
    $PY docs/verification/harness.py check
    $PY docs/verification/harness.py report

One thing the corpus does not cover, so this matrix does not either:
no valid case carries a `/notes` or a `/private` group. Section 7
below covers it with a file of my own, and finds a difference.


3. Evaluation of the affine callable
-------------------------------------

The three cases with an `evaluation` entry were evaluated in each
language on the keys table `expected.json` gives, and every output
compared bit for bit.

    case                  probes   Python   MATLAB      C++    Julia
    affine_zero_rows           7      7/7      7/7      7/7      7/7
    affine_with_rows          14    14/14    14/14    14/14    14/14
    callable_two_slots        24    24/24    24/24    24/24    24/24

All 45 outputs are bit-identical to `expected.json` and to each other
in all four languages. Section 27's rule that the dot product is
accumulated in the declared key order with `b` added last, and with
no fused multiply-add, is implemented the same way four times.

The evaluated dataset was then written from each language and read by
every other. All sixteen directions validate with no error.

Comparing the written evaluated files against each other structurally
leaves exactly two differences, both findings below: what `evaluate`
leaves under `/callables` (finding 7) and one chunk shape from MATLAB
(finding 10). Every key column, every scalar and every array is
structurally equal across all four in all three cases.

    $PY docs/verification/harness.py evaluate
    $PY docs/verification/harness.py evalcheck


4. The dictionary codec
------------------------

`codec_source.py` builds a file whose callable dictionary holds every
leaf of section 17: nested dictionaries including an empty one, a
nested dictionary using `type` and `repr` as keys, float64 arrays of
two and three dimensions, int32 and int64 arrays, a boolean array, an
array holding NaN and both infinities, an empty float64 array, an
empty two-dimensional int64 array, a list of strings, an empty
fixed-length string dataset, an integer, a float of the same value,
both booleans, a string, an empty string, the null sentinel, the most
negative int64 and the smallest subnormal float64. The callable's
`type` is one no implementation registers, so every reader keeps the
dictionary whole rather than interpreting it.

Each language read that file and wrote it again; each language then
read all five files and dumped the dictionary in the tagged form of
section 30. Each dump was compared against the reference written from
the specification, with every float compared by its bits.

Readers down, writers across; `source` is the file built from the
specification.

                    py       ml      cpp       jl   source
    Python        DIFF     same     same     same     same
    MATLAB        DIFF     same     same     same     same
    C++           DIFF     same     same     same     same
    Julia         DIFF     same     same     same     same

Nineteen of the twenty cells are the reference exactly. The four
failures are one defect in the Python writer, MUST-FIX 3: a file
Python wrote loses the type of an empty fixed-length string dataset,
and all four readers then see an empty float64 array where the source
had an empty string list.

    $PY docs/verification/harness.py codec
    $PY docs/verification/harness.py codecreport


5. The hostile subsets
-----------------------

`vectors/generate.py --hostile-deep` was run first. Every reader was
then run over the 15 files of `vectors/hostile` and over each
implementation's own hostile directory -- 13 for Python, 21 for
MATLAB, 10 for C++, 17 for Julia -- through three entry points each:
the validator, the metadata open, and a read of the data. Each
invocation had a timeout.

Python and C++ get one process per entry point. Julia and MATLAB pay
several seconds of interpreter start-up, so they get one process per
file that runs all three and times each inside; the outer timeout
still catches a hang but cannot say which of the three hung. No
timeout was reached on any hostile file in any language, so nothing
turns on that.

Outcomes, counted over entry points, which is files times three:

    set        files   language    clean  signal   hang   required
                                                          ids missing
    shared        15   Python         45       0      0   none
                       MATLAB         45       0      0   1 file
                       C++            45       0      0   none
                       Julia          45       0      0   9 files
    own_py        13   all four   39 each      0      0   n/a
    own_ml        21   all four   63 each      0      0   n/a
    own_cpp       10   all four   30 each      0      0   n/a
    own_jl        17   all four   51 each      0      0   n/a

No crash, no signal, no hang, no unbounded allocation, in any
language, on any of the 76 hostile files. That is what section 29
asks for and all four meet it. The two 31 MB deep-nesting files are
included: no reader asked HDF5 for the path of a dimension scale and
none died.

The last column is a different requirement, and two implementations
fail it. Section 30 says of the hostile subset: "Opening the file for
its metadata alone, and any operation that reads a slot, must refuse
with the same ids rather than return something." Every validator
reports at least the required ids in all four languages. The metadata
open and the read do not: Julia returns a dataset for nine of the
fifteen with nothing said (MUST-FIX 1), and MATLAB returns metadata
for one of them (MUST-FIX 2).

    $PY vectors/generate.py --hostile-deep
    $PY docs/verification/hostile.py run
    $PY docs/verification/hostile.py report

The C++ library was also rebuilt with `-DMESTRA_SANITIZE=ON` and the
whole hostile set, the private sets and my own seventeen files were
run through it: 279 invocations, no AddressSanitizer report, no
undefined-behaviour report. The only non-clean outcome was the
ten-thousand-key file, which is finding 4 and not a memory fault.


6. Seventeen adversarial files of my own
-----------------------------------------

`adversarial.py` builds seventeen files no existing hostile set
covers, each from the rules of the specification rather than from any
implementation. Sixteen are built with h5py; one is written by
netCDF-C through its own binding, so that the container is beyond
doubt. Each carries the rule ids I read the specification to require;
that reading is an argument, not an authority.

The hostile contract of section 30 applies to `vectors/hostile` and
not to these, so only the validator column is scored against the
expectation; what the metadata open and the read say is recorded as a
difference between implementations, not as a failure.

Validator outcome. `-` means no identifier at all; warnings are
omitted except where they carry the point.

    file                             expect  Python  MATLAB  C++   Julia
    aligned_is_two                      E19  E19     E19     E19   -
    attr_role_is_an_integer             E19  E02     E02     E02   E02
                                             E19     E19     E19   E19
    attr_units_is_a_float               E19  E19     E19     E19   E19
    nul_inside_a_string_attribute       E26  E26     E26     E26   E26
    category_longer_than_2^31           E41  E10     E10     E10   E39
                                                     E41           E41
    row_support_negative                E06  E06     E06     E06   E06
    support_id_in_upper_case            E08  E08     E08     E08   E08
    row_scale_length_disagrees          E16  E16     E16     E16   E16
    netcdf4_valid_mestra_invalid        E20  E08     E05     E08   E05
                                             E16     E08     E16   E08
                                             E19     E16     E19   E16
                                             E20     E19     E20   E19
                                                     E20           E20
                                                                   E28
                                                                   E37
    callable_type_with_a_slash           ok  -       -       -     -
    keys_differing_only_by_case          ok  -       -       -     -
    scale_attached_to_itself             ok  -       -       -     -
    unlimited_node_dimension             ok  -       -       -     -
    private_and_notes                    ok  -       -       -     E25
    support_holds_a_dataset_called_row   ok  E27     -       -     E27
                                                                   W11
    four_thousand_keys                   ok  (a)     -       -     -
    ten_thousand_keys                    ok  (a)     (a)     (a)   (a)

    (a) no result inside the budget; see finding 4.

What this set found, beyond the two performance results:

  - `aligned = 2`. Section 18: a boolean is int8, "value 0 for false
    and 1 for true. No other value is legal." Julia reports nothing
    and reads it back as `true`. The other three report E19.
    MUST-FIX 5.
  - a valid file carrying `/private`. Section 14: the byte-level
    rules "are checked on the public objects only. `/private` is not
    checked". Julia walks into it and rejects the file with E25 on a
    dataset there. The other three accept it. MUST-FIX 6.
  - an ordinary contiguous dataset named `row` inside a support
    group, attached to the file's `row` scale. Python and Julia
    report E27, which section 23 supports; Julia alone also reports
    W11 for the unknown member; MATLAB and C++ report nothing. A
    two-two split on a file the specification does not describe.
    SHOULD-FIX 12.
  - a category table declaring 2^31 + 5 entries and storing none.
    Nobody allocated it and nobody hung. Python's validator says E10
    and its eager read reports E41 on `dataset.problems`; MATLAB says
    E10 and E41; Julia says E39 and E41; C++ says E10 from all three
    entry points and never E41, although section 29 names E41 for
    exactly this. SHOULD-FIX 14.
  - a callable whose `type` contains a slash, and two keys whose
    names differ only by case, are accepted by all four. That is
    right: section 18 constrains names and not attribute values, and
    both names are legal netCDF-4 names.
  - a dimension scale whose own axis holds a reference back to
    itself. All four ignore it and none loops. Section 21 says a
    scale carries no scale on its own axis but not what a reader does
    when one does; ignoring it is the safe reading and all four agree.
  - an unlimited `node` dimension. All four accept it. Nothing
    forbids a second unlimited dimension and netCDF-4 allows one, so
    this is a hole in the text rather than a defect. SHOULD-FIX 15.

    $PY docs/verification/adversarial.py build $SCRATCH/adv
    $PY docs/verification/hostile.py run adversarial
    $PY docs/verification/hostile.py report


7. What a round trip does with `/notes` and `/private`
-------------------------------------------------------

No valid corpus case carries either group, so nothing in the corpus
tests this. `private_and_notes.mes` is a valid file carrying both.
Read and written again, compared against the original:

    Python    structurally equal
    MATLAB    structurally equal
    C++       `/private`, `/private/history` and
              `/private/history/stamps` are gone
    Julia     structurally equal

C++ documents this in its README. It is a reading of section 29's ban
on interpreting `/private`, and section 29 bans interpreting, not
copying. Three of four copy it. SHOULD-FIX 9.


8. Named dimensions through netCDF-C
-------------------------------------

For every file each language wrote in section 2 -- all thirty, not
two -- `ncdump -h` was run and the dimension list of every variable it
printed was compared against the link names of the scales attached to
that dataset's axes, resolved through a bounded walk keyed by object
address as section 21 requires.

    language   variables checked   files with a difference
    Python                  333                          0
    MATLAB                  333                          0
    C++                     333                          0
    Julia                   333                          0

netCDF-C reads every variable of every file every language wrote, and
gives every axis the name the scale's link name gives it. There is no
language whose files netCDF-C reads with different names.

    $PY docs/verification/ncnames.py $HDF5_ROOT/bin/ncdump \
        $SCRATCH/xwrite/py/*.mes


9. Determinism
---------------

Each language wrote each of the 30 valid cases twice and the bytes
were compared.

    language   identical   different
    Python            30           0
    MATLAB            30           0
    C++               30           0
    Julia             29           1

The one Julia difference is not about that case. Writing any file
twice with a second between the two runs gives different bytes, in
four places: the four timestamps in the root object header, at
offsets 0x36, 0x3a, 0x3e and 0x42, plus the checksum that follows
from them. Julia writes version-2 object headers where the other
three write none, and the root one records when the file was
written. See finding 8.


10. Findings
-------------

MUST-FIX
~~~~~~~~

**1. Julia: the reader returns a dataset for nine of the fifteen
shared hostile files without naming the required rule.**

Section 30: "Opening the file for its metadata alone, and any
operation that reads a slot, must refuse with the same ids rather
than return something." Julia's validator is correct on all fifteen.
`Mestra.read`, lazily and materialised, returns a dataset and reports
no finding at all for `attr_array_key`, `attr_array_root`,
`attr_vlen_array_slot`, `filter_many_client_data`,
`filter_unknown_id`, `scale_attached_twice`, `scale_no_name_attr` and
`string_invalid_utf8`, and reports only E41 rather than the required
E16 for `huge_unwritten_dataset`. Two of those matter beyond the
contract: a dataset carrying a filter no library has is read through
and its values handed back, where E29 says a reader must refuse it;
and a category entry that is not valid UTF-8 comes back as an invalid
string with nothing said, where section 25 says "A reader that cannot
recover the bytes of a string must say so rather than return
something else."

    $JULIA --project=julia -e 'using Mestra
      for c in ["attr_array_key", "filter_unknown_id",
                "string_invalid_utf8"]
          ds = Mestra.read("vectors/hostile/$(c)/case.mes")
          Mestra.materialise!(ds)
          println(c, " findings=", [f.rule for f in ds.findings])
          println("   validate says ", Mestra.validate(
              "vectors/hostile/$(c)/case.mes").errors)
      end'

prints an empty finding list for each, beside a validator that
reports E19, E29 and E26.

**2. MATLAB: the metadata open returns for a file whose required id
is E16, and the read names a different id.**

`vectors/hostile/huge_unwritten_dataset` declares a slot of 10^12
rows in a file of two. `mestra.validate` reports E16, E41 and W12,
which is right. `mestra.open` returns a dataset and says `rows = 2`.
`mestra.read` refuses, but with E41 and not E16.

    $MATLAB -nodisplay -batch "addpath('$REPO/matlab'); \
      d = mestra.open(['$REPO/vectors/hostile/' ...
          'huge_unwritten_dataset/case.mes']); \
      fprintf('open returned, rows=%d\n', d.nRows)" < /dev/null

**3. Python: an empty fixed-length string dataset in a callable's
dictionary does not survive a round trip.**

Section 25 provides for it by name: "a producer that needs an empty
list of strings writes an empty fixed-length string dataset with
shape (0,) and size 1", and of empty arrays, "Its dtype is kept, so
an empty float64 array and an empty int64 array are different
values". Section 30's tagged form distinguishes
`{"t":"strings","shape":[0]}` from
`{"t":"array","dtype":"float64","shape":[0]}`. Python's reader hands
back a bare Python list, which carries no element type, and its
writer then writes an empty float64 dataset. MATLAB, C++ and Julia
all keep the string type through the same round trip.

    $PY docs/verification/codec_source.py $SCRATCH/src.mes \
        $SCRATCH/ref.json
    $PY docs/verification/driver.py write $SCRATCH/src.mes \
        $SCRATCH/out.mes
    $PY -c "import h5py
    for p in ('$SCRATCH/src.mes', '$SCRATCH/out.mes'):
        print(p, h5py.File(p)['/callables/m1/empty_strings'].dtype)"

prints `|S1` for the source and `float64` for what Python wrote.

**4. Python: opening a file costs the square of the number of
row-dimensioned datasets, so a file with a thousand columns takes
minutes and one with four thousand takes most of an hour.**

Section 29: "Opening a file must not read any array. A reader must be
able to report the row count, the keys with their roles and bounds,
the supports with their ids, and every slot with its attributes,
having read attributes and dataspaces only." Measured on files that
are a corpus case with extra key columns, each holding two float64
values. Nothing in them is malformed and all four accept them.
Seconds, on a machine shared with other work, so the absolute numbers
are indicative and the shape is the point:

    keys   file    Python   Python   MATLAB   Julia    C++
                     open  validate  validate validate validate
     125  0.4 MB      3.1      3.1       2.5      0.3   0.14
     250  0.8 MB     10.6     10.8       2.0      2.6   0.19
     500  1.4 MB     41.6     41.4       3.5      7.5   0.36
    1000  2.8 MB    155.5    136.0       8.1     30.1   0.73
    2000  5.6 MB        -        -      15.9    102.0   1.74
    4000   11 MB        -        -      28.2    261.3   4.42

Python quadruples for every doubling, which is the signature of a
scan inside a scan; by extrapolation the open of the four-thousand
key file is around forty minutes, and the hostile runner's
sixty-second budget was never close. Julia's validator has the same
quadratic shape with a smaller constant, about four times faster than
Python at a thousand keys and sixty times slower than C++ at four
thousand; that is finding 17 below and a SHOULD-FIX rather than this
one, because Julia's open is linear and costs 1.2 s at four thousand
keys where Python's costs tens of minutes, and it is the open that
section 29 makes a requirement.

A file with a few hundred quantities of interest is an ordinary file.
Python's reader cannot open one in the time a user will wait.

    $PY -c "import h5py, sys, shutil
    sys.path.insert(0, 'docs/verification'); import adversarial as A
    shutil.copy(A.case('mesh_two_rows'), '$SCRATCH/k500.mes')
    with h5py.File('$SCRATCH/k500.mes', 'r+') as f:
        s = f['/keys/mach']
        for i in range(500):
            d = f['/keys'].create_dataset('k%04d' % i, data=s[()],
                dtype=s.dtype, maxshape=(None,), chunks=s.chunks,
                track_times=False)
            A.copy_attrs(s, d); d.dims[0].attach_scale(f['row'])"
    time $PY -c "import mestra; mestra.read('$SCRATCH/k500.mes')"
    time cpp/build/mestra-cli validate $SCRATCH/k500.mes

**5. Julia: a boolean attribute holding 2 is accepted, and read back
as true.**

Section 18: "boolean H5T_STD_I8LE (int8), scalar dataspace, value 0
for false and 1 for true. No other value is legal." E19 covers "a
boolean that is not int8 or whose value is not 0 or 1". Python,
MATLAB and C++ all report E19 on the file below. Julia reports no
error and no warning, and `ds.aligned` comes back `true`, so a file
that says something the format does not define is silently given the
meaning that suppresses the `/row_support` requirement of E28.

    $PY -c "import h5py, numpy as np, shutil
    shutil.copy('vectors/cases/mesh_two_rows/case.mes',
                '$SCRATCH/a2.mes')
    with h5py.File('$SCRATCH/a2.mes', 'r+') as f:
        del f.attrs['aligned']
        f.attrs.create('aligned', np.int8(2))"
    $JULIA --project=julia -e 'using Mestra
      r = Mestra.validate("'$SCRATCH'/a2.mes")
      println(r.errors, " ", r.warnings)
      println(Mestra.read("'$SCRATCH'/a2.mes").aligned)'
    cpp/build/mestra-cli validate $SCRATCH/a2.mes

**6. Julia: a conforming file carrying `/private` is rejected.**

Section 14, of the byte-level rules of sections 18 to 25: "They are
checked on the public objects only. `/private` is not checked, and
neither is any group this version of the format does not know".
Section 29 forbids a reader to interpret `/private` at all. Julia's
validator walks into it and reports E25 against a dataset there,
rejecting a file the other three accept. A producer's private records
are in whatever representation it chose, so this rejects an unknown
but legitimate fraction of real files.

    $PY docs/verification/adversarial.py build $SCRATCH/adv
    $JULIA --project=julia -e 'using Mestra
      r = Mestra.validate("'$SCRATCH'/adv/private_and_notes.mes")
      for f in r.findings; println(f.rule, "  ", f.path); end'

prints `E25  /private/history/stamps`. Python, MATLAB and C++ report
nothing on the same file.


SHOULD-FIX
~~~~~~~~~~

**7. `evaluate` leaves three different things under `/callables`.**

Evaluating a file on a keys table gives, in Python and C++, a file
with no `/callables` group at all; in MATLAB, a `/callables` group
present and empty; in Julia, the whole callable with its dictionary
intact. All three are conforming -- section 13 allows a container
group to be absent or present and empty, and no rule forbids a
callable nothing references -- and the specification says only that
evaluation "yields a file with the same slots, now holding data".
Three behaviours from one sentence. The data is identical in all
four; this is the only structural difference in `affine_zero_rows`
and `affine_with_rows`.

**8. Julia writes the newer HDF5 object header format, at two costs.**

Its files carry version-2 object headers where the other three write
none, and the root one records four timestamps. The first cost is
determinism, section 9 above; `julia/README.md` claims "object time
tracking off, so two runs of the writer produce the same bytes",
which is not what the bytes say. The second is that every other
implementation reads its files quadratically more slowly. The same
thousand-key content, written four ways, validated by C++:

    written by          size    v2 headers   C++ validate
    the generator     2.8 MB             0         0.64 s
    C++               2.8 MB             0         0.68 s
    Python            2.8 MB             0         0.68 s
    Julia             2.6 MB          1029         4.98 s

and the gap widens with the count: on four thousand keys C++ takes
13.7 s in the default layout and 246 s in the newer one, a factor of
eighteen on a file a quarter of the size. `vectors/README.md` already
names this layout and rejects it for the corpus, "because it writes
four timestamps into the root object header, and a file that records
when it was written is not byte reproducible". The specification says
nothing about which object header version a writer uses, which is why
this is a SHOULD-FIX rather than a MUST-FIX; it is also why the
specification should say something. Part of the cost is C++'s: a
linear scan somewhere in its walk turns quadratic on that layout.

**9. C++'s writer discards `/private`.**

Section 7 above. Section 29 forbids interpreting it, not copying it,
and Python, MATLAB and Julia all copy it. A producer that round-trips
a file through the C++ writer loses its own records with no warning.

**10. MATLAB's `evaluate` gives a key column a chunk shape that is
not the default, and every validator then warns.**

Evaluating `callable_two_slots` on a two-row keys table gives a file
whose `/keys/mach` is chunked (1,) from MATLAB and (2,) from the
other three. Section 23's default for a two-row float64 column is the
row count, that is 2. All four validators report W12 on MATLAB's
evaluated file and on nobody else's. Section 16 item 35 settles which
row count to use: "the length of the row dimension the leading axis
is attached to, not the dataset's own extent", which is 2 here and
not the source file's 0. Section 23 does allow another chunk, so the
file conforms; it is the only file in this verification that any
implementation wrote with an avoidable warning on it.

**11. The format cannot express more than 4085 row-dimensioned
datasets in the default HDF5 layout.**

Section 21 requires exactly one dimension scale attached to every
axis of every dataset, and `row` is the axis of every key, every
scalar, every row-varying array and `/row_support`. HDF5 records each
attachment in the scale's `REFERENCE_LIST` attribute, and in the
default object header an attribute cannot exceed 64 KiB. Attaching
the 4086th dataset fails:

    $PY -c "import h5py, numpy as np
    f = h5py.File('$SCRATCH/limit.h5', 'w')
    row = f.create_dataset('row', shape=(2,), dtype='>f4',
                           maxshape=(None,), chunks=(1,))
    row.attrs.create('CLASS', b'DIMENSION_SCALE',
                     dtype=h5py.string_dtype('utf-8', 15))
    n = 0
    try:
        for i in range(6000):
            d = f.create_dataset('v%05d' % i, data=np.zeros(2),
                                 maxshape=(None,), chunks=(2,))
            d.dims[0].attach_scale(row); n += 1
    except Exception as e:
        print('attached', n, 'then', str(e)[:60])"

prints `attached 4085`. The only escape is the newer object header
format, which finding 8 shows costs determinism and read speed. This
is a ceiling on the format and not on any implementation, and the
specification does not mention it. A file with four thousand
quantities of interest is not exotic.

**12. An unknown dataset inside a support group: two report E27, two
report nothing.**

`support_holds_a_dataset_called_row` puts a plain contiguous dataset
named `row` in a support group, attached to the file's `row` scale.
Section 23 says every dataset with a row dimension must be chunked
(E27); section 14 says the byte-level rules are checked on the public
objects and that a *group* this version does not know is W11 and
otherwise left alone. A *dataset* this version does not know is
covered by neither sentence. Python and Julia report E27, Julia also
reports W11, MATLAB and C++ report nothing. The text should say
whether an unknown dataset inside a known group is checked.

**13. The metadata open and the read name different rules in
different languages.**

For a file breaking E06, E08, E16, E19, E20 or E26, C++ refuses from
`validate`, `info` and `read` alike with the same identifiers. Python
refuses from `info` and `read` only for the rules in its documented
`REFUSED` set, and opens the file silently for E06, E08 and E20.
MATLAB and Julia open the file silently for most of them. All of this
is conforming -- section 30 imposes the stricter behaviour only on
the hostile subset -- but a caller moving between two languages will
find the same invalid file opens in one and is refused in the other.

**14. On an eager read above the element cap, C++ names E10 and not
E41.**

Section 29: "An eager read refuses a dataset whose declared element
count is above a maximum the reader states, with E41." For a category
table declaring 2^31 + 5 entries, Python's eager read reports E41 on
`dataset.problems`, MATLAB reports E10 and E41, and Julia reports E41
from all three entry points. C++ refuses, which is the substance, but
names only E10, the downstream consequence of a table it would not
read.

**15. A second unlimited dimension is neither allowed nor forbidden.**

Section 21 gives `row` an unlimited dimension and every other
dimension a length; section 19 says "A zero-length extent is legal
only for the `row` dimension and for a zero-length axis of a
dictionary dataset". Nothing says whether a `node` dimension may be
unlimited with a non-zero length. netCDF-4 allows several unlimited
dimensions and all four implementations accept such a file. Either
the text should allow it or a rule should catch it.

**16. Section 21's claim about netCDF-C is not true.**

Section 21, on making `row` unlimited: "the layout matches what
netCDF-C itself writes, so a round trip through netCDF-C changes
nothing." Copying a golden file with `nccopy -k nc4` changes, at
least: every string attribute from UTF-8 with NUL padding to ASCII
with NUL termination; `aligned` from a scalar to a one-element array;
every category table from a fixed-length string dataset to a
variable-length one, which section 18 forbids outright; every
dimension scale from chunked to contiguous; and the `row` scale from
length 2 to length 0. C++ then rejects the result with E16 and E19.

    $HDF5_ROOT/bin/nccopy -k nc4 \
        vectors/cases/mesh_two_rows/case.mes $SCRATCH/copy.mes
    $PY docs/verification/structural.py \
        vectors/cases/mesh_two_rows/case.mes $SCRATCH/copy.mes
    cpp/build/mestra-cli validate $SCRATCH/copy.mes

The sentence is about the `row` dimension in context, but it is
written without qualification and somebody will act on it.

**17. Julia's validator is quadratic in the number of
row-dimensioned datasets.**

The table in finding 4 gives it: 7.5 s at five hundred keys, 30.1 s
at a thousand, 102 s at two thousand, 261 s at four thousand, against
3.5, 8.1, 15.9 and 28.2 for MATLAB and 0.36, 0.73, 1.74 and 4.42 for
C++. Its reader is not affected -- the open of the same four-thousand
key file costs 1.2 s -- so this is the validator alone, and the
specification requires nothing of a validator's speed, which is why
it is a SHOULD-FIX. At four thousand keys it is already the
difference between a check that runs in a build and one that does
not.


NOTE
~~~~

**18. netCDF-C cannot write a conforming file.** Its own text
attributes are ASCII with NUL termination, where section 18 requires
UTF-8 with NUL padding, so every file netCDF-C writes breaks E19 on
`format`, `writer` and `created` before anything else about the
content. The format is readable by netCDF tooling and not writable by
it. That is a reasonable trade and worth stating in section 13, which
currently says only that a valid file "is also a valid netCDF-4
file".

**19. No crash and no hang on 76 hostile files.** Across the shared
subset, the four private sets and my seventeen, in four languages,
through three entry points each: no signal, no timeout, no unbounded
allocation. The deep-nesting trap of section 21 caught nobody. The
C++ sanitizer build adds 279 clean invocations to that.

**20. The corpus has no valid case with `/notes` or `/private`.**
Thirty valid cases and not one exercises either group, so the
cross-write matrix says nothing about them and finding 9 had to be
found with a file of my own. A corpus case would be cheap and would
have caught it.

**21. Bit-for-bit agreement on everything the corpus does cover.**
480 read-backs on four axes, 45 evaluation outputs, 75 support ids,
19 of 20 codec dumps, 333 variables per language under netCDF-C. The
disagreements in this report are all at edges the corpus does not
reach.


11. What I could not run, and why
----------------------------------

  - Python on the two-thousand and four-thousand key files, and all
    four on the ten-thousand key file. No result inside the budget
    spent, which was sixty seconds in the hostile runner and fifteen
    minutes by hand. That is findings 4, 11 and 17 rather than a gap
    in the method.
  - MATLAB and Julia on the hostile files with one process per entry
    point. Interpreter start-up made that 35 to 45 minutes per
    language, so all three entry points share one process and one
    outer timeout. No timeout was reached, so nothing depends on the
    finer granularity.
  - Byte identity between implementations. Section 30 says it must
    not be tested; structural equality is the comparison and was used
    throughout.
  - A ten-thousand-key file in the default HDF5 layout. The container
    cannot hold one; that is finding 11.
  - The Python package in the shared environment. It is installed
    editable into a conda environment that sibling worktrees also
    install into, and one of them repointed it partway through this
    run. Every Python-dependent result was then re-run with the
    import path pinned to this worktree: the suite, the writes, the
    reads, the codec, the evaluations, the determinism and the
    hostile runs. The 30 files Python writes are byte-identical
    before and after and every matrix is unchanged, so nothing here
    rests on the wrong copy. The drivers now pin the path themselves,
    and anyone repeating this should do the same.


12. Verdict
------------

The four implementations agree with each other and with the
specification to a degree that is unusual and worth stating plainly:
every one of the sixteen cross-write directions passes all thirty
cases on all four axes, the affine callable produces bit-identical
results in four languages, nineteen of twenty codec round trips are
exact, netCDF-C reads all 120 written files with the dimension names
the scales give them, and no reader crashed, hung or allocated
without bound on any of 76 hostile files or under the sanitizers. The
byte layout of sections 18 to 25 is pinned tightly enough that four
people working from the text alone converged on the same bytes. What
is left is at the edges the corpus does not reach, and it divides
cleanly. Three of the six MUST-FIX findings are Julia treating a read
as a place to be lenient: it returns a dataset for nine hostile files
without naming the rule the file breaks, it accepts a boolean holding
2 and quietly gives it a meaning, and it rejects a valid file by
looking inside `/private`, which section 29 forbids. Two are Python:
a round trip that loses the type of an empty string list, and a
reader whose open costs the square of the number of columns. One is a
MATLAB open that returns where the hostile contract says it must
refuse. None of the six touches a value in a well-formed file, which
is why the cross-write matrix is clean and why I would not hold a
release for any of them individually. What I would hold a release for
is the pair of findings behind them: finding 11 says the container
itself stops at 4085 row-dimensioned datasets in the default HDF5
layout, and findings 4, 8 and 17 say two of the four implementations
are already impractical well below that ceiling while the third is
only fast on files the fourth does not write. The format is correct
at the size the corpus tests, six nodes and three rows, and nobody
has yet asked it to carry the size a real dataset will be. That is
the work I would do before Phase 4 touches it.
