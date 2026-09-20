"""Errors and findings, each naming the rule of SPEC.md section 14.

Every mistake this package can name carries the identifier of the rule
it breaks, so that a message can be traced to the specification.
"""

from __future__ import annotations

from dataclasses import dataclass

__all__ = ["MestraError", "Finding"]


class MestraError(Exception):
    """A rule of section 14 broken by a file or by a call.

    `rule` is the identifier ("E11"), `where` the HDF5 path or the
    name the mistake is about, and `message` says what is wrong in
    plain words.
    """

    def __init__(self, rule: str, message: str, where: str = "") -> None:
        self.rule = rule
        self.message = message
        self.where = where
        text = "%s: %s" % (rule, message)
        if where:
            text = "%s: %s: %s" % (rule, where, message)
        super().__init__(text)


@dataclass(frozen=True)
class Finding:
    """One validator outcome: a rule identifier and where it applies."""

    rule: str
    where: str
    message: str

    def __str__(self) -> str:
        if self.where:
            return "%s  %s: %s" % (self.rule, self.where, self.message)
        return "%s  %s" % (self.rule, self.message)
