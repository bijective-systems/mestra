classdef Reader
%Reader  Turn a file into a mestra.Dataset.
%
%   mestra.read and mestra.open are the public way in.  Everything
%   here reads through the low-level HDF5 interface and takes every
%   dimension name from a scale's link name, never from its NAME
%   attribute, which holds the same sentence in every scale in the
%   file (specification section 21).
%
%   See also mestra.read, mestra.open.

    properties (Constant)
        ROOT_ATTRS = {'format', 'writer', 'created', 'aligned', ...
                      'generalisation_group'};
        ROOT_GROUPS = {'keys', 'scalars', 'categories', 'supports', ...
                       'callables', 'notes', 'private'};
    end

    methods (Static)

        function d = load(path, eager)
        %load  Read a file.  With `eager` false no array is read.
        %   Every failure below leaves this function as mestra:E01,
        %   when the file is another major version, or mestra:reader,
        %   whatever the HDF5 library called it. A file is untrusted
        %   input: the caller gets one of two identifiers and a
        %   sentence, not a library stack trace.
            if nargin < 2, eager = true; end
            try
                d = mestra.internal.Reader.loadUnguarded(path, eager);
            catch err
                if any(strcmp(err.identifier, {'mestra:E01', ...
                                               'mestra:reader', ...
                                               'mestra:noFile'}))
                    rethrow(err);
                end
                error('mestra:reader', ...
                      'the file "%s" could not be read: %s', path, ...
                      regexprep(strtrim(err.message), '\s+', ' '));
            end
        end

        function d = loadUnguarded(path, eager)
        %loadUnguarded  load, before the identifiers are tidied.
            if exist(path, 'file') ~= 2
                error('mestra:noFile', 'no file at "%s"', path);
            end
            fid = mestra.internal.Reader.openFile(path);
            closeFile = onCleanup(@() H5F.close(fid));
            d = mestra.Dataset();
            d.path = path;
            root = H5G.open(fid, '/');
            d.skipped = {};
            closeRoot = onCleanup(@() H5G.close(root)); %#ok<NASGU>
            H5 = mestra.internal.H5;

            [value, ok] = H5.scalarAttr(root, 'format');
            d.format = '';
            if ok && ischar(value), d.format = value; end
            major = mestra.internal.Reader.majorVersion(d.format);
            if isnan(major) || major ~= 0
                error('mestra:E01', ...
                      ['this reader accepts "mestra/0" and the file ' ...
                       'says "%s"; it will not be read partially (E01)'], ...
                      d.format);
            end
            d.writer = mestra.internal.Reader.str(root, 'writer');
            d.created = mestra.internal.Reader.str(root, 'created');
            aligned = mestra.internal.Reader.num(root, 'aligned');
            if ~isempty(aligned), d.aligned = aligned ~= 0; end
            d.generalisationGroup = ...
                mestra.internal.Reader.str(root, 'generalisation_group');
            for name = H5.publicAttrNames(root)
                if ~ismember(name{1}, mestra.internal.Reader.ROOT_ATTRS)
                    try
                        info = H5.attrInfo(root, name{1});
                        if ~info.scalar || isempty(info.type)
                            d.skipped{end + 1} = sprintf( ...
                                '/%s: an attribute not carried', name{1});
                        elseif strcmp(info.type, 'string')
                            d.unknownAttrs(name{1}) = ...
                                struct('type', info.type, 'bytes', ...
                                       H5.readRawStrAttr(root, name{1}));
                        else
                            d.unknownAttrs(name{1}) = ...
                                struct('type', info.type, 'value', ...
                                       H5.readAttr(root, name{1}));
                        end
                    catch
                        d.skipped{end + 1} = sprintf( ...
                            '/%s: an attribute that would not read', name{1});
                    end
                end
            end

            d.nRows = mestra.internal.Reader.rowCount(fid);

            if mestra.internal.Reader.hasGroup(fid, 'categories')
                g = H5.openGroup(fid, 'categories');
                for name = H5.children(g)
                    if ~mestra.internal.Reader.isKind(d, g, name{1}, ...
                            'dataset', ['/categories/' name{1}])
                        continue
                    end
                    did = H5D.open(g, name{1});
                    try
                        info = H5.dsetInfo(did);
                        rec = mestra.Dataset.emptyCategory();
                        rec(1).name = name{1};
                        rec(1).entries = H5.readData(did, info);
                        rec(1).strSize = info.strSize;
                        d.categories = [d.categories rec];
                    catch err
                        H5D.close(did);
                        rethrow(err);
                    end
                    H5D.close(did);
                end
                H5G.close(g);
            end

            if mestra.internal.Reader.hasGroup(fid, 'keys')
                g = H5.openGroup(fid, 'keys');
                for name = H5.children(g)
                    if ~mestra.internal.Reader.isKind(d, g, name{1}, ...
                            'dataset', ['/keys/' name{1}])
                        continue
                    end
                    d.keys = [d.keys ...
                        mestra.internal.Reader.readKey(g, name{1}, eager)];
                end
                H5G.close(g);
            end

            if mestra.internal.Reader.hasGroup(fid, 'scalars')
                g = H5.openGroup(fid, 'scalars');
                for name = H5.children(g)
                    kind = H5.childType(g, name{1});
                    if ~any(strcmp(kind, {'group', 'dataset'}))
                        d.skipped{end + 1} = sprintf( ...
                            '/scalars/%s: %s, not followed', name{1}, ...
                            mestra.internal.Reader.describeKind(kind, ...
                                                                'dataset'));
                        continue
                    end
                    d.scalars = [d.scalars ...
                        mestra.internal.Reader.readScalar(g, name{1}, eager)];
                end
                H5G.close(g);
            end

            if mestra.internal.Reader.hasKind(fid, 'row_support', 'dataset')
                did = H5D.open(fid, 'row_support');
                info = H5.dsetInfo(did);
                d.rowSupport = int32(H5.readData(did, info));
                d.rowSupport = reshape(d.rowSupport, 1, []);
                H5D.close(did);
            end

            if mestra.internal.Reader.hasGroup(fid, 'supports')
                g = H5.openGroup(fid, 'supports');
                for name = H5.children(g)
                    if ~mestra.internal.Reader.isKind(d, g, name{1}, ...
                            'group', ['/supports/' name{1}])
                        continue
                    end
                    d.supports = [d.supports ...
                        mestra.internal.Reader.readSupport(g, name{1}, eager)];
                end
                H5G.close(g);
            end

            if mestra.internal.Reader.hasGroup(fid, 'callables')
                g = H5.openGroup(fid, 'callables');
                for name = H5.children(g)
                    if ~mestra.internal.Reader.isKind(d, g, name{1}, ...
                            'group', ['/callables/' name{1}])
                        continue
                    end
                    [record, limits] = ...
                        mestra.internal.Reader.readCallable(g, name{1});
                    d.callables = [d.callables record];
                    for i = 1:numel(limits)
                        d.skipped{end + 1} = ...
                            ['/callables/' name{1} ': ' limits{i}];
                    end
                end
                H5G.close(g);
            end

            for which = {'notes', 'private'}
                if ~mestra.internal.Reader.hasGroup(fid, which{1})
                    continue
                end
                g = H5.openGroup(fid, which{1});
                tree = H5.captureTree(g);
                H5G.close(g);
                for i = 1:numel(tree.stopped)
                    d.skipped{end + 1} = ['/' which{1} '/' tree.stopped{i}];
                end
                if strcmp(which{1}, 'notes')
                    d.notes = tree;
                else
                    d.privateTree = tree;
                end
            end

            for name = H5.children(root)
                if ismember(name{1}, mestra.internal.Reader.ROOT_GROUPS) && ...
                   strcmp(H5.childType(root, name{1}), 'group')
                    d.groupsPresent{end + 1} = name{1};
                end
                if mestra.internal.Reader.knownRootChild(root, name{1})
                    continue
                end
                kind = H5.childType(root, name{1});
                if strcmp(kind, 'group')
                    g = H5G.open(root, name{1});
                    tree = H5.captureTree(g);
                    H5G.close(g);
                    for i = 1:numel(tree.stopped)
                        d.skipped{end + 1} = ['/' name{1} '/' tree.stopped{i}];
                    end
                    d.unknownGroups{end + 1} = ...
                        struct('name', name{1}, 'tree', tree);
                elseif strcmp(kind, 'dataset')
                    d.unknownGroups{end + 1} = ...
                        struct('name', name{1}, 'tree', []);
                else
                    d.skipped{end + 1} = sprintf('/%s: %s, not followed', ...
                        name{1}, ...
                        mestra.internal.Reader.describeKind(kind, 'group'));
                end
            end
        end

        function fid = openFile(path)
        %openFile  H5F.open, with any failure named as this reader's.
            try
                fid = H5F.open(path, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
            catch err
                error('mestra:reader', ...
                      ['"%s" would not open as an HDF5 file: %s'], path, ...
                      regexprep(strtrim(err.message), '\s+', ' '));
            end
        end

        function tf = hasGroup(loc, name)
        %hasGroup  True when a name is a hard-linked group.
            tf = mestra.internal.Reader.hasKind(loc, name, 'group');
        end

        function tf = hasKind(loc, name, wanted)
        %hasKind  True when a name is a hard link of the kind wanted.
            tf = false;
            try
                if ~H5L.exists(loc, name, 'H5P_DEFAULT')
                    return
                end
            catch
                return
            end
            tf = strcmp(mestra.internal.H5.childType(loc, name), wanted);
        end

        function tf = isKind(d, gid, name, wanted, path)
        %isKind  True when a member is the kind wanted, and otherwise
        %   records on the dataset why it was passed over.
            kind = mestra.internal.H5.childType(gid, name);
            tf = strcmp(kind, wanted);
            if ~tf
                d.skipped{end + 1} = sprintf('%s: %s, not followed', ...
                    path, mestra.internal.Reader.describeKind(kind, wanted));
            end
        end

        function text = describeKind(kind, wanted)
        %describeKind  What was found where something else was needed.
            switch kind
                case 'soft'
                    text = ['a soft link, which this format does not ' ...
                            'define'];
                case 'external'
                    text = ['an external link, which names another ' ...
                            'file this reader never opens'];
                case 'unreadable'
                    text = 'an object that would not open';
                otherwise
                    text = sprintf('a %s where a %s is required', ...
                                   kind, wanted);
            end
        end

        function tf = knownRootChild(root, name)
        %knownRootChild  True for a group or scale this version knows.
            if ismember(name, mestra.internal.Reader.ROOT_GROUPS)
                tf = true; return
            end
            if any(strcmp(name, {'row', 'row_support'}))
                tf = true; return
            end
            prefixes = {'component_', 'draw_', 'group_', 'category_'};
            for i = 1:numel(prefixes)
                p = prefixes{i};
                if numel(name) > numel(p) && strncmp(name, p, numel(p))
                    tf = true; return
                end
            end
            tf = false;
            try
                if strcmp(mestra.internal.H5.childType(root, name), 'dataset')
                    did = H5D.open(root, name);
                    info = mestra.internal.H5.dsetInfo(did);
                    H5D.close(did);
                    tf = info.isScale;  % any other scale is the container's
                end
            catch
            end
        end

        function major = majorVersion(format)
        %majorVersion  The n of "mestra/n", or NaN.
            major = NaN;
            if isempty(format), return, end
            parts = strsplit(format, '/');
            if numel(parts) ~= 2 || ~strcmp(parts{1}, 'mestra'), return, end
            v = str2double(parts{2});
            if ~isnan(v) && v == floor(v) && v >= 0
                major = v;
            end
        end

        function n = rowCount(fid)
        %rowCount  The length of the file-level `row` scale.
        %   Section 21 makes that the row count, so a reader learns it
        %   even from a file with no row-dimensioned dataset at all.
            n = 0;
            if ~mestra.internal.Reader.hasKind(fid, 'row', 'dataset')
                return
            end
            did = H5D.open(fid, 'row');
            info = mestra.internal.H5.dsetInfo(did);
            H5D.close(did);
            if ~isempty(info.dims)
                n = info.dims(1);
            end
        end

        function names = axisNames(did, ndims)
        %axisNames  The logical dimension name of each axis, FILE order.
            names = cell(1, ndims);
            for axis = 1:ndims
                found = mestra.internal.H5.scaleNames(did, axis - 1);
                if isempty(found)
                    names{axis} = '';
                else
                    names{axis} = mestra.Dataset.logicalDim(found{1});
                end
            end
        end

        function rec = readKey(g, name, eager)
        %readKey  One key column.
            H5 = mestra.internal.H5;
            did = H5D.open(g, name);
            info = H5.dsetInfo(did);
            rec = mestra.Dataset.emptyKey();
            rec(1).name = name;
            rec(1).role = mestra.internal.Reader.str(did, 'role');
            rec(1).units = mestra.internal.Reader.str(did, 'units');
            rec(1).category = mestra.internal.Reader.str(did, 'category');
            rec(1).trajectoryGroup = ...
                mestra.internal.Reader.str(did, 'trajectory_group');
            rec(1).parent = mestra.internal.Reader.str(did, 'parent');
            rec(1).lower = mestra.internal.Reader.num(did, 'lower');
            rec(1).upper = mestra.internal.Reader.num(did, 'upper');
            rec(1).dtype = info.type;
            rec(1).chunk = info.chunk;
            rec(1).strSize = info.strSize;
            if eager
                rec(1).values = reshape(H5.readData(did, info), 1, []);
            else
                rec(1).values = [];
            end
            H5D.close(did);
        end

        function rec = readScalar(g, name, eager)
        %readScalar  One scalar slot, stored or served by a callable.
            H5 = mestra.internal.H5;
            rec = mestra.Dataset.emptyScalar();
            rec(1).name = name;
            rec(1).dims = {'row'};
            if strcmp(H5.childType(g, name), 'group')
                oid = H5G.open(g, name);
                rec(1).units = mestra.internal.Reader.str(oid, 'units');
                rec(1).source = mestra.internal.Reader.str(oid, 'source');
                rec(1).output = mestra.internal.Reader.str(oid, 'output');
                rec(1).statistic = mestra.internal.Reader.str(oid, 'statistic');
                rec(1).of = mestra.internal.Reader.str(oid, 'of');
                rec(1).quantile = mestra.internal.Reader.num(oid, 'quantile');
                rec(1).values = [];
                rec(1).dtype = '';
                rec(1).dims = {};
                H5G.close(oid);
                return
            end
            did = H5D.open(g, name);
            info = H5.dsetInfo(did);
            rec(1).units = mestra.internal.Reader.str(did, 'units');
            rec(1).source = mestra.internal.Reader.str(did, 'source');
            rec(1).output = mestra.internal.Reader.str(did, 'output');
            rec(1).statistic = mestra.internal.Reader.str(did, 'statistic');
            rec(1).of = mestra.internal.Reader.str(did, 'of');
            rec(1).quantile = mestra.internal.Reader.num(did, 'quantile');
            rec(1).dtype = info.type;
            rec(1).chunk = info.chunk;
            if eager
                rec(1).values = reshape(H5.readData(did, info), 1, []);
            else
                rec(1).values = [];
            end
            H5D.close(did);
        end

        function rec = readSupport(g, name, eager)
        %readSupport  One support, its cells and its arrays.
            H5 = mestra.internal.H5;
            sid = H5.openGroup(g, name);
            rec = mestra.Dataset.emptySupport();
            rec(1).name = name;
            rec(1).kind = mestra.internal.Reader.str(sid, 'kind');
            rec(1).nNodes = mestra.internal.Reader.num(sid, 'n_nodes');
            rec(1).nCells = mestra.internal.Reader.num(sid, 'n_cells');
            rec(1).supportId = mestra.internal.Reader.str(sid, 'support_id');
            if isempty(rec(1).nNodes), rec(1).nNodes = 0; end
            if isempty(rec(1).nCells), rec(1).nCells = 0; end
            rec(1).cellTypes = [];
            rec(1).cellOffsets = [];
            rec(1).cellConnectivity = [];
            rec(1).coordinates = [];
            rec(1).nodeArrays = mestra.Dataset.emptySlot();
            rec(1).cellArrays = mestra.Dataset.emptySlot();
            rec(1).groupsPresent = {};
            for g2 = {'node_arrays', 'cell_arrays'}
                if H5.exists(sid, g2{1})
                    rec(1).groupsPresent{end + 1} = g2{1};
                end
            end

            plain = {'cell_types', 'cellTypes'; ...
                     'cell_offsets', 'cellOffsets'; ...
                     'cell_connectivity', 'cellConnectivity'};
            for i = 1:size(plain, 1)
                if mestra.internal.Reader.hasKind(sid, plain{i, 1}, 'dataset')
                    did = H5D.open(sid, plain{i, 1});
                    info = H5.dsetInfo(did);
                    rec(1).(plain{i, 2}) = ...
                        reshape(H5.readData(did, info), 1, []);
                    H5D.close(did);
                end
            end
            if any(strcmp(H5.childType(sid, 'coordinates'), ...
                          {'group', 'dataset'}))
                rec(1).coordinates = mestra.internal.Reader.readSlot( ...
                    sid, 'coordinates', name, 'node', eager);
            end
            arrays = {'node_arrays', 'node'; 'cell_arrays', 'cell'};
            for a = 1:size(arrays, 1)
                if ~mestra.internal.Reader.hasGroup(sid, arrays{a, 1})
                    continue
                end
                ag = H5.openGroup(sid, arrays{a, 1});
                for nm = H5.children(ag)
                    if ~any(strcmp(H5.childType(ag, nm{1}), ...
                                   {'group', 'dataset'}))
                        continue
                    end
                    slot = mestra.internal.Reader.readSlot(ag, nm{1}, ...
                        name, arrays{a, 2}, eager);
                    if strcmp(arrays{a, 2}, 'node')
                        rec(1).nodeArrays(end + 1) = slot;
                    else
                        rec(1).cellArrays(end + 1) = slot;
                    end
                end
                H5G.close(ag);
            end
            H5G.close(sid);
        end

        function rec = readSlot(g, name, supportName, location, eager)
        %readSlot  One array slot, stored or served by a callable.
            H5 = mestra.internal.H5;
            rec = mestra.Dataset.emptySlot();
            rec(1).name = name;
            rec(1).location = location;
            rec(1).support = supportName;
            isGroup = strcmp(H5.childType(g, name), 'group');
            if isGroup
                oid = H5G.open(g, name);
            else
                oid = H5D.open(g, name);
            end
            rec(1).role = mestra.internal.Reader.str(oid, 'role');
            rec(1).varies = mestra.internal.Reader.str(oid, 'varies');
            rec(1).units = mestra.internal.Reader.str(oid, 'units');
            rec(1).source = mestra.internal.Reader.str(oid, 'source');
            rec(1).output = mestra.internal.Reader.str(oid, 'output');
            rec(1).statistic = mestra.internal.Reader.str(oid, 'statistic');
            rec(1).of = mestra.internal.Reader.str(oid, 'of');
            rec(1).category = mestra.internal.Reader.str(oid, 'category');
            rec(1).derivedFrom = ...
                mestra.internal.Reader.str(oid, 'derived_from');
            rec(1).recipe = mestra.internal.Reader.str(oid, 'recipe');
            rec(1).reference = mestra.internal.Reader.str(oid, 'reference');
            rec(1).quantile = mestra.internal.Reader.num(oid, 'quantile');
            rec(1).components = mestra.internal.Reader.num(oid, 'components');
            rec(1).recomputed = mestra.internal.Reader.num(oid, 'recomputed');
            if ~isempty(rec(1).recomputed)
                rec(1).recomputed = rec(1).recomputed ~= 0;
            end
            if isGroup
                rec(1).values = [];
                rec(1).dims = {};
                rec(1).dtype = '';
                rec(1).chunk = [];
                H5G.close(oid);
                return
            end
            info = H5.dsetInfo(oid);
            names = mestra.internal.Reader.axisNames(oid, numel(info.dims));
            rec(1).dims = fliplr(names);
            rec(1).dtype = info.type;
            rec(1).chunk = info.chunk;
            if eager
                rec(1).values = H5.readData(oid, info);
                rec(1).values = reshape(rec(1).values, [fliplr(info.dims) 1 1]);
            else
                rec(1).values = [];
            end
            H5D.close(oid);
        end

        function [rec, limits] = readCallable(g, id)
        %readCallable  One callable: its type, its dictionary and, when
        %   the type is registered, the object itself.  A reader that
        %   does not know the type keeps the dictionary and must not
        %   interpret it (section 25).
            gid = mestra.internal.H5.openGroup(g, id);
            rec = mestra.Dataset.emptyCallable();
            rec(1).id = id;
            rec(1).type = mestra.internal.Reader.str(gid, 'type');
            rec(1).repr = mestra.internal.Reader.str(gid, 'repr');
            [rec(1).dict, problems] = mestra.internal.Codec.read(gid, true);
            limits = {};
            for i = 1:numel(problems)
                if numel(problems{i}) > 4 && strcmp(problems{i}(1:4), 'U03 ')
                    limits{end + 1} = problems{i}(5:end); %#ok<AGROW>
                end
            end
            rec(1).obj = [];
            if ~isempty(rec(1).type) && mestra.Registry.isKnown(rec(1).type)
                try
                    rec(1).obj = mestra.Registry.create(rec(1).type, ...
                                                        rec(1).dict);
                catch
                    rec(1).obj = [];
                end
            end
            H5G.close(gid);
        end

        function v = str(oid, name)
        %str  A scalar string attribute, or '' when there is not one.
        %   An attribute whose dataspace is not scalar is not a value
        %   this format defines (section 18), so it is passed over
        %   rather than handed on as an array.
            v = '';
            [value, ok] = mestra.internal.H5.scalarAttr(oid, name);
            if ok && ischar(value) && (isempty(value) || isrow(value))
                v = value;
            end
        end

        function v = num(oid, name)
        %num  A scalar numeric attribute, or [] when there is not one.
            v = [];
            [value, ok] = mestra.internal.H5.scalarAttr(oid, name);
            if ok && isnumeric(value) && isscalar(value)
                v = double(value);
            end
        end
    end
end
