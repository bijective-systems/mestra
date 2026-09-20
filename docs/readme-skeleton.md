The skeleton every per-language README is cut to
================================================

Phase 5 of `plan.md` gives the documents four layers, each complete at
its own depth and nothing repeated between them. A per-language README
is not a layer: it is the door to one interface. Anything about the
format belongs in `guide.md`, anything normative in `../SPEC.md`, and
anything about one call belongs in that call's docstring or help text,
where a user will actually meet it.

So every per-language README carries these five sections, in this
order, and nothing else. One screen for the first three.


1. Install
----------

How to get the package and run its tests: the one command that
installs it, what it depends on, and the one command that runs the
suite. No prose about what the format is.


2. The ten-line example (this language)
---------------------------------------

The top-level README's example, written in this language: build a
small dataset from plain arrays, write it, read it back, and take one
value by name. It is the same data and the same value in all four
languages, so a reader who knows one can read the others. Link to
`docs/examples/` for the seven worked examples and to `guide.md` for
what the concepts mean.


3. Axis order and permute by name
---------------------------------

What order this language hands an array back in, that the dimension
names are what two languages agree on, and the call that permutes or
indexes by name. State the value at one named coordinate of the
example above, so a reader can check their own run against it. This
section is the one that has to be right; the ergonomics review found
it was the part of the documents that never needed a second reading.


4. What the reader refuses
--------------------------

Three lines: the rules this reader refuses to open a file on, what a
non-strict read gives instead, and where the findings of a read are
reported. The detail of hostile files, limits and depth caps moves
into the module's own documentation.


5. Where to go next
-------------------

`../docs/guide.md` first, then `../SPEC.md` by section, then
`../docs/api-conventions.md` for anyone comparing two languages. Three
lines, not a table of contents.


Everything else
---------------

Everything a README carries today that is not one of those five moves
in one of two directions. If it is about the format -- roles, varies,
alignment, statistics, the public and private line, what the validator
reports -- it moves to `guide.md`, and the README links there. If it
is about this API -- an argument's default, what one call refuses,
what a helper returns -- it moves into the docstring, the help text or
the header comment for that call, and the README does not mention it.

One addition is allowed. Section 4 of `api-conventions.md` requires a
language without the post-processing helpers to say so under a heading
of its own; where that applies, that heading is the sixth section and
goes after "What the reader refuses".
