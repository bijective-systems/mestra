function out = timeSeries(dataset, slot, node, trajectory)
%MESTRA.TIMESERIES  One node's history through one trajectory.
%
%   T = MESTRA.TIMESERIES(DATASET, SLOT, NODE, TRAJECTORY) returns a
%   table of the values of SLOT at node NODE, for the rows that
%   belong to trajectory TRAJECTORY, in time order.
%
%   NODE is counted from 1, as MATLAB counts, and is a cell index
%   when the slot is a cell array.  TRAJECTORY names a category of
%   the group key that the time key declares as its trajectory group
%   (section 7), by its entry in the category table or by its integer
%   id.  It may be left out in a file whose rows are one trajectory.
%
%   The table has
%
%       row        the file's row index, counted from 0
%       time       the time key's value for that row
%       value      the slot's value at that node: one column per
%                  component
%
%   The rows come back in increasing time, which for a conforming
%   file is the order they are stored in: E09 makes time strictly
%   increasing within a trajectory.
%
%   Example
%
%       d = mestra.read('transient.mes');
%       t = mestra.timeSeries(d, 'pressure', 4, 'run_a');
%       plot(t.time, t.value);
%
%   A file with no key of role time has no time series in it, and
%   this call says so rather than inventing an order.
%
%   See also mestra.fieldStatistics, mestra.integrate.

    if nargin < 4, trajectory = []; end
    mestra.internal.Post.dataset(dataset, 'timeSeries');
    found = mestra.internal.Post.findSlot(dataset, slot, 'timeSeries');

    timeKey = keyOfRole(dataset, 'time');
    if isempty(timeKey)
        error('mestra:timeSeries', ...
              ['this file declares no key of role time, so it has no ' ...
               'time series; section 3 makes the time key the one ' ...
               'thing that orders rows within a trajectory']);
    end
    times = double(reshape(timeKey.values, 1, []));

    rows = 1:numel(times);
    if ~isempty(timeKey.trajectoryGroup)
        g = dataset.key(timeKey.trajectoryGroup);
        if isempty(g)
            error('mestra:timeSeries', ...
                  ['the time key names "%s" as its trajectory group ' ...
                   'and the file declares no such key'], ...
                  timeKey.trajectoryGroup);
        end
        ids = double(reshape(g.values, 1, []));
        entries = mestra.internal.Post.categoryOf(dataset, g.category);
        wanted = resolve(trajectory, entries, ids, timeKey.trajectoryGroup);
        rows = find(ids == wanted);
    elseif ~isempty(trajectory)
        error('mestra:timeSeries', ...
              ['the time key declares no trajectory group, so every ' ...
               'row of this file is one trajectory and "%s" names ' ...
               'nothing; leave the trajectory out'], text(trajectory));
    end
    if isempty(rows)
        error('mestra:timeSeries', ...
              'no row belongs to that trajectory');
    end

    components = max(double(found.slot.components), 1);
    values = zeros(numel(rows), components);
    for i = 1:numel(rows)
        v = reshape(mestra.internal.Post.perRow(found.slot, dataset, ...
                                                rows(i)), components, []);
        if node < 1 || node > size(v, 2)
            error('mestra:timeSeries', ...
                  ['the slot "%s" has %d %ss and %d was asked for; ' ...
                   'nodes are counted from 1 here, as MATLAB counts'], ...
                  found.slot.name, size(v, 2), found.slot.location, node);
        end
        values(i, :) = v(:, node)';
    end

    t = times(rows);
    [t, order] = sort(t);
    out = table(reshape(rows(order) - 1, [], 1), reshape(t, [], 1), ...
                values(order, :), ...
                'VariableNames', {'row', 'time', 'value'});
    out.Properties.VariableUnits = {'', char(timeKey.units), ...
                                    char(found.slot.units)};
end

function k = keyOfRole(d, role)
    k = [];
    i = find(strcmp({d.keys.role}, role), 1);
    if ~isempty(i)
        k = d.keys(i);
    end
end

function id = resolve(trajectory, entries, ids, groupName)
%resolve  A trajectory named by its category entry or by its id.
    if isempty(trajectory)
        seen = unique(ids);
        if numel(seen) == 1
            id = seen;
            return
        end
        error('mestra:timeSeries', ...
              ['this file holds %d trajectories of "%s" (%s); name the ' ...
               'one you want'], numel(seen), groupName, ...
              mestra.internal.Post.listOf(arrayfun(...
                  @(v) mestra.internal.Post.label(entries, v), seen, ...
                  'UniformOutput', false)));
    end
    if isnumeric(trajectory)
        id = double(trajectory);
        return
    end
    name = text(trajectory);
    j = find(strcmp(entries, name), 1);
    if isempty(j)
        error('mestra:timeSeries', ...
              ['"%s" is not a category of the trajectory group "%s"; ' ...
               'it has %s'], name, groupName, ...
              mestra.internal.Post.listOf(entries));
    end
    id = j - 1;
end

function s = text(v)
    if isstring(v), s = char(v); elseif ischar(v), s = v; else
        s = sprintf('%g', double(v));
    end
end
