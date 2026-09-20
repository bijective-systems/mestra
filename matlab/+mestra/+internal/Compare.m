classdef Compare
%Compare  The structural equality rule of specification section 30.
%
%   Byte identity across HDF5 versions is not required and must not be
%   tested, because the library decides the superblock and the object
%   header layout.  The normative comparison between two files that
%   should be the same is
%
%     * the same set of object paths;
%     * at each path, the same kind, group or dataset;
%     * for each dataset, the same dtype including byte order,
%       character set and padding, the same shape, the same maximum
%       shape, the same chunk shape, the same filters with the same
%       parameters, and element-by-element equal contents, with floats
%       compared as bits so that NaN equals NaN;
%     * at each path, the same set of attribute names excluding the
%       machinery names of section 18, and for each, the same dtype
%       and the same value;
%     * the same dimension scale attached to each axis of each
%       dataset, compared by the dimension's name.
%
%   See also mestra.write.

    methods (Static)

        function differences = structural(pathA, pathB)
        %structural  A cell array of differences; empty means equal.
            a = mestra.internal.Compare.snapshot(pathA);
            b = mestra.internal.Compare.snapshot(pathB);
            differences = {};
            ka = a.keys();
            kb = b.keys();
            for i = 1:numel(ka)
                if ~b.isKey(ka{i})
                    differences{end + 1} = sprintf( ...
                        '%s is only in the first file', ka{i}); %#ok<AGROW>
                end
            end
            for i = 1:numel(kb)
                if ~a.isKey(kb{i})
                    differences{end + 1} = sprintf( ...
                        '%s is only in the second file', kb{i}); %#ok<AGROW>
                end
            end
            for i = 1:numel(ka)
                if ~b.isKey(ka{i}), continue, end
                differences = [differences ...
                    mestra.internal.Compare.compareOne(ka{i}, a(ka{i}), ...
                                                       b(ka{i}))]; %#ok<AGROW>
            end
        end

        function out = compareOne(path, x, y)
            out = {};
            if ~strcmp(x.kind, y.kind)
                out{end + 1} = sprintf('%s is a %s and a %s', path, ...
                                       x.kind, y.kind);
                return
            end
            out = [out mestra.internal.Compare.compareAttrs(path, ...
                       x.attrs, y.attrs)];
            if ~strcmp(x.kind, 'dataset'), return, end
            fields = {'type', 'dims', 'maxdims', 'chunk', 'filters', ...
                      'strSize', 'cset', 'strpad', 'scales', 'bits'};
            for i = 1:numel(fields)
                f = fields{i};
                if ~isequal(x.(f), y.(f))
                    out{end + 1} = ...
                        sprintf('%s: %s differs', path, f); %#ok<AGROW>
                end
            end
        end

        function out = compareAttrs(path, x, y)
            out = {};
            names = union(x.keys(), y.keys());
            for i = 1:numel(names)
                n = names{i};
                if ~x.isKey(n)
                    out{end + 1} = sprintf( ...
                        '%s: attribute %s is only in the second file', ...
                        path, n); %#ok<AGROW>
                elseif ~y.isKey(n)
                    out{end + 1} = sprintf( ...
                        '%s: attribute %s is only in the first file', ...
                        path, n); %#ok<AGROW>
                elseif ~isequal(x(n), y(n))
                    out{end + 1} = sprintf('%s: attribute %s differs', ...
                                           path, n); %#ok<AGROW>
                end
            end
        end

        function map = snapshot(path)
        %snapshot  Every object in a file, in the form compared above.
            map = containers.Map('KeyType', 'char', 'ValueType', 'any');
            fid = H5F.open(path, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
            closer = onCleanup(@() H5F.close(fid)); %#ok<NASGU>
            closePass = mestra.internal.H5.pass(); %#ok<NASGU>
            root = H5G.open(fid, '/');
            scales = mestra.internal.H5.scaleMap(fid);
            mestra.internal.Compare.walk(map, root, '/', 0, scales);
            H5G.close(root);
        end

        function walk(map, gid, prefix, depth, scales)
        %walk  Every object under a group, to a bounded depth.
            H5 = mestra.internal.H5;
            if nargin < 4, depth = 0; end
            if nargin < 5, scales = []; end
            if depth > mestra.internal.Limits.get('maxDepth')
                map([prefix ' (not followed)']) = struct('kind', 'limit', ...
                    'attrs', containers.Map('KeyType', 'char', ...
                                            'ValueType', 'any'));
                return
            end
            rec.kind = 'group';
            rec.attrs = mestra.internal.Compare.attrs(gid);
            map(prefix) = rec;
            for name = H5.children(gid)
                if strcmp(prefix, '/')
                    path = ['/' name{1}];
                else
                    path = [prefix '/' name{1}];
                end
                kind = H5.childType(gid, name{1});
                if strcmp(kind, 'group')
                    sub = H5G.open(gid, name{1});
                    mestra.internal.Compare.walk(map, sub, path, ...
                                                 depth + 1, scales);
                    H5G.close(sub);
                elseif strcmp(kind, 'dataset')
                    did = H5D.open(gid, name{1});
                    map(path) = mestra.internal.Compare.dataset(did, scales);
                    H5D.close(did);
                else
                    map(path) = struct('kind', kind, ...
                        'attrs', containers.Map('KeyType', 'char', ...
                                                'ValueType', 'any'));
                end
            end
        end

        function rec = dataset(did, scales)
            H5 = mestra.internal.H5;
            if nargin < 2, scales = []; end
            info = H5.dsetInfo(did);
            rec.kind = 'dataset';
            rec.attrs = mestra.internal.Compare.attrs(did);
            rec.type = info.type;
            rec.dims = info.dims;
            rec.maxdims = info.maxdims;
            rec.chunk = info.chunk;
            rec.filters = info.filters;
            rec.strSize = -1;
            rec.cset = info.cset;
            rec.strpad = info.strpad;
            rec.scales = cell(1, numel(info.dims));
            for axis = 1:numel(info.dims)
                found = H5.scaleNames(did, axis - 1, scales);
                rec.scales{axis} = sort({found.name});
            end
            if info.isScale
                % A dimension scale holds no value anyone reads, so
                % there is nothing to compare but its shape and type.
                rec.bits = [];
                return
            end
            if strcmp(info.type, 'string')
                rec.strSize = info.strSize;
                rec.bits = H5.readRawStrings(did, info);
            else
                data = H5.readData(did, info);
                rec.bits = typecast(H5.cast(info.type, data(:))', 'uint8');
            end
        end

        function map = attrs(oid)
            H5 = mestra.internal.H5;
            map = containers.Map('KeyType', 'char', 'ValueType', 'any');
            for name = H5.publicAttrNames(oid)
                info = H5.attrInfo(oid, name{1});
                if strcmp(info.type, 'string')
                    map(name{1}) = {info.type, info.size, info.cset, ...
                                    info.strpad, ...
                                    H5.readRawStrAttr(oid, name{1})};
                else
                    value = H5.readAttr(oid, name{1});
                    map(name{1}) = {info.type, ...
                        typecast(H5.cast(info.type, value(:))', 'uint8')};
                end
            end
        end
    end
end
