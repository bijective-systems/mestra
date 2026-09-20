# mestra

A container for simulation and surrogate data with declared structure:
rows of observations over design parameters, operating conditions, and
time; scalar quantities and fields on shared supports; the claim that
rows are index-aligned, stated so a reader can check it.

Status: **specification version 0 with four conforming
implementations** (Python, MATLAB, C++, Julia), a 70-case conformance
corpus, and a hostile-file subset. The name is written `mestra`, lower
case, everywhere.

What is here:

    SPEC.md               the normative draft: concepts, roles, layout,
                          validator rules, the two states, the boundary
                          between public data and private model state,
                          and, in sections 18 to 30, the byte-level
                          detail an implementer needs
    docs/example.md       two valid files listed object by object and
                          value by value; the document to keep open
                          while implementing
    docs/examples/        those two files, and the script that writes
                          them with h5py alone
    docs/mappings.md      five real datasets mapped onto the model on
                          paper, which is the test the model must pass
                          before any code is written
    docs/design-notes.md  why it is shaped this way; the decisions and
                          the alternatives considered
    docs/plan.md          the implementation plan and its phases
    docs/api-conventions.md  the API rules every implementation follows
    vectors/              the conformance corpus and the hostile subset
    python/ matlab/ cpp/ julia/   the implementations, each with a
                          README, and each running the corpus

No implementation is the reference: the spec and the corpus are.

Licence: code under Apache-2.0 (see LICENSE); specification text under
CC-BY-4.0. Copyright (c) 2026 Bijective Systems.
