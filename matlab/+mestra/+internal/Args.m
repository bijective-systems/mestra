classdef Args
%Args  Peel positional arguments off a builder's varargin.
%
%   The cross-language conventions (docs/api-conventions.md, section
%   1) put a builder's arguments in one order in every language:
%
%       add_key(name, values, role, units)
%       add_scalar(name, values, units)
%       add_node_array(support, name, values, units, dims)
%
%   MATLAB's idiom is positional arguments first and name-value pairs
%   for the rest, so this package takes the order above positionally
%   and everything else as a name-value pair.  A positional argument
%   may also be given by name, so `addKey('mach', v, 'Units', '1')`
%   and `addKey('mach', v, 'condition', '1')` both work.
%
%   The rule that tells the two apart is decidable and stated in the
%   README: a character argument that is one of the call's parameter
%   names begins the name-value pairs, and anything before that is
%   positional.  The role vocabulary of specification section 3 and
%   the parameter names of this package do not overlap, and neither
%   does the UDUNITS grammar, so a role is never mistaken for a
%   parameter name and a unit is never mistaken for a role.
%
%   See also mestra.Dataset.

    properties (Constant)
        % The roles of specification section 3, by object.
        keyRoles = {'design', 'condition', 'time', 'categorical', ...
                    'group', 'split', 'id', 'status'}
        arrayRoles = {'coordinates', 'field', 'label', 'weight', ...
                      'normal', 'derived'}
    end

    methods (Static)

        function [vals, rest] = positional(args, specs, paramNames)
        %positional  Split ARGS into positional values and the rest.
        %
        %   SPECS is a cell array with one entry per positional slot,
        %   each {default, predicate}.  The positional run is every
        %   leading argument before the first one that names a
        %   parameter; the name-value pairs are the rest.
        %
        %   When the run is as long as SPECS, each argument fills its
        %   own slot and nothing is guessed at, so a role that is not
        %   a role reaches the caller as a role and is refused by
        %   name.  When it is shorter, an argument fills the first
        %   slot whose predicate accepts it, which is how an optional
        %   role can be left out: a unit is never a role and a role is
        %   never a unit.
            n = numel(specs);
            vals = cell(1, n);
            for i = 1:n
                vals{i} = specs{i}{1};
            end
            run = 0;
            while run < numel(args) && ...
                    ~mestra.internal.Args.isParamName(args{run + 1}, ...
                                                      paramNames)
                run = run + 1;
                if run > n, break, end
            end
            if run > n
                error('mestra:arguments', ...
                      ['this call takes %d positional argument(s) after ' ...
                       'the ones it names, and %d came in before the ' ...
                       'first name-value pair; the rest are name-value ' ...
                       'pairs'], n, run);
            end
            if run == n
                for i = 1:n
                    vals{i} = args{i};
                end
            else
                slot = 1;
                for i = 1:run
                    while slot <= n && ~specs{slot}{2}(args{i})
                        slot = slot + 1;
                    end
                    if slot > n
                        error('mestra:arguments', ...
                              ['nothing in this call takes the ' ...
                               'positional argument %d; name it, or ' ...
                               'check the order'], i);
                    end
                    vals{slot} = args{i};
                    slot = slot + 1;
                end
            end
            rest = args(run + 1:end);
        end

        function tf = isParamName(a, names)
        %isParamName  True when A is one of NAMES, ignoring case.
            tf = (ischar(a) && isrow(a)) || (isstring(a) && isscalar(a));
            if ~tf, return, end
            tf = any(strcmpi(char(a), names));
        end

        function tf = isKeyRole(a)
        %isKeyRole  True for a role of a key (section 3).
            tf = mestra.internal.Args.isOneOf(a, ...
                     mestra.internal.Args.keyRoles);
        end

        function tf = isArrayRole(a)
        %isArrayRole  True for a role of an array (section 3).
            tf = mestra.internal.Args.isOneOf(a, ...
                     mestra.internal.Args.arrayRoles);
        end

        function tf = isOneOf(a, set)
            tf = false;
            if isstring(a) && isscalar(a), a = char(a); end
            if ~(ischar(a) && isrow(a)), return, end
            tf = any(strcmp(a, set));
        end

        function tf = isText(a)
        %isText  True for a character row vector or a string scalar.
            tf = (ischar(a) && (isrow(a) || isempty(a))) || ...
                 (isstring(a) && isscalar(a));
        end

        function s = text(a)
        %text  A character row vector, whatever text form came in.
            if isstring(a), s = char(a); else, s = a; end
            if isempty(s), s = ''; end
        end

        function tf = isValues(a)
        %isValues  True for something that could be a column of data.
            tf = isnumeric(a) || islogical(a) || iscell(a) || isstring(a);
        end

        function names = parameterNames(p)
        %parameterNames  The parameter names an inputParser accepts.
            names = p.Parameters;
            names = reshape(names, 1, []);
        end
    end
end
