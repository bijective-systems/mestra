classdef Dataset < handle
%mestra.Dataset  One dataset in the open format: keys, scalars,
%   supports, arrays, categories and callables.
%
%   Why a handle class.  A dataset is built up a piece at a time, and
%   a value class would make every builder call a reassignment
%   (d = d.addKey(...)) and would copy every array it already holds.
%   A handle class lets the builder read the way people write it and
%   keeps the arrays in one place.  mestra.read and mestra.evaluate
%   each return a fresh object, so nothing is shared by accident.
%
%   AXIS ORDER.  HDF5 stores an array in C order and MATLAB is column
%   major, so every array this class holds has its axes REVERSED with
%   respect to the file.  The file's logical order is
%
%       (row | group | nothing, [draw], node | cell, component)
%
%   and a MATLAB array therefore comes back as
%
%       (component, node | cell, [draw], row | group)
%
%   Every array carries its dimension names in the same order as its
%   own axes, so you never have to count axes: permute by name.
%
%       a = d.nodeArray('s0', 'pressure');
%       p = mestra.permute(a.values, a.dims, {'row', 'node'});
%
%   Building one
%
%       d = mestra.Dataset();
%       d.addCategory('member', {'wing_a', 'wing_b'});
%       d.addKey('mach', 'condition', [0.4 0.8], 'Units', '1', ...
%                'Lower', 0.1, 'Upper', 0.9);
%       d.addKey('member', 'group', int32([0 1]), 'Category', 'member');
%       d.generalisationGroup = 'member';
%       d.addMeshSupport('s0', coords, uint8([9 9]), int64([0 4 8]), ...
%                        int64([0 1 4 3 1 2 5 4]), 'Varies', 'group:member');
%       d.addNodeArray('s0', 'pressure', p, 'field', 'Units', 'Pa', ...
%                      'Dims', {'row', 'node'});
%       d.addScalar('cl', [0.25 0.55], 'Units', '1');
%       mestra.write(d, 'two_rows.mes');
%
%   Reading one
%
%       d = mestra.read('two_rows.mes');    % everything
%       d = mestra.open('two_rows.mes');    % attributes only, no array
%       p = d.readRows('/supports/s0/node_arrays/pressure', [1 1]);
%
%   See also mestra.read, mestra.open, mestra.write, mestra.validate,
%   mestra.evaluate, mestra.permute.

    properties
        % Where this dataset was read from, or '' when it was built in
        % memory.  Lazy reads need it.
        path = ''

        % Root attributes (section 11).
        format = 'mestra/0'
        writer = 'mestra matlab 0'
        created = ''
        aligned = true
        generalisationGroup = ''

        % The number of rows.  The `row` dimension scale carries it,
        % so a file with no row-dimensioned dataset still states it.
        nRows = 0

        % Struct arrays.  Their fields are listed by emptyKey,
        % emptyScalar, emptySupport and emptySlot below.
        keys
        scalars
        categories
        supports
        callables

        % int32, one per row, zero based, present only in an unaligned
        % file (sections 8 and 22).
        rowSupport = []

        % Free-form and opaque subtrees, kept exactly as they were
        % read so that a round trip does not lose them.
        notes = []
        privateTree = []

        % Groups and root attributes this version does not know.  They
        % are ignored, reported (W11) and written back unchanged.
        unknownGroups
        unknownAttrs

        % Root groups the file carried, so that one that was there and
        % empty is written back.  The writer creates the union of this
        % and the groups that have content.
        groupsPresent = {}
    end

    methods

        function obj = Dataset()
        %Dataset  An empty dataset with sensible defaults.
            obj.keys = mestra.Dataset.emptyKey();
            obj.scalars = mestra.Dataset.emptyScalar();
            obj.categories = mestra.Dataset.emptyCategory();
            obj.supports = mestra.Dataset.emptySupport();
            obj.callables = mestra.Dataset.emptyCallable();
            obj.unknownGroups = {};
            obj.unknownAttrs = containers.Map('KeyType', 'char', ...
                                              'ValueType', 'any');
            obj.created = mestra.Dataset.nowUtc();
        end

        % ------------------------------------------------ accessors

        function names = keyNames(obj)
        %keyNames  Key names in the file's key order, which is the
        %   names sorted by their UTF-8 bytes (section 26).
            names = mestra.internal.H5.sortByBytes({obj.keys.name});
        end

        function k = key(obj, name)
        %key  One key by name.
            k = mestra.Dataset.pick(obj.keys, name, 'key');
        end

        function s = scalar(obj, name)
        %scalar  One scalar slot by name.
            s = mestra.Dataset.pick(obj.scalars, name, 'scalar');
        end

        function s = support(obj, name)
        %support  One support by name.
            s = mestra.Dataset.pick(obj.supports, name, 'support');
        end

        function c = category(obj, name)
        %category  One category table by name.
            c = mestra.Dataset.pick(obj.categories, name, 'category table');
        end

        function a = nodeArray(obj, supportName, name)
        %nodeArray  One node array by support and name.
            s = obj.support(supportName);
            a = mestra.Dataset.pick(s.nodeArrays, name, 'node array');
        end

        function a = cellArray(obj, supportName, name)
        %cellArray  One cell array by support and name.
            s = obj.support(supportName);
            a = mestra.Dataset.pick(s.cellArrays, name, 'cell array');
        end

        function c = callable(obj, id)
        %callable  One callable record by id.
            c = mestra.Dataset.pick(obj.callables, id, 'callable');
        end

        function names = supportNames(obj)
        %supportNames  Support names in the file's support order, which
        %   is the names sorted by their UTF-8 bytes (section 22).
            names = mestra.internal.H5.sortByBytes({obj.supports.name});
        end

        function out = slots(obj)
        %slots  Every slot in the file, as a struct array with fields
        %   path, kind ('scalar', 'coordinates', 'node' or 'cell'),
        %   support and slot.
            out = struct('path', {}, 'kind', {}, 'support', {}, 'slot', {});
            for i = 1:numel(obj.scalars)
                out(end + 1) = struct('path', ...
                    ['/scalars/' obj.scalars(i).name], 'kind', 'scalar', ...
                    'support', '', 'slot', obj.scalars(i)); %#ok<AGROW>
            end
            for i = 1:numel(obj.supports)
                s = obj.supports(i);
                base = ['/supports/' s.name];
                if ~isempty(s.coordinates)
                    out(end + 1) = struct('path', [base '/coordinates'], ...
                        'kind', 'coordinates', 'support', s.name, ...
                        'slot', s.coordinates); %#ok<AGROW>
                end
                for j = 1:numel(s.nodeArrays)
                    out(end + 1) = struct('path', ...
                        [base '/node_arrays/' s.nodeArrays(j).name], ...
                        'kind', 'node', 'support', s.name, ...
                        'slot', s.nodeArrays(j)); %#ok<AGROW>
                end
                for j = 1:numel(s.cellArrays)
                    out(end + 1) = struct('path', ...
                        [base '/cell_arrays/' s.cellArrays(j).name], ...
                        'kind', 'cell', 'support', s.name, ...
                        'slot', s.cellArrays(j)); %#ok<AGROW>
                end
            end
        end

        function t = keysTable(obj)
        %keysTable  The stored keys as a MATLAB table, in the file's
        %   key order.  This is the shape section 26 gives a keys
        %   table, so it can be handed straight to a callable.
            names = obj.keyNames();
            columns = cell(1, numel(names));
            for i = 1:numel(names)
                k = obj.key(names{i});
                v = k.values;
                if iscell(v)
                    columns{i} = reshape(v, [], 1);
                else
                    columns{i} = double(reshape(v, [], 1));
                end
            end
            if isempty(names)
                t = table.empty(obj.nRows, 0);
            else
                t = table(columns{:}, 'VariableNames', names);
            end
        end

        function s = axisOrder(obj) %#ok<MANU>
        %axisOrder  One sentence stating the order arrays come back in.
            s = ['arrays are returned in MATLAB order, which is the ' ...
                 'reverse of the file''s: (component, node | cell, ' ...
                 '[draw], row | group). Every array carries its ' ...
                 'dimension names in that same order; permute by name ' ...
                 'with mestra.permute.'];
        end

        % ----------------------------------------------- lazy access

        function out = readRows(obj, slotPath, rowRange)
        %readRows  One slot, for a range of rows, reading nothing else.
        %   `slotPath` is the HDF5 path of the slot, for example
        %   '/supports/s0/node_arrays/pressure' or '/scalars/cl'.
        %   `rowRange` is [first last], one based and inclusive; pass
        %   a single number for one row.  The result is a struct with
        %   fields values and dims, in the same axis order as every
        %   other array this class hands back.
        %
        %   Section 29 asks a reader to be able to do this without
        %   reading any other slot and without reading the rows
        %   outside the range; chunking along `row` with the non-row
        %   extents full is what makes that one run of chunks.
            if numel(rowRange) == 1
                rowRange = [rowRange rowRange];
            end
            first = rowRange(1);
            count = rowRange(2) - rowRange(1) + 1;
            if count < 0
                error('mestra:rowRange', 'the row range is empty');
            end
            if isempty(obj.path)
                out = obj.sliceInMemory(slotPath, first, count);
                return
            end
            fid = H5F.open(obj.path, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
            cleanup = onCleanup(@() H5F.close(fid));
            did = H5D.open(fid, slotPath);
            info = mestra.internal.H5.dsetInfo(did);
            names = cell(1, numel(info.dims));
            for axis = 1:numel(info.dims)
                found = mestra.internal.H5.scaleNames(did, axis - 1);
                if isempty(found)
                    names{axis} = sprintf('axis%d', axis - 1);
                else
                    names{axis} = mestra.Dataset.logicalDim(found{1});
                end
            end
            if isempty(info.dims) || ~strcmp(names{1}, 'row')
                error('mestra:rowRange', ...
                      'the slot "%s" has no row dimension', slotPath);
            end
            if first < 1 || first - 1 + count > info.dims(1)
                error('mestra:rowRange', ...
                      'rows %d to %d are outside the %d the slot holds', ...
                      first, first + count - 1, info.dims(1));
            end
            values = mestra.internal.H5.readRows(did, info, first - 1, count);
            H5D.close(did);
            out.values = values;
            out.dims = fliplr(names);
        end

        % -------------------------------------------------- builders

        function addCategory(obj, name, entries, varargin)
        %addCategory  A category table.  Ids are the positions, so the
        %   first entry is id 0 (section 21).
            p = inputParser();
            p.addParameter('Size', []);
            p.parse(varargin{:});
            if isstring(entries), entries = cellstr(entries); end
            rec = mestra.Dataset.emptyCategory();
            rec(1).name = name;
            rec(1).entries = reshape(entries, 1, []);
            rec(1).strSize = p.Results.Size;
            obj.categories = mestra.Dataset.append(obj.categories, rec, name);
        end

        function addKey(obj, name, role, values, varargin)
        %addKey  A key column.  The dtype follows the role
        %   (section 19) unless Dtype says otherwise.
            p = inputParser();
            p.addParameter('Units', '');
            p.addParameter('Lower', []);
            p.addParameter('Upper', []);
            p.addParameter('Category', '');
            p.addParameter('TrajectoryGroup', '');
            p.addParameter('Parent', '');
            p.addParameter('Dtype', '');
            p.addParameter('Chunk', []);
            p.parse(varargin{:});
            r = p.Results;
            rec = mestra.Dataset.emptyKey();
            rec(1).name = name;
            rec(1).role = role;
            rec(1).units = r.Units;
            rec(1).lower = r.Lower;
            rec(1).upper = r.Upper;
            rec(1).category = r.Category;
            rec(1).trajectoryGroup = r.TrajectoryGroup;
            rec(1).parent = r.Parent;
            rec(1).chunk = r.Chunk;
            if iscell(values) || isstring(values)
                rec(1).values = reshape(cellstr(values), 1, []);
                rec(1).dtype = 'string';
            else
                rec(1).dtype = r.Dtype;
                if isempty(rec(1).dtype)
                    rec(1).dtype = mestra.Dataset.dtypeForRole(role, values);
                end
                rec(1).values = reshape(values, 1, []);
            end
            obj.noteRows(numel(rec(1).values));
            obj.keys = mestra.Dataset.append(obj.keys, rec, name);
        end

        function addScalar(obj, name, values, varargin)
        %addScalar  A per-row quantity of interest.  Units are
        %   required (E11).
            p = inputParser();
            p.addParameter('Units', '');
            p.addParameter('Source', 'data');
            p.addParameter('Output', '');
            p.addParameter('Statistic', '');
            p.addParameter('Of', '');
            p.addParameter('Quantile', []);
            p.addParameter('Chunk', []);
            p.parse(varargin{:});
            r = p.Results;
            rec = mestra.Dataset.emptyScalar();
            rec(1).name = name;
            rec(1).units = r.Units;
            rec(1).source = r.Source;
            rec(1).output = r.Output;
            rec(1).statistic = r.Statistic;
            rec(1).of = r.Of;
            rec(1).quantile = r.Quantile;
            rec(1).chunk = r.Chunk;
            rec(1).dtype = 'float64';
            rec(1).values = reshape(double(values), 1, []);
            rec(1).dims = {'row'};
            if ~strcmp(r.Source, 'data')
                rec(1).values = [];
            else
                obj.noteRows(numel(rec(1).values));
            end
            obj.scalars = mestra.Dataset.append(obj.scalars, rec, name);
        end

        function addSupport(obj, name, kind, nNodes, varargin)
        %addSupport  A support of kind 'mesh', 'axis' or 'none'.
        %   addMeshSupport and addAxisSupport are the usual way in.
            p = inputParser();
            p.addParameter('CellTypes', []);
            p.addParameter('CellOffsets', []);
            p.addParameter('CellConnectivity', []);
            p.parse(varargin{:});
            r = p.Results;
            rec = mestra.Dataset.emptySupport();
            rec(1).name = name;
            rec(1).kind = kind;
            rec(1).nNodes = double(nNodes);
            rec(1).cellTypes = uint8(r.CellTypes(:)');
            rec(1).cellOffsets = int64(r.CellOffsets(:)');
            rec(1).cellConnectivity = int64(r.CellConnectivity(:)');
            rec(1).nCells = numel(rec(1).cellTypes);
            rec(1).coordinates = [];
            rec(1).nodeArrays = mestra.Dataset.emptySlot();
            rec(1).cellArrays = mestra.Dataset.emptySlot();
            rec(1).supportId = '';
            rec(1).groupsPresent = {};
            obj.supports = mestra.Dataset.append(obj.supports, rec, name);
            obj.refreshSupportId(name);
            obj.aligned = numel(obj.supports) <= 1;
        end

        function addMeshSupport(obj, name, coordinates, cellTypes, ...
                                cellOffsets, cellConnectivity, varargin)
        %addMeshSupport  A mesh support and its coordinates in one call.
        %   `coordinates` is given in MATLAB axis order, or in the
        %   order named by Dims.  The support id is computed for you.
            p = inputParser();
            p.KeepUnmatched = true;
            p.addParameter('Units', 'm');
            p.addParameter('Varies', 'none');
            p.addParameter('Dims', {});
            p.addParameter('Components', []);
            p.parse(varargin{:});
            r = p.Results;
            nNodes = mestra.Dataset.countNodes(coordinates, r.Dims);
            obj.addSupport(name, 'mesh', nNodes, ...
                           'CellTypes', cellTypes, ...
                           'CellOffsets', cellOffsets, ...
                           'CellConnectivity', cellConnectivity);
            obj.setCoordinates(name, coordinates, 'Units', r.Units, ...
                               'Varies', r.Varies, 'Dims', r.Dims, ...
                               'Components', r.Components);
        end

        function addAxisSupport(obj, name, coordinates, varargin)
        %addAxisSupport  An axis support and its coordinates.  The
        %   coordinates of an axis support never vary (E35).
            p = inputParser();
            p.addParameter('Units', '1');
            p.addParameter('Dims', {});
            p.parse(varargin{:});
            r = p.Results;
            nNodes = mestra.Dataset.countNodes(coordinates, r.Dims);
            obj.addSupport(name, 'axis', nNodes);
            obj.setCoordinates(name, coordinates, 'Units', r.Units, ...
                               'Varies', 'none', 'Dims', r.Dims, ...
                               'Components', 1);
        end

        function setCoordinates(obj, supportName, values, varargin)
        %setCoordinates  The one coordinates array of a support.
            slot = obj.makeSlot('coordinates', values, 'coordinates', ...
                                supportName, 'node', varargin{:});
            i = obj.supportIndex(supportName);
            obj.supports(i).coordinates = slot;
            obj.refreshSupportId(supportName);
        end

        function addNodeArray(obj, supportName, name, values, role, varargin)
        %addNodeArray  A node array on a support.
            slot = obj.makeSlot(name, values, role, supportName, 'node', ...
                                varargin{:});
            i = obj.supportIndex(supportName);
            obj.supports(i).nodeArrays = ...
                mestra.Dataset.append(obj.supports(i).nodeArrays, slot, name);
        end

        function addCellArray(obj, supportName, name, values, role, varargin)
        %addCellArray  A cell array on a support.
            slot = obj.makeSlot(name, values, role, supportName, 'cell', ...
                                varargin{:});
            i = obj.supportIndex(supportName);
            obj.supports(i).cellArrays = ...
                mestra.Dataset.append(obj.supports(i).cellArrays, slot, name);
        end

        function addCallable(obj, id, callableOrDict, varargin)
        %addCallable  Store a callable under an id.
            p = inputParser();
            p.addParameter('Type', '');
            p.addParameter('Repr', '');
            p.parse(varargin{:});
            r = p.Results;
            rec = mestra.Dataset.emptyCallable();
            rec(1).id = id;
            if isa(callableOrDict, 'mestra.Callable')
                rec(1).obj = callableOrDict;
                rec(1).dict = callableOrDict.toDict();
                rec(1).type = r.Type;
                if isempty(rec(1).type)
                    rec(1).type = callableOrDict.type();
                end
                rec(1).repr = r.Repr;
                if isempty(rec(1).repr)
                    rec(1).repr = callableOrDict.repr();
                end
            else
                rec(1).obj = [];
                rec(1).dict = callableOrDict;
                rec(1).type = r.Type;
                rec(1).repr = r.Repr;
            end
            if isempty(rec(1).type)
                error('mestra:E15', ...
                      'a callable needs a type (E15)');
            end
            obj.callables = mestra.Dataset.append(obj.callables, rec, id);
        end

        function setRowSupport(obj, values)
        %setRowSupport  Which support each row is on, zero based.
            obj.rowSupport = int32(reshape(values, 1, []));
            obj.noteRows(numel(obj.rowSupport));
            obj.aligned = numel(obj.supports) <= 1;
        end

        function refreshSupportId(obj, name)
        %refreshSupportId  Recompute one support's content hash.
            i = obj.supportIndex(name);
            obj.supports(i).supportId = mestra.supportId(obj.supports(i));
        end

        function disp(obj)
        %disp  A short summary.
            fprintf('  mestra.Dataset  %s  %d row(s)\n', obj.format, obj.nRows);
            if ~isempty(obj.path)
                fprintf('    read from %s\n', obj.path);
            end
            fprintf(['    aligned %d, %d support(s), %d key(s), ' ...
                     '%d scalar(s)\n'], obj.aligned, ...
                    numel(obj.supports), numel(obj.keys), ...
                    numel(obj.scalars));
            for i = 1:numel(obj.keys)
                k = obj.keys(i);
                fprintf('    key %-14s %-12s', k.name, k.role);
                if ~isempty(k.units), fprintf(' [%s]', k.units); end
                if ~isempty(k.lower) && ~isempty(k.upper)
                    fprintf(' in [%g, %g]', k.lower, k.upper);
                end
                fprintf('\n');
            end
            for i = 1:numel(obj.supports)
                s = obj.supports(i);
                fprintf('    support %-8s %-5s %d node(s) %d cell(s) %s\n', ...
                        s.name, s.kind, s.nNodes, s.nCells, s.supportId(1:8));
            end
            for i = 1:numel(obj.callables)
                fprintf('    callable %-8s %s\n', obj.callables(i).id, ...
                        obj.callables(i).type);
            end
        end
    end

    % ------------------------------------------------------ internals

    methods (Access = private)

        function i = supportIndex(obj, name)
            i = find(strcmp({obj.supports.name}, name), 1);
            if isempty(i)
                error('mestra:noSupport', 'no support "%s"', name);
            end
        end

        function noteRows(obj, n)
            if n > obj.nRows
                obj.nRows = n;
            end
        end

        function slot = makeSlot(obj, name, values, role, supportName, ...
                                 location, varargin)
            p = inputParser();
            p.addParameter('Units', '');
            p.addParameter('Varies', '');
            p.addParameter('Components', []);
            p.addParameter('Source', 'data');
            p.addParameter('Output', '');
            p.addParameter('Statistic', '');
            p.addParameter('Of', '');
            p.addParameter('Quantile', []);
            p.addParameter('Category', '');
            p.addParameter('Recomputed', []);
            p.addParameter('DerivedFrom', '');
            p.addParameter('Recipe', '');
            p.addParameter('Reference', '');
            p.addParameter('Dims', {});
            p.addParameter('Dtype', '');
            p.addParameter('Chunk', []);
            p.parse(varargin{:});
            r = p.Results;

            slot = mestra.Dataset.emptySlot();
            slot(1).name = name;
            slot(1).role = role;
            slot(1).units = r.Units;
            slot(1).source = r.Source;
            slot(1).output = r.Output;
            slot(1).statistic = r.Statistic;
            slot(1).of = r.Of;
            slot(1).quantile = r.Quantile;
            slot(1).category = r.Category;
            slot(1).recomputed = r.Recomputed;
            slot(1).derivedFrom = r.DerivedFrom;
            slot(1).recipe = r.Recipe;
            slot(1).reference = r.Reference;
            slot(1).location = location;
            slot(1).support = supportName;
            slot(1).chunk = r.Chunk;

            varies = r.Varies;
            if isempty(varies)
                if strcmp(role, 'coordinates')
                    varies = 'none';
                else
                    varies = 'row';
                end
            end
            slot(1).varies = varies;

            if ~strcmp(r.Source, 'data')
                slot(1).values = [];
                slot(1).dims = {};
                slot(1).dtype = '';
                slot(1).components = r.Components;
                if isempty(slot(1).components)
                    error('mestra:E31', ...
                          ['a callable slot must declare Components ' ...
                           '(E31)']);
                end
                return
            end

            hasDraw = strcmp(r.Statistic, 'draw');
            logicalNames = mestra.Dataset.logicalDims(varies, location, ...
                                                      hasDraw);
            wanted = fliplr(logicalNames);
            % Dims names the axes of the array the caller passes, in
            % that array's own order.  With no Dims the array is taken
            % to be in the order a reader hands one back.
            given = r.Dims;
            if isempty(given)
                given = wanted;
            else
                given = mestra.Dataset.canonicalDims(given, varies);
            end
            slot(1).values = mestra.permute(values, given, wanted);
            slot(1).dims = wanted;
            slot(1).dtype = r.Dtype;
            if isempty(slot(1).dtype)
                slot(1).dtype = mestra.Dataset.dtypeForArrayRole(role, values);
            end
            slot(1).components = r.Components;
            if isempty(slot(1).components)
                slot(1).components = size(slot(1).values, 1);
            end
            if strcmp(varies, 'row')
                obj.noteRows(size(slot(1).values, numel(wanted)));
            end
        end

        function out = sliceInMemory(obj, slotPath, first, count)
            found = obj.slots();
            i = find(strcmp({found.path}, slotPath), 1);
            if isempty(i)
                error('mestra:noSlot', 'no slot at "%s"', slotPath);
            end
            slot = found(i).slot;
            n = numel(slot.dims);
            if n == 0 || ~strcmp(slot.dims{end}, 'row')
                error('mestra:rowRange', ...
                      'the slot "%s" has no row dimension', slotPath);
            end
            subs = repmat({':'}, 1, n);
            subs{n} = first:(first + count - 1);
            out.values = slot.values(subs{:});
            out.dims = slot.dims;
        end
    end

    methods (Static)

        function s = emptyKey()
            s = struct('name', {}, 'role', {}, 'units', {}, 'lower', {}, ...
                       'upper', {}, 'category', {}, 'trajectoryGroup', {}, ...
                       'parent', {}, 'values', {}, 'dtype', {}, ...
                       'chunk', {}, 'strSize', {});
        end

        function s = emptyScalar()
            s = struct('name', {}, 'units', {}, 'source', {}, 'output', {}, ...
                       'statistic', {}, 'of', {}, 'quantile', {}, ...
                       'values', {}, 'dtype', {}, 'dims', {}, 'chunk', {});
        end

        function s = emptyCategory()
            s = struct('name', {}, 'entries', {}, 'strSize', {});
        end

        function s = emptySupport()
            s = struct('name', {}, 'kind', {}, 'nNodes', {}, 'nCells', {}, ...
                       'supportId', {}, 'cellTypes', {}, 'cellOffsets', {}, ...
                       'cellConnectivity', {}, 'coordinates', {}, ...
                       'nodeArrays', {}, 'cellArrays', {}, ...
                       'groupsPresent', {});
        end

        function s = emptySlot()
            s = struct('name', {}, 'role', {}, 'varies', {}, 'units', {}, ...
                       'components', {}, 'source', {}, 'output', {}, ...
                       'statistic', {}, 'of', {}, 'quantile', {}, ...
                       'category', {}, 'recomputed', {}, 'derivedFrom', {}, ...
                       'recipe', {}, 'reference', {}, 'values', {}, ...
                       'dims', {}, 'dtype', {}, 'location', {}, ...
                       'support', {}, 'chunk', {});
        end

        function s = emptyCallable()
            s = struct('id', {}, 'type', {}, 'repr', {}, 'dict', {}, ...
                       'obj', {});
        end

        function out = append(arr, rec, name)
            if ~isempty(arr)
                if isfield(arr, 'name')
                    taken = {arr.name};
                else
                    taken = {arr.id};
                end
                if any(strcmp(taken, name))
                    error('mestra:duplicate', '"%s" is already there', name);
                end
            end
            out = [arr rec];
        end

        function v = pick(arr, name, what)
            if isempty(arr)
                error('mestra:notFound', 'no %s "%s"', what, name);
            end
            if isfield(arr, 'name')
                i = find(strcmp({arr.name}, name), 1);
            else
                i = find(strcmp({arr.id}, name), 1);
            end
            if isempty(i)
                error('mestra:notFound', 'no %s "%s"', what, name);
            end
            v = arr(i);
        end

        function names = logicalDims(varies, location, hasDraw)
        %logicalDims  The file's logical dimension names for a slot.
            names = {};
            if ~strcmp(varies, 'none')
                names{end + 1} = varies;      % 'row' or 'group:<k>'
            end
            if hasDraw
                names{end + 1} = 'draw';
            end
            names{end + 1} = location;        % 'node' or 'cell'
            names{end + 1} = 'component';
        end

        function out = canonicalDims(given, varies)
        %canonicalDims  Accept 'instance' for a group leading axis.
            out = given;
            for i = 1:numel(out)
                if strcmp(out{i}, 'instance')
                    out{i} = varies;
                end
            end
        end

        function name = logicalDim(diskName)
        %logicalDim  The logical dimension name for a name on disk
        %   (section 21).
            if strncmp(diskName, 'component_', 10)
                name = 'component';
            elseif strncmp(diskName, 'draw_', 5)
                name = 'draw';
            elseif strncmp(diskName, 'group_', 6)
                name = ['group:' diskName(7:end)];
            elseif strncmp(diskName, 'category_', 9)
                name = 'category';
            else
                name = diskName;   % row, node, cell, cell_plus_one, index
            end
        end

        function name = diskDim(logicalName, length)
        %diskDim  The name on disk for a logical dimension name.
            switch logicalName
                case 'component'
                    name = sprintf('component_%d', length);
                case 'draw'
                    name = sprintf('draw_%d', length);
                otherwise
                    if strncmp(logicalName, 'group:', 6)
                        name = ['group_' logicalName(7:end)];
                    else
                        name = logicalName;
                    end
            end
        end

        function t = dtypeForRole(role, values)
        %dtypeForRole  The dtype table of section 19, for a key.
            switch role
                case {'design', 'condition', 'time'}
                    t = 'float64';
                case {'categorical', 'group', 'split', 'status'}
                    t = 'int32';
                case 'id'
                    t = 'int64';
                otherwise
                    t = 'float64';
            end
            if isa(values, 'int64'), t = 'int64'; end
            if isa(values, 'int32') && ~strcmp(t, 'float64'), t = 'int32'; end
        end

        function t = dtypeForArrayRole(role, values)
        %dtypeForArrayRole  The dtype table of section 19, for an array.
            switch role
                case 'label'
                    if isa(values, 'int64'), t = 'int64'; else, t = 'int32'; end
                otherwise
                    t = 'float64';
            end
        end

        function n = countNodes(coordinates, dims)
        %countNodes  How many nodes a coordinates array describes.
            if isempty(dims)
                % MATLAB order is (component, node, ...), so node is
                % the second axis.
                n = size(coordinates, 2);
            else
                i = find(strcmp(dims, 'node'), 1);
                if isempty(i)
                    error('mestra:dims', ...
                          'the coordinates Dims must name "node"');
                end
                n = size(coordinates, i);
            end
        end

        function s = nowUtc()
        %nowUtc  An ISO 8601 UTC timestamp for `created`.
            s = char(datetime('now', 'TimeZone', 'UTC', ...
                              'Format', 'uuuu-MM-dd''T''HH:mm:ss''Z'''));
        end
    end
end
