"""One rule set decides every entry point.

Finding 13 of the Phase 3 report: "a caller moving between two
languages will find the same invalid file opens in one and is refused
in the other", because the metadata open and the read do not name the
same rule. Within this implementation they do, and these tests are
what holds it: over every case of the corpus and every file of the
hostile subset, the rule the metadata open names is the rule a read
names.

The set is `mestra.reader.REFUSED`, which is the one section 2 of
`docs/api-conventions.md` fixes: E01, E16, E19, E25, E26, E29, E30,
E40 and E41. A semantic fault -- a missing unit, a support a row
references and the file does not hold, a dtype the role does not
allow -- never stops a read, so that `info` works on the files a user
most needs to inspect. That is a choice and not an accident, and it
is the same choice at every door.

Section 30 asks for more than agreement on the hostile subset:
"Opening the file for its metadata alone, and any operation that
reads a slot, must refuse with the same ids rather than return
something." The last test here is that, against each hostile case's
own `required_errors`.
"""

from __future__ import annotations

import json
import os

import pytest

import mestra
from mestra.errors import MestraError
from mestra.reader import REFUSED
from tests import corpus

HOSTILE = os.path.join(corpus.VECTORS, "hostile")


def _hostile_names() -> list[str]:
    with open(os.path.join(corpus.VECTORS, "manifest.json"),
              encoding="utf-8") as fh:
        manifest = json.load(fh)
    return [case["name"] for case in manifest.get("hostile", [])]


def _hostile_path(name: str) -> str:
    return os.path.join(HOSTILE, name, "case.mes")


def _hostile_expected(name: str) -> dict:
    with open(os.path.join(HOSTILE, name, "expected.json"),
              encoding="utf-8") as fh:
        return json.load(fh)


def _named(call) -> list[str]:
    """The rules one entry point names: the refusal, or the
    findings a non-refusing entry point leaves on the dataset."""
    try:
        dataset = call()
    except MestraError as exc:
        return ["refused:" + exc.rule]
    with dataset:
        return sorted({finding.rule for finding in dataset.problems})


def _open(path: str) -> list[str]:
    """The metadata open: attributes and dataspaces, no array."""
    return _named(lambda: mestra.read(path))


def _read(path: str) -> list[str]:
    """The read: every value, at once."""
    return _named(lambda: mestra.read(path, lazy=False))


CASES = corpus.case_names()
HOSTILE_CASES = _hostile_names()


def test_the_hostile_subset_is_where_it_should_be():
    assert len(HOSTILE_CASES) == 15
    for name in HOSTILE_CASES:
        assert os.path.exists(_hostile_path(name)), name


@pytest.mark.parametrize("name", CASES)
def test_the_open_and_the_read_agree_on_every_corpus_case(name):
    path = corpus.case_path(name)
    assert _open(path) == _read(path)


@pytest.mark.parametrize("name", HOSTILE_CASES)
def test_the_open_and_the_read_agree_on_every_hostile_file(name):
    path = _hostile_path(name)
    assert _open(path) == _read(path)


@pytest.mark.parametrize("name", CASES)
def test_a_refusal_names_a_rule_from_the_documented_set(name):
    """Nothing is refused that the conventions do not list, and
    everything listed that the validator finds is refused."""
    path = corpus.case_path(name)
    named = _open(path)
    refusals = [r.split(":", 1)[1] for r in named
                if r.startswith("refused:")]
    for rule in refusals:
        assert rule in REFUSED, "%s refused under %s" % (name, rule)
    if refusals:
        return
    # Nothing was refused, so the validator must have found nothing
    # in the set either -- an open that lets through a file a read
    # would refuse is the half of finding 13 that matters.
    found = set(mestra.validate(path).error_ids)
    assert not found & set(REFUSED), (
        "%s breaks %s and opened anyway"
        % (name, sorted(found & set(REFUSED))))


@pytest.mark.parametrize("name", HOSTILE_CASES)
def test_the_hostile_contract_holds_at_both_doors(name):
    """Section 30: the metadata open and any operation that reads a
    slot must refuse with the same ids rather than return
    something."""
    required = _hostile_expected(name)["required_errors"]
    for entry in (_open, _read):
        named = entry(_hostile_path(name))
        refusals = {r.split(":", 1)[1] for r in named
                    if r.startswith("refused:")}
        assert refusals, "%s: %s returned instead of refusing" % (
            name, entry.__name__)
        for rule in required:
            assert rule in refusals or rule in set(named), (
                "%s: %s named %s and the file requires %s"
                % (name, entry.__name__, sorted(refusals), required))
