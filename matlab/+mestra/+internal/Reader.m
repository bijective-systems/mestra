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
            if nargin < 2, eager = true; end
            if exist(path, 'file') ~= 2
                error('mestra:noFile', 'no file at "%s"', path);
            end
            fid = H5F.open(path, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
            closeFile = onCleanup(@() H5F.close(fid));
            d = mestra.Dataset();
            d.path = path;
            root = H5G.open(fid, '/');
            closeRoot = onCleanup(@() H5G.close(root)); %#ok<NASGU>
            H5 = mestra.internal.H5;

            if H5.hasAttr(root, 'format')
                d.format = H5.readAttr(root, 'format');
            else
                d.format = '';
            end
            major = mestra.internal.Reader.majorVersion(d.format);
            if isnan(major) || major ~= 0
                error('mestra:E01', ...
                      ['this reader accepts "mestra/0" and the file ' ...
                       'says "%s"; it will not be read partially (E01)'], ...
                      d.format);
            end
            if H5.hasAttr(root, 'writer')
                d.writer = H5.readAttr(root, 'writer');
            else
                d.writer = '';
            end
            if H5.hasAttr(root, 'created')
                d.created = H5.readAttr(root, 'created');
            else
                d.created = '';
            end
            if H5.hasAttr(root, 'aligned')
                d.aligned = H5.readAttr(root, 'aligned') ~= 0;
            end
            if H5.hasAttr(root, 'generalisation_group')
                d.generalisationGroup = ...
                    H5.readAttr(root, 'generalisation_group');
            end
            for name = H5.publicAttrNames(root)
                if ~ismember(name{1}, mestra.internal.Reader.ROOT_ATTRS)
                    info = H5.attrInfo(root, name{1});
                    if strcmp(info.type, 'string')
                        d.unknownAttrs(name{1}) = ...
                            struct('type', info.type, ...
                                   'bytes', H5.readRawStrAttr(root, name{1}));
                    else
                        d.unknownAttrs(name{1}) = ...
                            struct('type', info.type, ...
                                   'value', H5.readAttr(root, name{1}));
                    end
                end
            end

            d.nRows = mestra.internal.Reader.rowCount(fid);

            if H5.exists(fid, '/categories')
                g = H5G.open(fid, '/categories');
                for name = H5.children(g)
                    did = H5D.open(g, name{1});
                    info = H5.dsetInfo(did);
                    rec = mestra.Dataset.emptyCategory();
                    rec(1).name = name{1};
                    rec(1).entries = H5.readData(did, info);
                    rec(1).strSize = info.strSize;
                    d.categories = [d.categories rec];
                    H5D.close(did);
                end
                H5G.close(g);
            end

            if H5.exists(fid, '/keys')
                g = H5G.open(fid, '/keys');
                for name = H5.children(g)
                    d.keys = [d.keys ...
                        mestra.internal.Reader.readKey(g, name{1}, eager)];
                end
                H5G.close(g);
            end

            if H5.exists(fid, '/scalars')
                g = H5G.open(fid, '/scalars');
                for name = H5.children(g)
                    d.scalars = [d.scalars ...
                        mestra.internal.Reader.readScalar(g, name{1}, eager)];
                end
                H5G.close(g);
            end

            if H5.exists(fid, '/row_support')
                did = H5D.open(fid, '/row_support');
                info = H5.dsetInfo(did);
                d.rowSupport = int32(H5.readData(did, info));
                d.rowSupport = reshape(d.rowSupport, 1, []);
                H5D.close(did);
            end

            if H5.exists(fid, '/supports')
                g = H5G.open(fid, '/supports');
                for name = H5.children(g)
                    d.supports = [d.supports ...
                        mestra.internal.Reader.readSupport(g, name{1}, eager)];
                end
                H5G.close(g);
            end

            if H5.exists(fid, '/callables')
                g = H5G.open(fid, '/callables');
                for name = H5.children(g)
                    d.callables = [d.callables ...
                        mestra.internal.Reader.readCallable(g, name{1})];
                end
                H5G.close(g);
            end

            if H5.exists(fid, '/notes')
                g = H5G.open(fid, '/notes');
                d.notes = H5.captureTree(g);
                H5G.close(g);
            end
            if H5.exists(fid, '/private')
                g = H5G.open(fid, '/private');
                d.privateTree = H5.captureTree(g);
                H5G.close(g);
            end

            for name = H5.children(root)
                if ismember(name{1}, mestra.internal.Reader.ROOT_GROUPS) && ...
                   strcmp(H5.childType(root, name{1}), 'group')
                    d.groupsPresent{end + 1} = name{1};
                end
                if mestra.internal.Reader.knownRootChild(root, name{1})
                    continue
                end
                if strcmp(H5.childType(root, name{1}), 'group')
                    g = H5G.open(root, name{1});
                    d.unknownGroups{end + 1} = ...
                        struct('name', name{1}, 'tree', H5.captureTree(g));
                    H5G.close(g);
                else
                    d.unknownGroups{end + 1} = ...
                        struct('name', name{1}, 'tree', []);
                end
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
            if strcmp(mestra.internal.H5.childType(root, name), 'dataset')
                did = H5D.open(root, name);
                info = mestra.internal.H5.dsetInfo(did);
                H5D.close(did);
                tf = info.isScale;   % any other scale is the container's
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
            if ~mestra.internal.H5.exists(fid, '/row'), return, end
            did = H5D.open(fid, '/row');
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
            sid = H5G.open(g, name);
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
                if H5.exists(sid, plain{i, 1})
                    did = H5D.open(sid, plain{i, 1});
                    info = H5.dsetInfo(did);
                    rec(1).(plain{i, 2}) = ...
                        reshape(H5.readData(did, info), 1, []);
                    H5D.close(did);
                end
            end
            if H5.exists(sid, 'coordinates')
                rec(1).coordinates = mestra.internal.Reader.readSlot( ...
                    sid, 'coordinates', name, 'node', eager);
            end
            if H5.exists(sid, 'node_arrays')
                ng = H5G.open(sid, 'node_arrays');
                for nm = H5.children(ng)
                    rec(1).nodeArrays(end + 1) = ...
                        mestra.internal.Reader.readSlot(ng, nm{1}, name, ...
                                                        'node', eager);
                end
                H5G.close(ng);
            end
            if H5.exists(sid, 'cell_arrays')
                cg = H5G.open(sid, 'cell_arrays');
                for nm = H5.children(cg)
                    rec(1).cellArrays(end + 1) = ...
                        mestra.internal.Reader.readSlot(cg, nm{1}, name, ...
                                                        'cell', eager);
                end
                H5G.close(cg);
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

        function rec = readCallable(g, id)
        %readCallable  One callable: its type, its dictionary and, when
        %   the type is registered, the object itself.  A reader that
        %   does not know the type keeps the dictionary and must not
        %   interpret it (section 25).
            gid = H5G.open(g, id);
            rec = mestra.Dataset.emptyCallable();
            rec(1).id = id;
            rec(1).type = mestra.internal.Reader.str(gid, 'type');
            rec(1).repr = mestra.internal.Reader.str(gid, 'repr');
            rec(1).dict = mestra.internal.Codec.read(gid, true);
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
        %str  A string attribute, or '' when it is not there.
            v = '';
            try
                if mestra.internal.H5.hasAttr(oid, name)
                    v = mestra.internal.H5.readAttr(oid, name);
                    if ~ischar(v), v = ''; end
                end
            catch
            end
        end

        function v = num(oid, name)
        %num  A numeric attribute, or [] when it is not there.
            v = [];
            try
                if mestra.internal.H5.hasAttr(oid, name)
                    raw = mestra.internal.H5.readAttr(oid, name);
                    if isnumeric(raw), v = double(raw); end
                end
            catch
            end
        end
    end
end
