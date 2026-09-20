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
    out.nRows = nRows;
    for i = 1:numel(out.keys)
        name = out.keys(i).name;
        column = keysTable.(name);
        if iscell(column) || isstring(column)
            out.keys(i).values = reshape(cellstr(column), 1, []);
        else
            out.keys(i).values = reshape(column, 1, []);
        end
    end
    if ~isempty(out.rowSupport) && numel(out.rowSupport) ~= nRows
        out.rowSupport = [];
    end

    results = containers.Map('KeyType', 'char', 'ValueType', 'any');
    for i = 1:numel(out.scalars)
        out.scalars(i) = fill(out, results, out.scalars(i), ...
                              ['/scalars/' out.scalars(i).name], ...
                              keysTable, nRows, {'row'});
    end
    for i = 1:numel(out.supports)
        s = out.supports(i);
        base = ['/supports/' s.name];
        if ~isempty(s.coordinates)
            s.coordinates = fill(out, results, s.coordinates, ...
                [base '/coordinates'], keysTable, nRows, ...
                {'row', 'node', 'component'});
        end
        for j = 1:numel(s.nodeArrays)
            s.nodeArrays(j) = fill(out, results, s.nodeArrays(j), ...
                [base '/node_arrays/' s.nodeArrays(j).name], keysTable, ...
                nRows, {'row', 'node', 'component'});
        end
        for j = 1:numel(s.cellArrays)
            s.cellArrays(j) = fill(out, results, s.cellArrays(j), ...
                [base '/cell_arrays/' s.cellArrays(j).name], keysTable, ...
                nRows, {'row', 'cell', 'component'});
        end
        out.supports(i) = s;
    end
    out.callables = mestra.Dataset.emptyCallable();
end

% ---------------------------------------------------------------------

function slot = fill(d, results, slot, path, keysTable, nRows, fileDims)
%fill  One slot: call its callable, or check the data it already has.
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
