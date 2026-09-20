"""Errors and findings, each naming the rule of SPEC.md section 14.

Every mistake this package can name carries the identifier of the rule
it breaks, so that a message can be traced to the specification.
"""

from __future__ import annotations

from dataclasses import dataclass

__all__ = ["MestraError", "TooLarge", "Finding"]


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


class TooLarge(MestraError):
    """A read that would materialise more than the limit allows.

    It is E41 when an eager read meets it (section 14). A validator
    catches it and leaves the rule unchecked instead, because
    section 14 reserves the size case for an eager read.
    """

    def __init__(self, message: str, where: str = "",
                 count: int = 0) -> None:
        super().__init__("E41", message, where)
        self.count = count


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
