classdef Units
%Units  A small parser for the unit strings this format carries.
%
%   Specification section 3 puts units in the UDUNITS grammar that CF
%   uses, and section 14 makes a string the validator cannot parse a
%   warning (W10) rather than an error.  This parser checks the
%   grammar and not the names: it accepts any symbol built from
%   letters, digits, underscore and the degree sign, because shipping
%   a unit database is not what W10 asks for, and it rejects anything
%   whose shape is wrong, such as an unbalanced parenthesis, a
%   dangling operator or an exponent with no base.
%
%   The grammar accepted is
%
%       expression := term { ("/" | "*" | "." | " ") term }
%       term       := factor [ ["^"] integer ]
%       factor     := symbol | number | "(" expression ")"
%
%   so "1", "m", "Pa", "m2", "W m-2", "m2 s-1", "kg/(m s)" and
%   "degree" all parse, and "kg/(m s" does not.
%
%   See also mestra.validate.

    methods (Static)

        function tf = parses(text)
        %parses  True when a unit string fits the grammar above.
        %
        %   mestra.internal.Units.parses('W m-2')   % true
        %   mestra.internal.Units.parses('kg/(m s') % false

            if ~ischar(text) && ~isstring(text)
                tf = false; return
            end
            text = char(text);
            if isempty(strtrim(text))
                tf = false; return
            end
            state.s = text;
            state.i = 1;
            try
                state = mestra.internal.Units.expression(state);
                state = mestra.internal.Units.skip(state);
                tf = state.i > numel(state.s);
            catch
                tf = false;
            end
        end

        function state = expression(state)
            state = mestra.internal.Units.term(state);
            while true
                save = state;
                state = mestra.internal.Units.skip(state);
                if state.i > numel(state.s)
                    return
                end
                c = state.s(state.i);
                if any(c == '*/.')
                    state.i = state.i + 1;
                    state = mestra.internal.Units.term(state);
                elseif mestra.internal.Units.startsFactor(state)
                    % Juxtaposition, as in "W m-2", is multiplication.
                    state = mestra.internal.Units.term(state);
                else
                    state = save;
                    return
                end
            end
        end

        function state = term(state)
            state = mestra.internal.Units.factor(state);
            if state.i <= numel(state.s) && state.s(state.i) == '^'
                state.i = state.i + 1;
                state = mestra.internal.Units.integer(state);
            elseif state.i <= numel(state.s) && ...
                   any(state.s(state.i) == '-+0123456789')
                state = mestra.internal.Units.integer(state);
            end
        end

        function state = factor(state)
            state = mestra.internal.Units.skip(state);
            if state.i > numel(state.s)
                error('mestra:units', 'unit string ends early');
            end
            c = state.s(state.i);
            if c == '('
                state.i = state.i + 1;
                state = mestra.internal.Units.expression(state);
                state = mestra.internal.Units.skip(state);
                if state.i > numel(state.s) || state.s(state.i) ~= ')'
                    error('mestra:units', 'unbalanced parenthesis');
                end
                state.i = state.i + 1;
            elseif mestra.internal.Units.isSymbolStart(c)
                while state.i <= numel(state.s) && ...
                      mestra.internal.Units.isSymbolChar(state.s(state.i))
                    state.i = state.i + 1;
                end
            elseif any(c == '0123456789')
                while state.i <= numel(state.s) && ...
                      any(state.s(state.i) == '0123456789.eE')
                    state.i = state.i + 1;
                end
            else
                error('mestra:units', 'unexpected character "%s"', c);
            end
        end

        function state = integer(state)
            start = state.i;
            if state.i <= numel(state.s) && any(state.s(state.i) == '-+')
                state.i = state.i + 1;
            end
            digits = 0;
            while state.i <= numel(state.s) && ...
                  any(state.s(state.i) == '0123456789')
                state.i = state.i + 1;
                digits = digits + 1;
            end
            if digits == 0
                state.i = start;
                error('mestra:units', 'exponent with no digits');
            end
        end

        function tf = startsFactor(state)
            c = state.s(state.i);
            tf = c == '(' || mestra.internal.Units.isSymbolStart(c) || ...
                 any(c == '0123456789');
        end

        function state = skip(state)
            while state.i <= numel(state.s) && state.s(state.i) == ' '
                state.i = state.i + 1;
            end
        end

        function tf = isSymbolStart(c)
            tf = isletter(c) || c == '_' || double(c) == 176;
        end

        function tf = isSymbolChar(c)
            tf = isletter(c) || c == '_' || double(c) == 176 || c == '%';
        end
    end
end
