# A small units parser, for W10 only.
#
# Section 3 puts units in the UDUNITS grammar that CF uses, and makes
# a string the validator cannot parse a warning rather than an error
# in version 0.  This parser recognises the shape of that grammar --
# products, quotients, parenthesised groups, and an exponent written
# either as `^n` or as digits run on to the symbol -- and nothing
# about what the symbols mean.  It accepts every units string in the
# conformance corpus ("1", "m", "m2", "s", "K", "Pa", "W", "W m-2",
# "m2 s-1", "degree") and rejects "kg/(m s", which has no closing
# parenthesis.  It is not a unit system: it converts nothing and it
# does not know that "Pa" is a pascal.

mutable struct UnitsCursor
    s::String
    i::Int
    depth::Int
end

UnitsCursor(s::AbstractString, i::Int) = UnitsCursor(String(s), i, 0)

"""How deep a units string may nest its parentheses.  A units string
comes out of a file, so its depth is the file's choice, and the parser
below is recursive."""
const MAX_UNITS_DEPTH = 32

"""The longest units string this parser will look at."""
const MAX_UNITS_BYTES = 4096

peek(c::UnitsCursor) = c.i <= ncodeunits(c.s) ? c.s[c.i] : '\0'

function skipspace!(c::UnitsCursor)
    while c.i <= ncodeunits(c.s) && isspace(c.s[c.i])
        c.i = nextind(c.s, c.i)
    end
end

function advance!(c::UnitsCursor)
    c.i = nextind(c.s, c.i)
end

unit_symbol_char(ch::Char) =
    isletter(ch) || ch == '_' || ch == '%' || ch == '°' || ch == 'µ'

"""
    parse_units(s) -> Bool

True when the string has the shape of a UDUNITS expression.
"""
function parse_units(s::AbstractString)
    isempty(s) && return false
    ncodeunits(s) > MAX_UNITS_BYTES && return false
    c = UnitsCursor(String(s), 1)
    parse_expr!(c) || return false
    skipspace!(c)
    return c.i > ncodeunits(c.s)
end

function parse_expr!(c::UnitsCursor)
    parse_term!(c) || return false
    while true
        skipspace!(c)
        ch = peek(c)
        if ch == '*' || ch == '/' || ch == '.'
            advance!(c)
            skipspace!(c)
            parse_term!(c) || return false
        elseif unit_symbol_char(ch) || isdigit(ch) || ch == '('
            parse_term!(c) || return false
        else
            return true
        end
    end
end

function parse_term!(c::UnitsCursor)
    skipspace!(c)
    ch = peek(c)
    if ch == '('
        c.depth >= MAX_UNITS_DEPTH && return false
        c.depth += 1
        advance!(c)
        ok = parse_expr!(c)
        c.depth -= 1
        ok || return false
        skipspace!(c)
        peek(c) == ')' || return false
        advance!(c)
    elseif unit_symbol_char(ch)
        while unit_symbol_char(peek(c))
            advance!(c)
        end
    elseif isdigit(ch) || ch == '-' || ch == '+'
        parse_number!(c) || return false
        return true
    else
        return false
    end
    parse_exponent!(c)
    return true
end

function parse_exponent!(c::UnitsCursor)
    if peek(c) == '^'
        advance!(c)
        return parse_int!(c)
    end
    ch = peek(c)
    if isdigit(ch) || ((ch == '-' || ch == '+') &&
                       isdigit(peekahead(c)))
        return parse_int!(c)
    end
    return true
end

function peekahead(c::UnitsCursor)
    j = c.i <= ncodeunits(c.s) ? nextind(c.s, c.i) : c.i
    return j <= ncodeunits(c.s) ? c.s[j] : '\0'
end

function parse_int!(c::UnitsCursor)
    ch = peek(c)
    (ch == '-' || ch == '+') && advance!(c)
    isdigit(peek(c)) || return false
    while isdigit(peek(c))
        advance!(c)
    end
    return true
end

function parse_number!(c::UnitsCursor)
    ch = peek(c)
    (ch == '-' || ch == '+') && advance!(c)
    isdigit(peek(c)) || return false
    while isdigit(peek(c))
        advance!(c)
    end
    if peek(c) == '.'
        advance!(c)
        while isdigit(peek(c))
            advance!(c)
        end
    end
    if peek(c) == 'e' || peek(c) == 'E'
        save = c.i
        advance!(c)
        if !parse_int!(c)
            c.i = save
        end
    end
    return true
end
