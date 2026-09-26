# Releasing

Package version and format version are distinct. A Python bug-fix
release need not change `mestra/0`; changing what an existing file means
requires the specification's compatibility process (see
[CONTRIBUTING.md](../CONTRIBUTING.md)).

## Release gate

Pushing a `v*` tag starts `.github/workflows/publish.yml`. Its
`conformance` job calls the existing CI workflow from the same commit,
covering the corpus and all four language implementations. The `build`
job independently builds the wheel/sdist, installs the wheel outside
the checkout, checks tag/package/version agreement and runs the examples.
`publish` requires both jobs to succeed. Only that final job requests
the PyPI OpenID Connect credential. Do not bypass a failed language or
corpus job to ship a tag.

Before tagging, note in the release any known limitation, linked to the
[capability table](compatibility.md). Tag the reviewed commit after its
checks pass; the tag workflow repeats the checks for that exact revision.
No release is performed by editing this document or the workflows.

## Downstream consumers

A tool that vendors or pins an implementation should update its pin,
rebuild, and run its own tests against the new revision. The CI here
is self-contained: it validates the open format without any consumer's
runtime, so a consumer's checks stay with that consumer.
