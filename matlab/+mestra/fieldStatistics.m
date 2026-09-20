function out = fieldStatistics(dataset, slot, varargin)
%MESTRA.FIELDSTATISTICS  Per-row statistics of a field, optionally
%   grouped by a label.
%
%   T = MESTRA.FIELDSTATISTICS(DATASET, SLOT) returns a table with
%   one line per row of the file, holding the count, minimum,
%   maximum, mean and standard deviation of that slot's values over
%   the nodes or the cells of its support.
%
%   T = MESTRA.FIELDSTATISTICS(DATASET, SLOT, 'By', LABEL) groups by
%   a label array on the same support and gives one line per row and
%   per group.  The grouping column is named after the label, never
%   after a fixed word, and there is no grouping column at all when
%   'By' is not given (docs/api-conventions.md, section 4).  A label
%   with a category table is reported by its entries; one without is
%   reported by its own integer values, which section 3 says are
%   their own categories.
%
%   A field of more than one component gets a `component` column,
%   counted from 1 as MATLAB counts.  A field of one component does
%   not, because a column of ones tells nobody anything.
%
%   A scalar may be named too, and is reported over the rows: the
%   whole of a scalars-only file is still a thing to take statistics
%   of.  'By' then names a categorical, group, split or status key,
%   because a scalar has no support and therefore no label.
%
%   Example
%
%       d = mestra.read('family.mes');
%       t = mestra.fieldStatistics(d, 'pressure', 'By', 'cad_face_id');
%       t(1:3, :)
%       ans =
%         row    cad_face_id    count    min    max    mean    std
%         ___    ___________    _____    ___    ___    ____    ___
%          0        "11"          2      101    104    102.5   ...
%
%   Row indices are the file's, counted from 0, so that a line of
%   this table and a line of a validator report name the same row.
%
%   See also mestra.integrate, mestra.timeSeries, mestra.groupedSplit.

    p = inputParser();
    p.addParameter('By', '');
    p.parse(varargin{:});
    by = char(p.Results.By);

    mestra.internal.Post.dataset(dataset, 'fieldStatistics');
    found = mestra.internal.Post.findSlot(dataset, slot, 'fieldStatistics');
    if strcmp(found.kind, 'scalar')
        out = scalarStatistics(dataset, found.slot, by);
        return
    end

    field = found.slot;
    support = found.support;
    [labelValues, labelEntries] = findLabel(dataset, support, ...
                                            field.location, by);

    components = max(double(field.components), 1);
    nRows = max(dataset.nRows, 1);
    rows = {};
    for i = 1:nRows
        v = reshape(mestra.internal.Post.perRow(field, dataset, i), ...
                    components, []);
        if isempty(by)
            groups = {[], ''};
        else
            if numel(labelValues) ~= size(v, 2)
                error('mestra:E05', ...
                      ['E05: %s: the label "%s" has %d values and the ' ...
                       'field has %d %ss; they are not on the same ' ...
                       'support'], found.path, by, numel(labelValues), ...
                      size(v, 2), field.location);
            end
            ids = unique(labelValues);
            groups = cell(numel(ids), 2);
            for g = 1:numel(ids)
                groups{g, 1} = labelValues == ids(g);
                groups{g, 2} = mestra.internal.Post.label(labelEntries, ...
                                                          ids(g));
            end
        end
        for g = 1:size(groups, 1)
            mask = groups{g, 1};
            for c = 1:components
                if isempty(mask)
                    x = double(v(c, :));
                else
                    x = double(v(c, mask));
                end
                rows{end + 1} = lineOf(i - 1, groups{g, 2}, c, x); %#ok<AGROW>
            end
        end
    end

    out = assemble(rows, by, components > 1);
end

function out = scalarStatistics(d, slot, by)
%scalarStatistics  A scalar over its rows, grouped by a key.
    v = double(reshape(slot.values, 1, []));
    if isempty(by)
        out = assemble({lineOf([], '', 1, v)}, '', false);
        return
    end
    k = d.key(by);
    if isempty(k)
        error('mestra:fieldStatistics', ...
              ['a scalar has no support and therefore no label, so ' ...
               '''By'' names a key; this file has no key called "%s" ' ...
               '(it has %s)'], by, mestra.internal.Post.listOf(d.keyNames()));
    end
    if ~any(strcmp(k.role, {'categorical', 'group', 'split', 'status'}))
        error('mestra:fieldStatistics', ...
              ['the key "%s" has role %s and cannot group anything; ' ...
               'group by a categorical, group, split or status key'], ...
              by, k.role);
    end
    ids = double(reshape(k.values, 1, []));
    entries = mestra.internal.Post.categoryOf(d, k.category);
    rows = {};
    for id = unique(ids)
        rows{end + 1} = lineOf([], mestra.internal.Post.label(entries, id), ...
                               1, v(ids == id)); %#ok<AGROW>
    end
    out = assemble(rows, by, false);
end

function line = lineOf(row, group, component, x)
    x = double(x(:)');
    finite = x(isfinite(x));
    line = struct();
    line.row = row;
    line.group = group;
    line.component = component;
    line.count = numel(x);
    if isempty(finite)
        line.min = NaN;
        line.max = NaN;
        line.mean = NaN;
        line.std = NaN;
    else
        line.min = min(finite);
        line.max = max(finite);
        line.mean = mean(finite);
        if numel(finite) > 1
            line.std = std(finite);
        else
            line.std = 0;
        end
    end
end

function t = assemble(rows, by, withComponent)
%assemble  The lines as a table, with the grouping column named after
%   the label and left out when there is none.
    n = numel(rows);
    names = {};
    cols = {};
    haveRow = n > 0 && ~isempty(rows{1}.row);
    if haveRow
        names{end + 1} = 'row';
        cols{end + 1} = cellfun(@(r) r.row, rows)';
    end
    if ~isempty(by)
        names{end + 1} = matlab.lang.makeValidName(by);
        cols{end + 1} = string(cellfun(@(r) r.group, rows, ...
                                       'UniformOutput', false))';
    end
    if withComponent
        names{end + 1} = 'component';
        cols{end + 1} = cellfun(@(r) r.component, rows)';
    end
    for f = {'count', 'min', 'max', 'mean', 'std'}
        names{end + 1} = f{1}; %#ok<AGROW>
        cols{end + 1} = cellfun(@(r) r.(f{1}), rows)'; %#ok<AGROW>
    end
    if n == 0
        t = table.empty(0, numel(names));
        t.Properties.VariableNames = names;
        return
    end
    t = table(cols{:}, 'VariableNames', names);
end

function [values, entries] = findLabel(d, support, location, by)
%findLabel  The label array named by 'By', on the same support and at
%   the same location as the field.
    values = [];
    entries = {};
    if isempty(by), return, end
    i = find(strcmp({d.supports.name}, support), 1);
    s = d.supports(i);
    if strcmp(location, 'cell')
        slots = s.cellArrays;
    else
        slots = s.nodeArrays;
    end
    j = [];
    if ~isempty(slots)
        j = find(strcmp({slots.name}, by), 1);
    end
    if isempty(j)
        error('mestra:fieldStatistics', ...
              ['there is no array called "%s" on the %ss of "%s"; it ' ...
               'has %s'], by, location, support, ...
              mestra.internal.Post.listOf({slots.name}));
    end
    label = slots(j);
    if ~strcmp(label.role, 'label')
        error('mestra:fieldStatistics', ...
              ['"%s" has role %s and cannot group anything; ''By'' ' ...
               'names an array of role label'], by, label.role);
    end
    values = double(reshape(label.values, 1, []));
    entries = mestra.internal.Post.categoryOf(d, label.category);
end
