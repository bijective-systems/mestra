"""A small parser for the UDUNITS-style grammar the spec names.

SPEC.md section 3 says units are strings in the UDUNITS grammar that
CF uses ("Pa", "m s-1", "W m-2", "1" for dimensionless), and that in
version 0 a string the validator cannot parse is a warning (W10) and
not an error.

This parser is deliberately small. It reads products, quotients,
powers written as a trailing integer or after "^" or "**",
parenthesised groups, decimal factors, and names built from a base
unit list with the SI prefixes. It decides one question - does this
string parse - and reports the dimensions it found, so that a tool
can also refuse to combine two quantities whose dimensions differ.
It does not convert between units and it knows nothing about
offsets, calendars or the many spellings UDUNITS itself accepts.

    >>> parse("W m-2").dimensions
    {'kg': 1, 's': -3}
    >>> parse("kg/(m s") is None
    True
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from dataclasses import dataclass, field

from . import limits

__all__ = ["Unit", "parse", "is_parseable", "same_dimensions"]

#: The base dimensions every other unit is reduced to.
BASE = ("m", "kg", "s", "A", "K", "mol", "cd")

#: Dimensionless names, kept apart so that "1", "rad" and "degree"
#: all parse and all come out with no dimensions.
_DIMENSIONLESS = {
    "1", "one", "unitless", "dimensionless", "none", "count", "percent",
    "rad", "radian", "radians", "sr", "steradian", "degree", "degrees",
    "deg", "arcdeg", "arcminute", "arcsecond", "dB", "decibel", "PLdB",
}

#: name -> the exponents of the base dimensions.
_UNITS: dict[str, dict[str, int]] = {
    "m": {"m": 1}, "metre": {"m": 1}, "meter": {"m": 1},
    "g": {"kg": 1}, "gram": {"kg": 1},
    "s": {"s": 1}, "second": {"s": 1}, "sec": {"s": 1},
    "A": {"A": 1}, "ampere": {"A": 1},
    "K": {"K": 1}, "kelvin": {"K": 1},
    "mol": {"mol": 1}, "mole": {"mol": 1},
    "cd": {"cd": 1}, "candela": {"cd": 1},
    "Hz": {"s": -1}, "hertz": {"s": -1},
    "N": {"kg": 1, "m": 1, "s": -2}, "newton": {"kg": 1, "m": 1, "s": -2},
    "Pa": {"kg": 1, "m": -1, "s": -2},
    "pascal": {"kg": 1, "m": -1, "s": -2},
    "bar": {"kg": 1, "m": -1, "s": -2},
    "atm": {"kg": 1, "m": -1, "s": -2},
    "psi": {"kg": 1, "m": -1, "s": -2},
    "J": {"kg": 1, "m": 2, "s": -2}, "joule": {"kg": 1, "m": 2, "s": -2},
    "W": {"kg": 1, "m": 2, "s": -3}, "watt": {"kg": 1, "m": 2, "s": -3},
    "C": {"A": 1, "s": 1}, "coulomb": {"A": 1, "s": 1},
    "V": {"kg": 1, "m": 2, "s": -3, "A": -1},
    "volt": {"kg": 1, "m": 2, "s": -3, "A": -1},
    "F": {"kg": -1, "m": -2, "s": 4, "A": 2},
    "ohm": {"kg": 1, "m": 2, "s": -3, "A": -2},
    "S": {"kg": -1, "m": -2, "s": 3, "A": 2},
    "Wb": {"kg": 1, "m": 2, "s": -2, "A": -1},
    "T": {"kg": 1, "s": -2, "A": -1},
    "H": {"kg": 1, "m": 2, "s": -2, "A": -2},
    "lm": {"cd": 1}, "lx": {"cd": 1, "m": -2},
    "Bq": {"s": -1}, "Gy": {"m": 2, "s": -2}, "Sv": {"m": 2, "s": -2},
    "kat": {"mol": 1, "s": -1},
    "L": {"m": 3}, "l": {"m": 3}, "litre": {"m": 3}, "liter": {"m": 3},
    "t": {"kg": 1}, "tonne": {"kg": 1},
    "min": {"s": 1}, "minute": {"s": 1},
    "h": {"s": 1}, "hour": {"s": 1}, "hr": {"s": 1},
    "d": {"s": 1}, "day": {"s": 1}, "week": {"s": 1},
    "year": {"s": 1}, "yr": {"s": 1},
    "degree_C": {"K": 1}, "degC": {"K": 1}, "celsius": {"K": 1},
    "degree_F": {"K": 1}, "degF": {"K": 1},
    "ft": {"m": 1}, "foot": {"m": 1}, "feet": {"m": 1},
    "in": {"m": 1}, "inch": {"m": 1}, "yd": {"m": 1}, "yard": {"m": 1},
    "mi": {"m": 1}, "mile": {"m": 1}, "nmi": {"m": 1},
    "lb": {"kg": 1}, "lbm": {"kg": 1},
    "lbf": {"kg": 1, "m": 1, "s": -2},
    "slug": {"kg": 1},
    "knot": {"m": 1, "s": -1}, "kt": {"m": 1, "s": -1},
}

#: The SI prefixes, and the ones UDUNITS spells out.
_PREFIXES = {
    "y", "z", "a", "f", "p", "n", "u", "µ", "μ", "m", "c",
    "d", "da", "h", "k", "M", "G", "T", "P", "E", "Z", "Y",
    "yocto", "zepto", "atto", "femto", "pico", "nano", "micro",
    "milli", "centi", "deci", "deca", "hecto", "kilo", "mega", "giga",
    "tera", "peta", "exa", "zetta", "yotta",
}

_TOKEN = re.compile(r"""
    (?P<space>\s+)
  | (?P<number>[0-9]+\.[0-9]*(?:[eE][-+]?[0-9]+)?
              |\.[0-9]+(?:[eE][-+]?[0-9]+)?
              |[0-9]+[eE][-+]?[0-9]+)
  | (?P<divide>/|per(?![A-Za-z_]))
  | (?P<name>[A-Za-z_µμ][A-Za-z_µμ]*)
  | (?P<integer>[0-9]+)
  | (?P<power>\^|\*\*)
  | (?P<times>\*|·)
  | (?P<percent>%)
  | (?P<open>\()
  | (?P<close>\))
  | (?P<sign>[-+])
""", re.VERBOSE)


@dataclass(frozen=True)
class Unit:
    """A parsed unit: the string it came from and its dimensions."""

    text: str
    dimensions: dict[str, int] = field(default_factory=dict)

    @property
    def dimensionless(self) -> bool:
        """True when nothing is left after reduction, as for "1"."""
        return not self.dimensions

    def __str__(self) -> str:
        return self.text


class _Token:
    __slots__ = ("kind", "text")

    def __init__(self, kind: str, text: str) -> None:
        self.kind = kind
        self.text = text


class _ParseError(Exception):
    pass


def _scan(text: str) -> Iterator[_Token]:
    at = 0
    while at < len(text):
        match = _TOKEN.match(text, at)
        if match is None:
            raise _ParseError("unexpected character %r" % text[at])
        at = match.end()
        kind = match.lastgroup or ""
        if kind == "space":
            yield _Token("space", " ")
            continue
        yield _Token(kind, match.group())


def _lookup(name: str) -> dict[str, int]:
    """The dimensions of one name, trying the SI prefixes."""
    if name in _DIMENSIONLESS:
        return {}
    if name in _UNITS:
        return dict(_UNITS[name])
    for cut in (1, 2, 5):
        head, tail = name[:cut], name[cut:]
        if head in _PREFIXES and tail:
            if tail in _DIMENSIONLESS:
                return {}
            if tail in _UNITS:
                return dict(_UNITS[tail])
    raise _ParseError("unknown unit %r" % name)


def _combine(left: dict[str, int], right: dict[str, int],
             sign: int) -> dict[str, int]:
    out = dict(left)
    for base, power in right.items():
        value = out.get(base, 0) + sign * power
        if value:
            out[base] = value
        elif base in out:
            del out[base]
    return out


def _power(dims: dict[str, int], exponent: int) -> dict[str, int]:
    return {base: power * exponent
            for base, power in dims.items() if power * exponent}


class _Parser:
    """Recursive descent over the token stream."""

    def __init__(self, text: str) -> None:
        self.tokens = list(_scan(text))
        self.at = 0
        #: How many parentheses deep the parser is. A units string
        #: is one or two levels; thousands is an attack on a
        #: recursive descent parser and not a unit (limits).
        self.depth = 0

    def peek(self) -> _Token | None:
        while (self.at < len(self.tokens)
               and self.tokens[self.at].kind == "space"):
            self.at += 1
        if self.at >= len(self.tokens):
            return None
        return self.tokens[self.at]

    def peek_raw(self) -> _Token | None:
        if self.at >= len(self.tokens):
            return None
        return self.tokens[self.at]

    def take(self) -> _Token:
        token = self.peek()
        if token is None:
            raise _ParseError("the string ends too early")
        self.at += 1
        return token

    def parse(self) -> dict[str, int]:
        dims = self.expression()
        left = self.peek()
        if left is not None:
            raise _ParseError("trailing %r" % left.text)
        return dims

    def expression(self) -> dict[str, int]:
        dims = self.term()
        while True:
            token = self.peek()
            if token is None or token.kind == "close":
                return dims
            if token.kind == "divide":
                self.take()
                dims = _combine(dims, self.term(), -1)
            elif token.kind == "times":
                self.take()
                dims = _combine(dims, self.term(), 1)
            elif token.kind in ("name", "number", "open", "integer",
                                "percent"):
                dims = _combine(dims, self.term(), 1)
            else:
                raise _ParseError("unexpected %r" % token.text)

    def term(self) -> dict[str, int]:
        dims = self.factor()
        token = self.peek_raw()
        if token is not None and token.kind in ("integer", "sign"):
            # An exponent written against the name, "m2" or "s-1".
            return _power(dims, self.exponent())
        after = self.peek()
        if after is not None and after.kind == "power":
            self.take()
            return _power(dims, self.exponent())
        return dims

    def exponent(self) -> int:
        token = self.take()
        sign = 1
        if token.kind == "sign":
            sign = -1 if token.text == "-" else 1
            token = self.take()
        if token.kind != "integer":
            raise _ParseError("an exponent must be an integer")
        return sign * int(token.text)

    def factor(self) -> dict[str, int]:
        token = self.take()
        if token.kind == "open":
            if self.depth >= limits.MAX_UNITS_DEPTH:
                raise _ParseError("more than %d parentheses deep"
                                  % limits.MAX_UNITS_DEPTH)
            self.depth += 1
            dims = self.expression()
            self.depth -= 1
            close = self.peek()
            if close is None or close.kind != "close":
                raise _ParseError("a group is not closed")
            self.take()
            return dims
        if token.kind in ("number", "integer", "percent"):
            return {}
        if token.kind == "name":
            return _lookup(token.text)
        raise _ParseError("unexpected %r" % token.text)


def parse(text: str) -> Unit | None:
    """Parse a units string, or return None when it does not parse.

    A None result is what the validator reports as W10.
    """
    if text is None:
        return None
    if len(text) > limits.MAX_UNITS_LENGTH:
        return None
    stripped = text.strip()
    if not stripped:
        return None
    try:
        return Unit(text, _Parser(stripped).parse())
    except _ParseError:
        return None
    except RecursionError:                          # pragma: no cover
        return None


def is_parseable(text: str) -> bool:
    """True when `text` is a units string this parser understands."""
    return parse(text) is not None


def same_dimensions(left: str, right: str) -> bool:
    """True when both parse and their dimensions agree.

    Tools must refuse to combine unparseable units, so an
    unparseable string is never the same as anything.
    """
    a, b = parse(left), parse(right)
    if a is None or b is None:
        return False
    return a.dimensions == b.dimensions
