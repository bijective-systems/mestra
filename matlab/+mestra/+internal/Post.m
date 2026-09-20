classdef Post
%Post  The pieces the post-processing helpers share.
%
%   Finding a slot by name, splitting an array into its instances,
%   lining an array up with the rows, and composing units.  Nothing
%   here is public; mestra.fieldStatistics, mestra.integrate,
%   mestra.timeSeries, mestra.groupedSplit and mestra.computeWeights
%   are.
%
%   A name that is not in the file is a caller's mistake and not a
%   finding about the file, so it raises an error with no rule
%   identifier: the identifiers of section 14 say something about a
%   file, and a caller who catches one to detect a malformed file
%   must not catch a typo as well.
%
%   See also mestra.fieldStatistics, mestra.integrate.

    methods (Static)

        function d = dataset(d, who)
        %dataset  Refuse anything but a mestra.Dataset, by name.
            if ~isa(d, 'mestra.Dataset')
                error(['mestra:' who], ...
                      ['the first argument must be a mestra.Dataset; ' ...
                       'mestra.read gives you one']);
            end
        end

        function found = findSlot(d, name, who)
        %findSlot  One slot by name, across every support and the
        %   scalars, with the choice named when there is no such slot
        %   and when the name is ambiguous.
            if isstring(name), name = char(name); end
            all = d.slots();
            hit = find(strcmp(cellfun(@(s) s.name, {all.slot}, ...
                       'UniformOutput', false), name));
            if isempty(hit)
                error(['mestra:' who], ...
                      ['there is no slot called "%s" in this file; it ' ...
                       'has %s'], name, ...
                      mestra.internal.Post.listOf(...
                          cellfun(@(s) s.name, {all.slot}, ...
                                  'UniformOutput', false)));
            end
            if numel(hit) > 1
                error(['mestra:' who], ...
                      ['"%s" names %d slots in this file (%s); this ' ...
                       'call takes one, so name the support it is on'], ...
                      name, numel(hit), ...
                      mestra.internal.Post.listOf({all(hit).path}));
            end
            found = all(hit);
        end

        function [parts, axis] = instances(slot)
        %instances  A slot's values as one matrix per instance.
        %
        %   The instance axis is the trailing one in MATLAB order, and
        %   is `row`, `group:<k>` or absent.  Each part is
        %   (component-by-node|cell), with the draw axis, when there
        %   is one, left where it is.
            dims = slot.dims;
            axis = 0;
            for i = 1:numel(dims)
                if strcmp(dims{i}, 'row') || strncmp(dims{i}, 'group:', 6)
                    axis = i;
                end
            end
            v = slot.values;
            if axis == 0
                parts = {v};
                return
            end
            n = size(v, axis);
            parts = cell(1, n);
            subs = repmat({':'}, 1, max(numel(dims), ndims(v)));
            for k = 1:n
                s = subs;
                s{axis} = k;
                parts{k} = squeezeTo(v(s{:}), axis);
            end
        end

        function v = perRow(slot, d, rowIndex)
        %perRow  The instance of a slot that applies to one row
        %   (one-based), whatever the slot varies along.
            parts = mestra.internal.Post.instances(slot);
            switch true
                case strcmp(slot.varies, 'none')
                    v = parts{1};
                case strcmp(slot.varies, 'row')
                    if rowIndex > numel(parts)
                        error('mestra:post', ...
                              ['the slot "%s" holds %d rows and row %d ' ...
                               'was asked for'], slot.name, ...
                              numel(parts), rowIndex);
                    end
                    v = parts{rowIndex};
                otherwise
                    key = slot.varies(7:end);
                    k = d.key(key);
                    if isempty(k) || isempty(k.values)
                        error('mestra:post', ...
                              ['the slot "%s" varies along the group ' ...
                               'key "%s" and the file declares no such ' ...
                               'column'], slot.name, key);
                    end
                    which = double(k.values(rowIndex)) + 1;
                    v = parts{which};
            end
        end

        function u = raise(units, power)
        %raise  A unit string raised to a whole power, for a measure.
        %
        %   The coordinates of a support are a length, so a measure is
        %   that length to the support's dimension.  A single symbol
        %   with an optional exponent is raised; anything else is
        %   refused rather than guessed at, and the caller says what
        %   to record.
            units = strtrim(char(units));
            if power == 0 || strcmp(units, '1') || isempty(units)
                u = '1';
                return
            end
            if power == 1
                u = units;
                return
            end
            token = regexp(units, '^([A-Za-z_]+)(-?\d+)?$', 'tokens', 'once');
            if isempty(token)
                error('mestra:units', ...
                      ['the coordinates are in "%s", which this package ' ...
                       'cannot raise to the power %d; pass ''Units'' to ' ...
                       'say what the measure is in'], units, power);
            end
            symbol = token{1};
            exponent = 1;
            if numel(token) > 1 && ~isempty(token{2})
                exponent = str2double(token{2});
            end
            e = exponent * power;
            if e == 1
                u = symbol;
            else
                u = sprintf('%s%d', symbol, e);
            end
        end

        function u = times(a, b)
        %times  The units of a product, in the UDUNITS grammar CF
        %   uses: a space between the two, and nothing at all when one
        %   of them is dimensionless.
            a = strtrim(char(a));
            b = strtrim(char(b));
            if isempty(a) || strcmp(a, '1'), u = b; return, end
            if isempty(b) || strcmp(b, '1'), u = a; return, end
            u = [a ' ' b];
            if isempty(u), u = '1'; end
        end

        function s = listOf(names)
        %listOf  A readable list of what the file does have.
            names = unique(reshape(names, 1, []));
            if isempty(names)
                s = 'none';
            elseif numel(names) <= 8
                s = strjoin(names, ', ');
            else
                s = [strjoin(names(1:8), ', ') ...
                     sprintf(' and %d more', numel(names) - 8)];
            end
        end

        function k = groupKeyOf(d, varies)
        %groupKeyOf  The key a `group:<k>` names.
            k = '';
            if numel(varies) > 6 && strncmp(varies, 'group:', 6)
                k = varies(7:end);
            end
        end

        function entries = categoryOf(d, name)
        %categoryOf  A category table by name, or {} when there is
        %   none.
            entries = {};
            if isempty(name), return, end
            i = find(strcmp({d.categories.name}, name), 1);
            if ~isempty(i)
                entries = d.categories(i).entries;
            end
        end

        function s = label(entries, id)
        %label  What a category id is called, or the id itself.
            j = double(id) + 1;
            if ~isempty(entries) && j >= 1 && j <= numel(entries)
                s = entries{j};
            else
                s = sprintf('%d', double(id));
            end
        end
    end
end

function v = squeezeTo(v, axis)
%squeezeTo  Drop one axis that has just been indexed to length one,
%   keeping every other axis where it was.
    sz = size(v);
    if axis <= numel(sz)
        sz(axis) = [];
    end
    if numel(sz) < 2
        sz = [sz ones(1, 2 - numel(sz))];
    end
    v = reshape(v, sz);
end
