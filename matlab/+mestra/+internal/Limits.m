classdef Limits
%Limits  What this reader refuses to do for a file it did not write.
%
%   A file is untrusted input.  Its declared shapes, its nesting, its
%   links and its string sizes are numbers someone else chose, and a
%   reader that follows them wherever they lead can be made to
%   exhaust memory or run forever without the file ever being large.
%   Every limit here is a number this package will not go past; each
%   one raises mestra:reader in the reader and records an
%   unclassified finding (U03) in the validator.
%
%   The defaults are deliberately generous for real data and far below
%   what a hostile file asks for:
%
%     maxElements   134217728   elements in one read, which is one
%                               gibibyte of float64
%     maxDepth      64          levels of group nesting a walk follows
%     maxObjects    200000      objects a walk visits in one file
%     maxStringSize 65536       bytes in one fixed-length string
%
%   Raise one when a real file needs it:
%
%       old = mestra.limits('maxElements', 2^31);
%       ...
%       mestra.limits(old);            % put it back
%
%   See also mestra.limits, mestra.read, mestra.validate.

    methods (Static)

        function value = get(name)
        %get  One limit, or the whole struct when given no name.
            state = mestra.internal.Limits.store();
            if nargin == 0
                value = state;
            elseif isfield(state, name)
                value = state.(name);
            else
                error('mestra:limits', 'there is no limit called "%s"', name);
            end
        end

        function previous = set(name, value)
        %set  Change one limit and return what it was.
            state = mestra.internal.Limits.store();
            if ~isfield(state, name)
                error('mestra:limits', 'there is no limit called "%s"', name);
            end
            if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value) || ...
               value < 1
                error('mestra:limits', ...
                      'the limit "%s" must be a finite number of at least 1', ...
                      name);
            end
            previous = state.(name);
            state.(name) = double(value);
            mestra.internal.Limits.store(state);
        end

        function reset()
        %reset  Put every limit back to its default.
            mestra.internal.Limits.store(mestra.internal.Limits.defaults());
        end

        function s = defaults()
        %defaults  The documented numbers above.
            s = struct('maxElements', 134217728, ...
                       'maxDepth', 64, ...
                       'maxObjects', 200000, ...
                       'maxStringSize', 65536);
        end

        function checkElements(count, what)
        %checkElements  Refuse a read that would materialise too much.
            limit = mestra.internal.Limits.get('maxElements');
            if count > limit
                error('mestra:reader', ...
                      ['%s declares %s elements and this reader will ' ...
                       'materialise at most %d in one read. Nothing was ' ...
                       'read. Raise the limit with mestra.limits if the ' ...
                       'file is genuinely that large.'], ...
                      what, mestra.internal.Limits.count(count), limit);
            end
        end

        function text = count(n)
        %count  A large count as text, without losing precision.
            if n < 1e15
                text = sprintf('%.0f', n);
            else
                text = sprintf('%g', n);
            end
        end

        function state = store(newState)
        %store  The settings themselves, built on first use.
            persistent current
            if nargin >= 1
                current = newState;
            elseif isempty(current)
                current = mestra.internal.Limits.defaults();
            end
            state = current;
        end
    end
end
