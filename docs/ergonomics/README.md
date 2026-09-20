The ergonomics review, and what its scripts are
===============================================

`report.md` is the review: the five mapped datasets of
`docs/mappings.md` built at toy size in four languages, and what it
cost to follow the documents. The scripts under `scripts/` are the
record of that review as it was run, against the APIs as they stood
before `docs/api-conventions.md` was written; the conventions are
what the review produced, so several of the calls in these scripts
have since been renamed, reordered or given different defaults. They
are kept because a finding is only checkable against the code that
produced it, and they are not maintained: a script here may no
longer run, and one that runs may not be the way to do the thing any
more. For how the APIs are used today, read the README of the
language you are in and `docs/example.md`, which are kept current,
and read `docs/api-conventions.md` for the rules all four follow.
