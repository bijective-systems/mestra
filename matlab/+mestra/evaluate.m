function out = evaluate(dataset, keysTable)
%MESTRA.EVALUATE  Materialise a dataset's callable slots on a keys table.
%
%   OUT = MESTRA.EVALUATE(DATASET, KEYSTABLE) returns a new
%   mestra.Dataset with the same slots as DATASET, every slot that was
%   served by a callable now holding data, and the key columns holding
%   the rows of KEYSTABLE.  Specification section 10 calls this
%   evaluating the file on a keys table; doing it on a grid is
%   distillation.
%
%   KEYSTABLE is a MATLAB table whose variable names are the key names
%   (section 26).  Its row order is the evaluation order: output row i
%   is the result for table row i.  Every key the file declares must
%   have a column; other columns are passed through to the callables,
%   which read the columns they declare and ignore the rest.
%
%   DATASET is not changed.  A slot that already held data is carried
%   over unchanged when it does not vary along `row`; when it does,
%   its row count must match the table, and an error names the slot if
%   it does not.
%
%   The result has no callables: every callable slot now holds data,
%   so there is nothing left for one to serve, and the written file
%   has no `/callables` group at all rather than an empty one
%   (docs/api-conventions.md, section 7).
%
%   Example
%
%       d = mestra.read('affine_zero_rows.mes');
%       t = table(0.5, 4.0, 'VariableNames', {'mach', 'alpha'});
%       e = mestra.evaluate(d, t);
%       e.scalar('cl').values                    % 1.45
%       a = e.nodeArray('s0', 'pressure');
%       mestra.permute(a.values, a.dims, {'row', 'node'})
%
%   See also mestra.Callable, mestra.Affine, mestra.read, mestra.write.

    if ~isa(dataset, 'mestra.Dataset')
        error('mestra:evaluate', ...
              'the first argument must be a mestra.Dataset');
    end
    if ~istable(keysTable)
        error('mestra:keysTable', ...
              'the keys table must be a MATLAB table (section 26)');
    end
    nRows = height(keysTable);
    declared = dataset.keyNames();
    missing = setdiff(declared, keysTable.Properties.VariableNames);
    if ~isempty(missing)
        error('mestra:keysTable', ...
              'the keys table has no column for %s', strjoin(missing, ', '));
    end

    out = copyDataset(dataset);
    out.path = '';
    rerowed = nRows ~= dataset.nRows;
    out.nRows = nRows;
    for i = 1:numel(out.keys)
        name = out.keys(i).name;
        column = keysTable.(name);
        if iscell(column) || isstring(column)
            out.keys(i).values = reshape(cellstr(column), 1, []);
        else
            out.keys(i).values = reshape(column, 1, []);
        end
        if rerowed, out.keys(i).chunk = []; end
    end
    if ~isempty(out.rowSupport) && numel(out.rowSupport) ~= nRows
        out.rowSupport = [];
    end

    results = containers.Map('KeyType', 'char', 'ValueType', 'any');
    for i = 1:numel(out.scalars)
        out.scalars(i) = fill(out, results, out.scalars(i), ...
                              ['/scalars/' out.scalars(i).name], ...
                              keysTable, nRows, {'row'}, rerowed);
    end
    for i = 1:numel(out.supports)
        s = out.supports(i);
        base = ['/supports/' s.name];
        if ~isempty(s.coordinates)
            s.coordinates = fill(out, results, s.coordinates, ...
                [base '/coordinates'], keysTable, nRows, ...
                {'row', 'node', 'component'}, rerowed);
        end
        for j = 1:numel(s.nodeArrays)
            s.nodeArrays(j) = fill(out, results, s.nodeArrays(j), ...
                [base '/node_arrays/' s.nodeArrays(j).name], keysTable, ...
                nRows, {'row', 'node', 'component'}, rerowed);
        end
        for j = 1:numel(s.cellArrays)
            s.cellArrays(j) = fill(out, results, s.cellArrays(j), ...
                [base '/cell_arrays/' s.cellArrays(j).name], keysTable, ...
                nRows, {'row', 'cell', 'component'}, rerowed);
        end
        out.supports(i) = s;
    end
    % Section 7 of docs/api-conventions.md: evaluating turns every
    % callable slot into a stored slot, so the result has no callable
    % to keep and the `/callables` group is absent from the file, not
    % present and empty.  Dropping the callables is not enough on its
    % own: the writer also writes a group the file it came from
    % carried, so the group has to go from `groupsPresent` too.
    out.callables = mestra.Dataset.emptyCallable();
    out.groupsPresent = setdiff(out.groupsPresent, {'callables'}, 'stable');
end

% ---------------------------------------------------------------------

function slot = fill(d, results, slot, path, keysTable, nRows, fileDims, ...
                     rerowed)
%fill  One slot: call its callable, or check the data it already has.
%   With REROWED true the file being made has a different row count
%   from the one it was read from, so a chunk shape carried over from
%   that file is measured against a row count that is no longer the
%   one it has.  Section 23 measures the default against the length of
%   the row dimension the leading axis is attached to, so the chunk is
%   dropped and the writer computes the default for the new count; a
%   chunk that is not the default is W12 and no file this package
%   writes should draw one.
    if rerowed && isfield(slot, 'chunk') && ...
            ~isempty(slot.dims) && strcmp(slot.dims{end}, 'row')
        slot.chunk = [];
    end
    if strcmp(slot.source, 'data')
        if strcmp(slot.varies, 'row') && ~isempty(slot.values)
            n = size(slot.values, numel(slot.dims));
            if n ~= nRows
                error('mestra:evaluate', ...
                      ['the slot "%s" holds %d rows of data and the keys ' ...
                       'table has %d; drop it or pass a matching table'], ...
                      path, n, nRows);
            end
        end
        return
    end
    [id, output] = splitSource(slot.source, slot.output, path);
    if ~results.isKey(id)
        record = d.callable(id);
        if isempty(record.obj)
            if ~isempty(record.type) && mestra.Registry.isKnown(record.type)
                % The type is one this package can build, so what is
                % missing is the dictionary to build it from.  A
                % dataset from mestra.open has none, because an open
                % does not read one (docs/api-conventions.md, section
                % 7); a dataset from mestra.read has one that would
                % not build.
                error('mestra:evaluate', ...
                      ['the callable "%s" has type "%s" and no object ' ...
                       'built from it. A dataset from mestra.open ' ...
                       'carries no dictionary, because an open does ' ...
                       'not read one: read the file with mestra.read ' ...
                       'to evaluate it. If it was read, the ' ...
                       'dictionary does not describe a %s'], ...
                      id, record.type, record.type);
            end
            error('mestra:evaluate', ...
                  ['the callable "%s" has type "%s", which no registered ' ...
                   'type can evaluate; register it with ' ...
                   'mestra.Registry.register'], id, record.type);
        end
        results(id) = record.obj.call(keysTable);
    end
    produced = results(id);
    if ~produced.isKey(output)
        error('mestra:evaluate', ...
              'the callable "%s" produces no output named "%s"', id, output);
    end
    value = produced(output);
    slot.source = 'data';
    slot.output = '';
    slot.dtype = 'float64';
    if numel(fileDims) == 1
        slot.values = reshape(double(value.buffer()), 1, []);
        slot.dims = {'row'};
    else
        buf = double(value.buffer());
        slot.values = reshape(buf, [fliplr(value.shape) 1 1]);
        slot.dims = fliplr(fileDims);
        if isempty(slot.components)
            slot.components = size(slot.values, 1);
        end
    end
    if isfield(slot, 'shape')
        sz = size(slot.values);
        sz = [sz ones(1, numel(slot.dims) - numel(sz))];
        slot.shape = fliplr(sz(1:numel(slot.dims)));
    end
end

function [id, output] = splitSource(source, output, path)
    if numel(source) <= 9 || ~strncmp(source, 'callable:', 9)
        error('mestra:E36', ...
              'the slot "%s" has source "%s"', path, source);
    end
    id = source(10:end);
    if isempty(output)
        error('mestra:E39', ...
              'the slot "%s" names a callable and no output', path);
    end
end

function out = copyDataset(d)
%copyDataset  A fresh Dataset with the same contents.
    out = mestra.Dataset();
    out.format = d.format;
    out.writer = d.writer;
    out.created = d.created;
    out.aligned = d.aligned;
    out.generalisationGroup = d.generalisationGroup;
    out.nRows = d.nRows;
    out.keys = d.keys;
    out.scalars = d.scalars;
    out.categories = d.categories;
    out.supports = d.supports;
    out.callables = d.callables;
    out.rowSupport = d.rowSupport;
    out.notes = d.notes;
    out.privateTree = d.privateTree;
    out.unknownGroups = d.unknownGroups;
    out.skipped = d.skipped;
    if d.unknownAttrs.Count > 0
        out.unknownAttrs = containers.Map(d.unknownAttrs.keys(), ...
                                          d.unknownAttrs.values());
    end
    out.groupsPresent = d.groupsPresent;
end
