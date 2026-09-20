classdef H5
%H5  Low-level HDF5 helpers shared by the reader, writer and validator.
%
%   Everything here uses the low-level HDF5 interface (H5F, H5G, H5D,
%   H5A, H5S, H5T, H5P and H5DS).  The high-level interface cannot
%   write fixed-length null-padded UTF-8 strings, cannot attach
%   dimension scales, and cannot turn object time tracking off, so it
%   is not used anywhere in this package.
%
%   Axis order.  HDF5 numbers the axes of a dataset in C order, with
%   the fastest-varying axis last.  MATLAB is column major, so an
%   array read back from HDF5 arrives with its axes reversed: a file
%   array of shape (row, node, component) becomes a MATLAB array of
%   size (component, node, row).  Dimension vectors returned by
%   dsetInfo and taken by createDataset are in FILE order; array data
%   passed to and returned by readData and createDataset is in MATLAB
%   order.  Nothing here reverses silently.
%
%   See also mestra.read, mestra.write, mestra.validate.

    properties (Constant)
        % Attributes written by the HDF5 dimension scale machinery and
        % by the netCDF-C library.  A reader ignores these wherever
        % they appear (specification section 18).
        MACHINERY = {'CLASS', 'NAME', 'DIMENSION_LIST', ...
                     'REFERENCE_LIST', 'DIMENSION_LABELS', ...
                     '_Netcdf4Dimid', '_Netcdf4Coordinates', ...
                     '_nc3_strict', '_NCProperties'};

        % The sentence every dimension scale carries in its NAME
        % attribute (specification section 21).  The dimension's name
        % is the scale's link name, never this.
        SENTENCE = 'This is a netCDF dimension but not a netCDF variable.';
    end

    methods (Static)

        % ---------------------------------------------------- types

        function tid = strType(nbytes)
        %strType  A fixed-length UTF-8 string type with NUL padding.
            tid = H5T.copy('H5T_C_S1');
            H5T.set_size(tid, max(nbytes, 1));
            H5T.set_cset(tid, H5ML.get_constant_value('H5T_CSET_UTF8'));
            H5T.set_strpad(tid, H5ML.get_constant_value('H5T_STR_NULLPAD'));
        end

        function name = typeName(tid)
        %typeName  A short name for an HDF5 type, or '' when it is one
        %   this format never uses.
            cls = H5T.get_class(tid);
            if cls == H5ML.get_constant_value('H5T_STRING')
                if H5T.is_variable_str(tid)
                    name = 'vlstring';
                else
                    name = 'string';
                end
                return
            end
            sz = H5T.get_size(tid);
            if cls == H5ML.get_constant_value('H5T_FLOAT')
                switch sz
                    case 8, name = 'float64';
                    case 4, name = 'float32';
                    otherwise, name = '';
                end
            elseif cls == H5ML.get_constant_value('H5T_INTEGER')
                signed = H5T.get_sign(tid) ~= ...
                         H5ML.get_constant_value('H5T_SGN_NONE');
                switch sz
                    case 8, base = 'int64';
                    case 4, base = 'int32';
                    case 2, base = 'int16';
                    case 1, base = 'int8';
                    otherwise, base = '';
                end
                if isempty(base)
                    name = '';
                elseif signed
                    name = base;
                else
                    name = ['u' base];
                end
            else
                name = '';
            end
        end

        function tid = typeId(name)
        %typeId  The little-endian file type for a short type name.
            switch name
                case 'float64', tid = H5T.copy('H5T_IEEE_F64LE');
                case 'float32', tid = H5T.copy('H5T_IEEE_F32LE');
                case 'int64',   tid = H5T.copy('H5T_STD_I64LE');
                case 'int32',   tid = H5T.copy('H5T_STD_I32LE');
                case 'int8',    tid = H5T.copy('H5T_STD_I8LE');
                case 'uint8',   tid = H5T.copy('H5T_STD_U8LE');
                otherwise
                    error('mestra:internal', ...
                          'no file type for "%s"', name);
            end
        end

        function tid = memType(name)
        %memType  The native memory type for a short type name.
            switch name
                case 'float64', tid = H5T.copy('H5T_NATIVE_DOUBLE');
                case 'float32', tid = H5T.copy('H5T_NATIVE_FLOAT');
                case 'int64',   tid = H5T.copy('H5T_NATIVE_LLONG');
                case 'int32',   tid = H5T.copy('H5T_NATIVE_INT');
                case 'int8',    tid = H5T.copy('H5T_NATIVE_SCHAR');
                case 'uint8',   tid = H5T.copy('H5T_NATIVE_UCHAR');
                otherwise
                    error('mestra:internal', ...
                          'no memory type for "%s"', name);
            end
        end

        function v = cast(name, data)
        %cast  Convert a MATLAB array to the class a type name names.
            switch name
                case {'float64', 'float32'}, v = double(data);
                case 'int64',  v = int64(data);
                case 'int32',  v = int32(data);
                case 'int8',   v = int8(data);
                case 'uint8',  v = uint8(data);
                otherwise,     v = data;
            end
        end

        % ----------------------------------------------- properties

        function plist = plist(class)
        %plist  A creation property list with object time tracking off.
        %   MATLAB does not wrap H5Pset_obj_track_times, so the
        %   underlying "object header flags" property is set directly:
        %   clearing bit 0x20 is exactly what that call does.
            plist = H5P.create(class);
            try
                flags = H5P.get(plist, 'object header flags');
                H5P.set(plist, 'object header flags', ...
                        bitand(uint8(flags), uint8(223)));
            catch
                % An HDF5 build without that property keeps the times;
                % nothing else in this package depends on it.
            end
        end

        % ---------------------------------------------- attributes

        function names = attrNames(oid)
        %attrNames  Every attribute name on an object, in name order.
            info = H5O.get_info(oid);
            n = double(info.num_attrs);
            names = cell(1, n);
            for i = 1:n
                aid = H5A.open_by_idx(oid, '.', 'H5_INDEX_NAME', ...
                                      'H5_ITER_INC', i - 1, ...
                                      'H5P_DEFAULT', 'H5P_DEFAULT');
                names{i} = H5A.get_name(aid);
                H5A.close(aid);
            end
        end

        function names = publicAttrNames(oid)
        %publicAttrNames  Attribute names minus the machinery names.
            names = mestra.internal.H5.attrNames(oid);
            names = names(~ismember(names, mestra.internal.H5.MACHINERY));
        end

        function tf = hasAttr(oid, name)
        %hasAttr  True when the object carries that attribute.
            tf = ismember(name, mestra.internal.H5.attrNames(oid));
        end

        function info = attrInfo(oid, name)
        %attrInfo  How an attribute is encoded.
        %   Fields: type (short type name), size (bytes, strings only),
        %   cset, strpad, scalar (true when the dataspace is scalar).
            aid = H5A.open(oid, name);
            tid = H5A.get_type(aid);
            sid = H5A.get_space(aid);
            info.type = mestra.internal.H5.typeName(tid);
            info.size = H5T.get_size(tid);
            info.cset = -1;
            info.strpad = -1;
            if strcmp(info.type, 'string')
                info.cset = H5T.get_cset(tid);
                info.strpad = H5T.get_strpad(tid);
            end
            info.scalar = H5S.get_simple_extent_type(sid) == ...
                          H5ML.get_constant_value('H5S_SCALAR');
            H5S.close(sid);
            H5T.close(tid);
            H5A.close(aid);
        end

        function v = readAttr(oid, name)
        %readAttr  An attribute as a MATLAB value.
        %   Strings arrive as char with the trailing NUL padding
        %   stripped, booleans as int8, integers as int64, floats as
        %   double.  Nothing here interprets int8 as logical: the
        %   caller knows which attributes are booleans.
            aid = H5A.open(oid, name);
            raw = H5A.read(aid);
            tid = H5A.get_type(aid);
            isStr = H5T.get_class(tid) == ...
                    H5ML.get_constant_value('H5T_STRING');
            H5T.close(tid);
            H5A.close(aid);
            if isStr
                mestra.internal.H5.checkAsciiRead(raw, 0, ...
                    sprintf('the attribute %s', name));
                v = mestra.internal.H5.toText(raw);
            else
                v = raw;
            end
        end

        function s = toText(raw)
        %toText  Bytes from HDF5 to a char row vector.
            if iscell(raw)
                if isempty(raw)
                    s = '';
                else
                    s = mestra.internal.H5.toText(raw{1});
                end
                return
            end
            if isstring(raw)
                s = char(raw(1));
                return
            end
            bytes = uint8(raw(:)');
            last = find(bytes ~= 0, 1, 'last');
            if isempty(last)
                s = '';
            else
                s = native2unicode(bytes(1:last), 'UTF-8');
            end
        end

        function writeStrAttr(oid, name, value)
        %writeStrAttr  A fixed-length UTF-8 attribute, NUL padded.
            bytes = unicode2native(value, 'UTF-8');
            mestra.internal.H5.checkAsciiBytes(bytes, ...
                sprintf('the attribute %s', name));
            n = max(numel(bytes), 1);
            tid = mestra.internal.H5.strType(n);
            sid = H5S.create('H5S_SCALAR');
            aid = H5A.create(oid, name, tid, sid, 'H5P_DEFAULT');
            buf = char(zeros(1, n));
            buf(1:numel(bytes)) = char(double(bytes));
            H5A.write(aid, tid, buf);
            H5A.close(aid); H5S.close(sid); H5T.close(tid);
        end

        function writeRawStrAttr(oid, name, bytes)
        %writeRawStrAttr  A fixed-length string attribute, byte exact.
        %   Used for the null sentinel of section 18, whose first byte
        %   is NUL and which therefore cannot go through unicode2native
        %   and back.
            n = max(numel(bytes), 1);
            tid = mestra.internal.H5.strType(n);
            sid = H5S.create('H5S_SCALAR');
            aid = H5A.create(oid, name, tid, sid, 'H5P_DEFAULT');
            buf = char(zeros(1, n));
            buf(1:numel(bytes)) = char(double(uint8(bytes)));
            H5A.write(aid, tid, buf);
            H5A.close(aid); H5S.close(sid); H5T.close(tid);
        end

        function bytes = readRawStrAttr(oid, name)
        %readRawStrAttr  A string attribute as its stored bytes.
            aid = H5A.open(oid, name);
            raw = H5A.read(aid);
            H5A.close(aid);
            if iscell(raw), raw = raw{1}; end
            mestra.internal.H5.checkAsciiRead(raw, 0, ...
                sprintf('the attribute %s', name));
            bytes = uint8(raw(:)');
        end

        function writeNumAttr(oid, name, value, typeName)
        %writeNumAttr  A scalar numeric or boolean attribute.
            ftid = mestra.internal.H5.typeId(typeName);
            mtid = mestra.internal.H5.memType(typeName);
            sid = H5S.create('H5S_SCALAR');
            aid = H5A.create(oid, name, ftid, sid, 'H5P_DEFAULT');
            H5A.write(aid, mtid, mestra.internal.H5.cast(typeName, value));
            H5A.close(aid); H5S.close(sid);
            H5T.close(ftid); H5T.close(mtid);
        end

        % ------------------------------------------- the ASCII wall

        function checkAsciiBytes(bytes, where)
        %checkAsciiBytes  Refuse to write a string MATLAB would mangle.
        %   MATLAB's HDF5 interface writes a fixed-length string from a
        %   char array and refuses any code above 127, so a non-ASCII
        %   UTF-8 string cannot be written through it at all.  Saying
        %   so here is better than the library's own message, and far
        %   better than writing something else.
            if any(uint8(bytes) > 127)
                error('mestra:matlabAscii', ...
                      ['%s holds a byte above 127. MATLAB''s HDF5 ' ...
                       'interface writes a fixed-length string only ' ...
                       'from ASCII characters, so this package cannot ' ...
                       'write non-ASCII UTF-8 strings. Keep names, ' ...
                       'category entries and string ids ASCII.'], where);
            end
        end

        function checkAsciiRead(raw, expected, where)
        %checkAsciiRead  Refuse to hand back a string MATLAB mangled.
        %   MATLAB decodes a fixed-length string as text before this
        %   package sees it: with a UTF-8 locale it turns the bytes
        %   into characters, which breaks the fixed blocking, and
        %   otherwise it replaces them.  Either way the bytes are lost,
        %   so an ASCII-only file is the only one that can be trusted.
            if ischar(raw) && any(double(raw(:)) > 127)
                error('mestra:matlabAscii', ...
                      ['%s holds a byte above 127. MATLAB''s HDF5 ' ...
                       'interface decodes a fixed-length string before ' ...
                       'this package sees it, so the stored bytes ' ...
                       'cannot be recovered and nothing is returned ' ...
                       'rather than something wrong.'], where);
            end
            if expected > 0 && numel(raw) ~= expected
                error('mestra:matlabAscii', ...
                      ['%s came back as %d characters where the file ' ...
                       'stores %d bytes; MATLAB re-encoded it.'], ...
                      where, numel(raw), expected);
            end
        end

        % ---------------------------------------------------- links

        function names = children(gid)
        %children  The link names of a group, sorted by UTF-8 bytes.
            info = H5G.get_info(gid);
            n = double(info.nlinks);
            names = cell(1, n);
            for i = 1:n
                names{i} = H5L.get_name_by_idx(gid, '.', ...
                    'H5_INDEX_NAME', 'H5_ITER_INC', i - 1, 'H5P_DEFAULT');
            end
            names = mestra.internal.H5.sortByBytes(names);
        end

        function out = sortByBytes(names)
        %sortByBytes  Sort names by their UTF-8 bytes.
        %   This is the one ordering every language produces
        %   identically (specification section 22).
            if isempty(names), out = names; return, end
            n = numel(names);
            keys = cell(1, n);
            for i = 1:n
                keys{i} = double(unicode2native(names{i}, 'UTF-8'));
            end
            order = 1:n;
            for i = 2:n
                j = i;
                while j > 1 && mestra.internal.H5.byteLess( ...
                        keys{order(j)}, keys{order(j - 1)})
                    t = order(j); order(j) = order(j - 1); order(j - 1) = t;
                    j = j - 1;
                end
            end
            out = names(order);
        end

        function tf = byteLess(a, b)
        %byteLess  Lexicographic comparison of two byte vectors.
            m = min(numel(a), numel(b));
            for k = 1:m
                if a(k) ~= b(k)
                    tf = a(k) < b(k);
                    return
                end
            end
            tf = numel(a) < numel(b);
        end

        function t = childType(gid, name)
        %childType  'group', 'dataset' or 'other'.
            oid = H5O.open(gid, name, 'H5P_DEFAULT');
            kind = H5I.get_type(oid);
            H5O.close(oid);
            if kind == H5ML.get_constant_value('H5I_GROUP')
                t = 'group';
            elseif kind == H5ML.get_constant_value('H5I_DATASET')
                t = 'dataset';
            else
                t = 'other';
            end
        end

        function tf = exists(loc, path)
        %exists  True when a path exists under a location.
            parts = strsplit(path, '/');
            parts = parts(~cellfun(@isempty, parts));
            tf = true;
            here = '';
            for i = 1:numel(parts)
                if isempty(here)
                    here = parts{i};
                else
                    here = [here '/' parts{i}]; %#ok<AGROW>
                end
                if ~H5L.exists(loc, here, 'H5P_DEFAULT')
                    tf = false;
                    return
                end
            end
        end

        % -------------------------------------------------- datasets

        function info = dsetInfo(did)
        %dsetInfo  Shape, storage and type of a dataset, in FILE order.
        %   Fields: type, dims, maxdims (-1 for unlimited), chunk ([]
        %   when contiguous), filters (an n-by-2 matrix of filter id
        %   and first parameter), strSize, cset, strpad, isScale.
            sid = H5D.get_space(did);
            [~, dims, maxdims] = H5S.get_simple_extent_dims(sid);
            H5S.close(sid);
            info.dims = double(dims);
            info.maxdims = double(maxdims);
            tid = H5D.get_type(did);
            info.type = mestra.internal.H5.typeName(tid);
            info.strSize = H5T.get_size(tid);
            info.cset = -1; info.strpad = -1;
            if strcmp(info.type, 'string')
                info.cset = H5T.get_cset(tid);
                info.strpad = H5T.get_strpad(tid);
            end
            H5T.close(tid);
            dcpl = H5D.get_create_plist(did);
            if H5P.get_layout(dcpl) == H5ML.get_constant_value('H5D_CHUNKED')
                [~, chunk] = H5P.get_chunk(dcpl);
                info.chunk = double(chunk);
            else
                info.chunk = [];
            end
            nf = H5P.get_nfilters(dcpl);
            info.filters = zeros(nf, 2);
            for i = 1:nf
                [fid, ~, cd] = H5P.get_filter(dcpl, i - 1);
                p = 0;
                if ~isempty(cd), p = double(cd(1)); end
                info.filters(i, :) = [double(fid) p];
            end
            H5P.close(dcpl);
            info.isScale = false;
            try
                info.isScale = H5DS.is_scale(did) > 0;
            catch
            end
        end

        function names = scaleNames(did, axis)
        %scaleNames  The link names of the scales attached to one axis.
        %   `axis` is zero based and in FILE order.  The name comes
        %   from the link and never from the NAME attribute, which
        %   holds the same sentence in every scale in the file
        %   (specification section 21).
        %   DIMENSION_LIST is read directly rather than through
        %   H5DS.iterate_scales, which in MATLAB refuses a handle to a
        %   function inside a package.  The attribute holds one list of
        %   object references per axis, in file axis order, and each
        %   reference is eight bytes.
            names = {};
            if ~mestra.internal.H5.hasAttr(did, 'DIMENSION_LIST')
                return
            end
            aid = H5A.open(did, 'DIMENSION_LIST');
            list = H5A.read(aid);
            H5A.close(aid);
            if ~iscell(list) || axis + 1 > numel(list)
                return
            end
            refs = uint8(list{axis + 1}(:));
            for k = 1:8:numel(refs)
                try
                    full = H5R.get_name(did, 'H5R_OBJECT', refs(k:k + 7));
                    parts = strsplit(full, '/');
                    names{end + 1} = parts{end}; %#ok<AGROW>
                catch
                end
            end
        end

        function n = numScales(did, axis)
        %numScales  How many scales are attached to one axis.
            n = double(H5DS.get_num_scales(did, axis));
        end

        function data = readData(did, info)
        %readData  A whole dataset, in MATLAB axis order.
        %   Strings come back as a cell array of char row vectors.
            if nargin < 2
                info = mestra.internal.H5.dsetInfo(did);
            end
            if strcmp(info.type, 'string')
                raw = H5D.read(did);
                count = prod(max(info.dims, 0));
                mestra.internal.H5.checkAsciiRead(raw, ...
                    info.strSize * count, 'a fixed-length string dataset');
                data = mestra.internal.H5.splitStrings(raw, count);
                return
            end
            if any(info.dims == 0)
                data = zeros([fliplr(info.dims) 1 1]);
                data = mestra.internal.H5.cast(info.type, data);
                return
            end
            data = H5D.read(did);
        end

        function out = splitStrings(raw, n)
        %splitStrings  A fixed-length string buffer to a cell array.
            out = cell(1, n);
            if n == 0, return, end
            if iscell(raw)
                for i = 1:n
                    out{i} = mestra.internal.H5.toText(raw{i});
                end
                return
            end
            m = numel(raw) / n;
            buf = reshape(raw, m, n);
            for i = 1:n
                out{i} = mestra.internal.H5.toText(buf(:, i)');
            end
        end

        function raw = readRawStrings(did, info)
        %readRawStrings  A fixed-length string dataset as its bytes.
        %   Returns a size-by-count uint8 matrix, padding and all, so
        %   that a validator can see a NUL where it should not be.
            n = prod(max(info.dims, 0));
            raw = zeros(info.strSize, n, 'uint8');
            if n == 0, return, end
            buf = H5D.read(did);
            mestra.internal.H5.checkAsciiRead(buf, info.strSize * n, ...
                'a fixed-length string dataset');
            if iscell(buf)
                for i = 1:n
                    b = uint8(buf{i});
                    raw(1:min(numel(b), info.strSize), i) = ...
                        b(1:min(numel(b), info.strSize))';
                end
            else
                raw = reshape(uint8(buf), info.strSize, n);
            end
        end

        function data = readRows(did, info, first, count)
        %readRows  Rows [first, first+count) of a dataset.
        %   `first` is zero based.  Only the chunks that hold those
        %   rows are touched, which is what section 29 asks a reader
        %   to be able to do.  The result is in MATLAB axis order.
            fileSid = H5D.get_space(did);
            start = zeros(1, numel(info.dims));
            block = info.dims;
            start(1) = first;
            block(1) = count;
            H5S.select_hyperslab(fileSid, 'H5S_SELECT_SET', start, [], ...
                                 ones(1, numel(block)), block);
            memSid = H5S.create_simple(numel(block), block, block);
            if strcmp(info.type, 'string')
                tid = H5D.get_type(did);
                raw = H5D.read(did, tid, memSid, fileSid, 'H5P_DEFAULT');
                H5T.close(tid);
                mestra.internal.H5.checkAsciiRead(raw, ...
                    info.strSize * prod(block), ...
                    'a fixed-length string dataset');
                data = mestra.internal.H5.splitStrings(raw, prod(block));
            else
                mtid = mestra.internal.H5.memType(info.type);
                data = H5D.read(did, mtid, memSid, fileSid, 'H5P_DEFAULT');
                H5T.close(mtid);
                data = reshape(data, [fliplr(block) 1 1]);
            end
            H5S.close(memSid); H5S.close(fileSid);
        end

        % --------------------------------------------------- writing

        function did = createDataset(gid, name, typeName, dims, maxdims, ...
                                     chunk, filters, strSize)
        %createDataset  Create one dataset, in FILE axis order.
        %   `maxdims` uses -1 for an unlimited extent, `chunk` is []
        %   for contiguous storage, `filters` is an n-by-2 matrix of
        %   filter id and first parameter, and `strSize` is the byte
        %   size of a fixed-length string type.
            if nargin < 7 || isempty(filters), filters = zeros(0, 2); end
            if nargin < 8, strSize = 0; end
            rank = numel(dims);
            hmax = maxdims;
            hmax(maxdims < 0) = H5ML.get_constant_value('H5S_UNLIMITED');
            sid = H5S.create_simple(rank, dims, hmax);
            dcpl = mestra.internal.H5.plist('H5P_DATASET_CREATE');
            if ~isempty(chunk)
                H5P.set_chunk(dcpl, chunk);
            end
            for i = 1:size(filters, 1)
                switch filters(i, 1)
                    case 1, H5P.set_deflate(dcpl, filters(i, 2));
                    case 2, H5P.set_shuffle(dcpl);
                    case 3, H5P.set_fletcher32(dcpl);
                    otherwise
                        error('mestra:E29', ...
                              'filter %d is not allowed (E29)', filters(i, 1));
                end
            end
            if strcmp(typeName, 'string')
                tid = mestra.internal.H5.strType(strSize);
            else
                tid = mestra.internal.H5.typeId(typeName);
            end
            did = H5D.create(gid, name, tid, sid, 'H5P_DEFAULT', dcpl, ...
                             'H5P_DEFAULT');
            H5T.close(tid); H5P.close(dcpl); H5S.close(sid);
        end

        function writeData(did, typeName, data, strSize)
        %writeData  Fill a dataset.  `data` is in MATLAB axis order.
            if strcmp(typeName, 'string')
                tid = mestra.internal.H5.strType(strSize);
                n = numel(data);
                buf = char(zeros(max(strSize, 1), max(n, 1)));
                for i = 1:n
                    bytes = unicode2native(data{i}, 'UTF-8');
                    mestra.internal.H5.checkAsciiBytes(bytes, ...
                        'a fixed-length string dataset');
                    buf(1:numel(bytes), i) = char(double(bytes))';
                end
                if n > 0
                    H5D.write(did, tid, 'H5S_ALL', 'H5S_ALL', ...
                              'H5P_DEFAULT', buf(:, 1:n));
                end
                H5T.close(tid);
                return
            end
            if isempty(data), return, end
            mtid = mestra.internal.H5.memType(typeName);
            H5D.write(did, mtid, 'H5S_ALL', 'H5S_ALL', 'H5P_DEFAULT', ...
                      mestra.internal.H5.cast(typeName, data));
            H5T.close(mtid);
        end

        function did = makeScale(gid, name, len, unlimited)
        %makeScale  A dimension scale, written as netCDF-C writes one.
        %   One-dimensional, big-endian float32, no value ever stored,
        %   CLASS and NAME as section 21 requires.  An unlimited scale
        %   is chunked with chunk length one; a fixed one is chunked
        %   over its whole length, which is what the corpus carries.
            if unlimited
                maxd = H5ML.get_constant_value('H5S_UNLIMITED');
                chunk = 1;
            else
                maxd = len;
                chunk = max(len, 1);
            end
            sid = H5S.create_simple(1, len, maxd);
            dcpl = mestra.internal.H5.plist('H5P_DATASET_CREATE');
            H5P.set_chunk(dcpl, chunk);
            did = H5D.create(gid, name, 'H5T_IEEE_F32BE', sid, ...
                             'H5P_DEFAULT', dcpl, 'H5P_DEFAULT');
            H5P.close(dcpl); H5S.close(sid);
            H5DS.set_scale(did, sprintf('%s%10d', ...
                                        mestra.internal.H5.SENTENCE, len));
        end

        % --------------------------------------- whole subtree copies

        function tree = captureTree(gid)
        %captureTree  Everything under a group, kept as it stands.
        %   Used for /notes, for /private, which section 29 forbids a
        %   reader to interpret, and for any group this version does
        %   not know (section 28).  A round trip through this package
        %   therefore loses none of them.
            H5 = mestra.internal.H5;
            tree.attrs = struct('name', {}, 'type', {}, 'bytes', {}, ...
                                'value', {});
            for name = H5.publicAttrNames(gid)
                info = H5.attrInfo(gid, name{1});
                rec.name = name{1};
                rec.type = info.type;
                rec.bytes = [];
                rec.value = [];
                if strcmp(info.type, 'string')
                    rec.bytes = H5.readRawStrAttr(gid, name{1});
                elseif ~isempty(info.type)
                    rec.value = H5.readAttr(gid, name{1});
                end
                tree.attrs(end + 1) = rec;
            end
            tree.datasets = struct('name', {}, 'info', {}, 'data', {}, ...
                                   'scales', {}, 'label', {});
            tree.groups = struct('name', {}, 'tree', {});
            for name = H5.children(gid)
                if strcmp(H5.childType(gid, name{1}), 'group')
                    sub = H5G.open(gid, name{1});
                    tree.groups(end + 1) = struct('name', name{1}, ...
                        'tree', H5.captureTree(sub));
                    H5G.close(sub);
                else
                    did = H5D.open(gid, name{1});
                    info = H5.dsetInfo(did);
                    rec.name = name{1};
                    rec.info = info;
                    rec.data = [];
                    if ~info.isScale
                        rec.data = H5.readData(did, info);
                    end
                    rec.scales = cell(1, numel(info.dims));
                    for axis = 1:numel(info.dims)
                        found = H5.scaleNames(did, axis - 1);
                        if isempty(found)
                            rec.scales{axis} = '';
                        else
                            rec.scales{axis} = found{1};
                        end
                    end
                    rec.label = '';
                    if info.isScale && H5.hasAttr(did, 'NAME')
                        rec.label = H5.readAttr(did, 'NAME');
                    end
                    tree.datasets(end + 1) = rec;
                    H5D.close(did);
                end
            end
        end

        function replayTree(gid, tree)
        %replayTree  Write back a subtree captureTree took.
            H5 = mestra.internal.H5;
            for i = 1:numel(tree.attrs)
                a = tree.attrs(i);
                if strcmp(a.type, 'string')
                    H5.writeRawStrAttr(gid, a.name, a.bytes);
                elseif ~isempty(a.type)
                    H5.writeNumAttr(gid, a.name, a.value, a.type);
                end
            end
            made = containers.Map('KeyType', 'char', 'ValueType', 'any');
            for i = 1:numel(tree.datasets)
                ds = tree.datasets(i);
                did = H5.createDataset(gid, ds.name, ds.info.type, ...
                    ds.info.dims, ds.info.maxdims, ds.info.chunk, ...
                    ds.info.filters, ds.info.strSize);
                if ds.info.isScale
                    H5DS.set_scale(did, ds.label);
                else
                    H5.writeData(did, ds.info.type, ds.data, ds.info.strSize);
                end
                made(ds.name) = did;
            end
            for i = 1:numel(tree.datasets)
                ds = tree.datasets(i);
                for axis = 1:numel(ds.scales)
                    if ~isempty(ds.scales{axis}) && made.isKey(ds.scales{axis})
                        H5DS.attach_scale(made(ds.name), ...
                                          made(ds.scales{axis}), axis - 1);
                    end
                end
            end
            for key = made.keys()
                H5D.close(made(key{1}));
            end
            for i = 1:numel(tree.groups)
                gcpl = H5.plist('H5P_GROUP_CREATE');
                sub = H5G.create(gid, tree.groups(i).name, 'H5P_DEFAULT', ...
                                 gcpl, 'H5P_DEFAULT');
                H5P.close(gcpl);
                H5.replayTree(sub, tree.groups(i).tree);
                H5G.close(sub);
            end
        end

    end
end
