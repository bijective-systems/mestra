function out = prediction(dataset, slot, keysTable)
%MESTRA.PREDICTION  One slot as a prediction: its mean with its band.
%
%   P = MESTRA.PREDICTION(DATASET, SLOT) returns the prediction record
%   of specification section 10 for a slot whose statistic is value or
%   mean, or none: a struct with the fields mean, uncertainty, level
%   and method, the same one a callable's call returns (see
%   mestra.Callable).  For a slot holding data the mean is its values
%   and the band is the band slot at the same location that names it
%   with `of`, if there is one.  For a slot a callable serves, the
%   callable is called on the file's own key columns and its record
%   for the slot's output is returned as it is.
%
%   P = MESTRA.PREDICTION(DATASET, SLOT, KEYSTABLE) calls the callable
%   on KEYSTABLE instead, which is the only way for a file with no
%   rows.  A slot holding data has values on its own rows only, so
%   KEYSTABLE is an error for one.
%
%   Either way the caller gets the same record and never has to know
%   which it was.  The mean and the uncertainty are mestra.Array with
%   the file's own axis order.
%
%   See also mestra.Callable, mestra.evaluate, mestra.fieldStatistics.

    mestra.internal.Post.dataset(dataset, 'prediction');
    found = mestra.internal.Post.findSlot(dataset, slot, 'prediction');
    s = found.slot;
    statistic = '';
    if isfield(s, 'statistic'), statistic = s.statistic; end
    if strcmp(statistic, 'band')
        error('mestra:prediction', ...
              ['"%s" is the band of "%s"; name the base slot and the ' ...
               'band comes with it'], found.path, s.of);
    end
    if ~(isempty(statistic) || any(strcmp(statistic, {'value', 'mean'})))
        error('mestra:prediction', ...
              ['"%s" holds the %s of "%s", which is stored data about ' ...
               'stored data and not a prediction; name the base slot'], ...
              found.path, statistic, s.of);
    end

    if numel(s.source) > 9 && strncmp(s.source, 'callable:', 9)
        id = s.source(10:end);
        record = dataset.callable(id);
        if isempty(record.obj)
            error('mestra:prediction', ...
                  ['the callable "%s" has type "%s" and no object built ' ...
                   'from it; read the file with mestra.read and register ' ...
                   'the type with mestra.Registry.register'], ...
                  id, record.type);
        end
        if nargin < 3
            if dataset.nRows == 0
                error('mestra:prediction', ...
                      ['this file has no rows to evaluate "%s" on; pass ' ...
                       'a keys table with one column per key'], found.path);
            end
            keysTable = ownKeys(dataset);
        end
        produced = record.obj.call(keysTable);
        output = s.output;
        if isempty(output), output = s.name; end
        if ~produced.isKey(output)
            error('mestra:prediction', ...
                  'the callable "%s" produces no output named "%s"', ...
                  id, output);
        end
        out = produced(output);
        if ~isstruct(out) || ~isfield(out, 'mean')
            error('mestra:prediction', ...
                  ['the callable "%s" returned something that is not a ' ...
                   'prediction for output "%s" (section 10)'], id, output);
        end
        return
    end

    if nargin >= 3
        error('mestra:prediction', ...
              ['"%s" holds stored data, which has values on its own ' ...
               'rows only; omit the keys table, or name a slot a ' ...
               'callable serves'], found.path);
    end
    band = bandOf(dataset, found);
    if isempty(band)
        out = mestra.Callable.prediction(toArray(s));
    else
        out = mestra.Callable.prediction(toArray(s), toArray(band), ...
                                         band.level, band.method);
    end
end

% ---------------------------------------------------------------------

function t = ownKeys(d)
%ownKeys  The file's key columns as a keys table (section 26).
    names = d.keyNames();
    columns = cell(1, numel(names));
    for i = 1:numel(names)
        v = d.key(names{i}).values;
        columns{i} = reshape(v, [], 1);
    end
    t = table(columns{:}, 'VariableNames', names);
end

function band = bandOf(d, found)
%bandOf  The stored band slot at the same location that names `found`.
    band = [];
    if strcmp(found.kind, 'scalar')
        candidates = d.scalars;
    else
        s = d.support(found.support);
        if strcmp(found.kind, 'cell')
            candidates = s.cellArrays;
        else
            candidates = s.nodeArrays;
        end
    end
    for i = 1:numel(candidates)
        c = candidates(i);
        if isfield(c, 'statistic') && strcmp(c.statistic, 'band') && ...
                strcmp(c.of, found.slot.name) && strcmp(c.source, 'data')
            band = c;
            return
        end
    end
end

function a = toArray(slot)
%toArray  A stored slot's values as a mestra.Array in the file's axis
%   order.  The reader holds an array with its axes reversed from the
%   file's, so the file's shape is the reversed size and the data is
%   the reversed permutation; a scalar is one column of rows.
    values = double(slot.values);
    n = numel(slot.dims);
    if n <= 1
        a = mestra.Array(values(:), numel(values));
        return
    end
    sz = size(values);
    sz = [sz ones(1, n - numel(sz))];
    shape = fliplr(sz(1:n));
    a = mestra.Array(builtin('permute', values, n:-1:1), shape);
end
