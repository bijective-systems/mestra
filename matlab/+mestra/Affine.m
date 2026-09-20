classdef Affine < mestra.Callable
%mestra.Affine  The reference callable of specification section 27.
%
%   For each output slot it serves, with x the vector of key values in
%   the declared key order,
%
%       y = A x + b
%
%   and y is reshaped to the slot's shape in C order.  It is
%   deterministic and produces no draws.  It exists so that the
%   protocol, the codec and evaluation can be conformance tested in
%   every language with no proprietary model.
%
%   Summation order.  The dot product is accumulated over the keys in
%   the declared key order and b is added last, with no fused
%   multiply-add.  The order matters: the corpus compares float64
%   results bit for bit and the other orders differ in the last place.
%   This class therefore uses explicit loops in double precision and
%   never a matrix-vector product, which would be free to reorder the
%   sums.
%
%   Example
%
%       A = mestra.Affine( ...
%           {'mach', 'alpha'}, ...
%           struct('cl', struct('A', [2.0 0.1], 'b', 0.05, 'shape', []), ...
%                  'pressure', struct('A', [1 0; 2 0; 3 0.5; 4 0.5; ...
%                                           5 1; 6 1], ...
%                                     'b', [0; 0.1; 0.2; 0.3; 0.4; 0.5], ...
%                                     'shape', [6 1])));
%       out = A.call(table(0.5, 4.0, 'VariableNames', {'mach', 'alpha'}));
%       out('cl').data      % 1.45
%
%   See also mestra.Callable, mestra.Registry, mestra.evaluate.

    properties
        % The declared key order: a cell array of key names.  x is
        % built by taking these columns from the keys table in this
        % order, and it is the callable's own order, not the file's.
        keys

        % A containers.Map from the value of a slot's `output`
        % attribute to a struct with fields A, b and shape.
        outputs

        % An optional one-line description.
        description = ''
    end

    methods
        function obj = Affine(keys, outputs, description)
        %Affine  Build an affine callable.
        %   `outputs` is a struct or a containers.Map whose entries
        %   each have A (n_out_flat by n_keys), b (n_out_flat) and
        %   shape (the slot's dimensions after the row dimension).
            if nargin == 0, return, end
            if ischar(keys), keys = {keys}; end
            if isstring(keys), keys = cellstr(keys); end
            obj.keys = keys(:)';
            obj.outputs = containers.Map('KeyType', 'char', ...
                                         'ValueType', 'any');
            if isstruct(outputs)
                names = fieldnames(outputs);
                for i = 1:numel(names)
                    obj.outputs(names{i}) = ...
                        mestra.Affine.normalise(outputs.(names{i}), ...
                                                numel(obj.keys), names{i});
                end
            else
                names = outputs.keys();
                for i = 1:numel(names)
                    obj.outputs(names{i}) = ...
                        mestra.Affine.normalise(outputs(names{i}), ...
                                                numel(obj.keys), names{i});
                end
            end
            if nargin >= 3
                obj.description = description;
            else
                sorted = mestra.internal.H5.sortByBytes( ...
                    obj.outputs.keys());
                obj.description = sprintf('affine(%s -> %s)', ...
                    strjoin(obj.keys, ', '), strjoin(sorted, ', '));
            end
        end

        function s = repr(obj)
        %repr  The one-line description.
            s = obj.description;
        end

        function out = call(obj, keysTable)
        %call  Evaluate every output on a keys table.
        %   `keysTable` is a MATLAB table whose variable names are the
        %   key names (section 26).  The result is a containers.Map
        %   from output name to a mestra.Array with the file's own
        %   axis order: (row, node | cell, component) for an array
        %   slot and (row) for a scalar slot.
            if ~istable(keysTable)
                error('mestra:keysTable', ...
                      'the keys table must be a MATLAB table (section 26)');
            end
            nRows = height(keysTable);
            nKeys = numel(obj.keys);
            x = zeros(nRows, nKeys);
            for k = 1:nKeys
                name = obj.keys{k};
                if ~ismember(name, keysTable.Properties.VariableNames)
                    error('mestra:keysTable', ...
                          'the keys table has no column "%s"', name);
                end
                column = keysTable.(name);
                if ~isnumeric(column)
                    error('mestra:keysTable', ...
                          'column "%s" is not numeric', name);
                end
                x(:, k) = double(column(:));
            end

            out = containers.Map('KeyType', 'char', 'ValueType', 'any');
            names = obj.outputs.keys();
            for i = 1:numel(names)
                entry = obj.outputs(names{i});
                A = entry.A;
                b = entry.b;
                shape = double(entry.shape(:)');
                nOut = size(A, 1);
                y = zeros(nRows, nOut);
                for r = 1:nRows
                    for j = 1:nOut
                        acc = 0;
                        for k = 1:nKeys
                            acc = acc + A(j, k) * x(r, k);
                        end
                        y(r, j) = acc + b(j);
                    end
                end
                if isempty(shape)
                    out(names{i}) = mestra.Array(y(:), nRows);
                else
                    full = zeros([nRows shape]);
                    subs = repmat({':'}, 1, numel(shape));
                    for r = 1:nRows
                        full(r, subs{:}) = ...
                            mestra.Affine.cReshape(y(r, :), shape);
                    end
                    out(names{i}) = mestra.Array(full, [nRows shape]);
                end
            end
        end

        function d = toDict(obj)
        %toDict  The dictionary of section 27, and nothing else.
            d = containers.Map('KeyType', 'char', 'ValueType', 'any');
            d('keys') = mestra.Array(reshape(obj.keys, [], 1), numel(obj.keys));
            outs = containers.Map('KeyType', 'char', 'ValueType', 'any');
            names = obj.outputs.keys();
            for i = 1:numel(names)
                entry = obj.outputs(names{i});
                one = containers.Map('KeyType', 'char', 'ValueType', 'any');
                one('A') = mestra.Array(entry.A, size(entry.A));
                one('b') = mestra.Array(entry.b(:), numel(entry.b));
                shape = int64(entry.shape(:));
                one('shape') = mestra.Array(shape, numel(shape));
                outs(names{i}) = one;
            end
            d('outputs') = outs;
        end
    end

    methods (Static)

        function obj = fromDict(d)
        %fromDict  Rebuild an affine callable from its dictionary.
            names = d.keys();
            extra = setdiff(names, {'keys', 'outputs'});
            if ~isempty(extra)
                error('mestra:affine', ...
                      ['an affine dictionary holds only keys and ' ...
                       'outputs; this one also holds %s (section 27)'], ...
                      strjoin(extra, ', '));
            end
            if ~all(ismember({'keys', 'outputs'}, names))
                error('mestra:affine', ...
                      'an affine dictionary needs keys and outputs');
            end
            keyList = d('keys');
            if isa(keyList, 'mestra.Array')
                keyList = keyList.data;
            end
            keyList = cellstr(keyList(:));
            outs = d('outputs');
            built = containers.Map('KeyType', 'char', 'ValueType', 'any');
            slotNames = outs.keys();
            for i = 1:numel(slotNames)
                one = outs(slotNames{i});
                entry.A = mestra.Affine.plain(one('A'));
                entry.b = mestra.Affine.plain(one('b'));
                entry.shape = double(mestra.Affine.plain(one('shape')));
                built(slotNames{i}) = entry;
            end
            obj = mestra.Affine(keyList, built);
        end

        function v = plain(value)
        %plain  The MATLAB array behind a dictionary leaf.
            if isa(value, 'mestra.Array')
                v = value.data;
            else
                v = value;
            end
        end

        function out = cReshape(v, shape)
        %cReshape  Reshape a flat vector to `shape` in C order.
            if numel(shape) <= 1
                out = reshape(v, [shape 1]);
                return
            end
            out = reshape(v, fliplr(shape));
            out = builtin('permute', out, numel(shape):-1:1);
        end

        function entry = normalise(entry, nKeys, name)
        %normalise  Check and square up one output entry.
            if ~isstruct(entry) || ...
               ~all(isfield(entry, {'A', 'b', 'shape'}))
                error('mestra:affine', ...
                      'output "%s" needs A, b and shape', name);
            end
            entry.A = double(entry.A);
            entry.b = double(entry.b(:));
            entry.shape = double(entry.shape(:)');
            nOut = max(prod(entry.shape), 1);
            if isempty(entry.shape), nOut = 1; end
            if size(entry.A, 1) ~= nOut || size(entry.A, 2) ~= nKeys
                error('mestra:affine', ...
                      ['output "%s" has A of size %s where shape %s and ' ...
                       '%d keys need %d by %d'], name, ...
                      mat2str(size(entry.A)), mat2str(entry.shape), ...
                      nKeys, nOut, nKeys);
            end
            if numel(entry.b) ~= nOut
                error('mestra:affine', ...
                      'output "%s" has b of length %d where %d is needed', ...
                      name, numel(entry.b), nOut);
            end
        end
    end
end
