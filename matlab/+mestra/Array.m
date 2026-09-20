classdef Array
%mestra.Array  An array leaf of a callable's dictionary.
%
%   The dictionary codec of specification sections 17 and 25 stores a
%   number as an attribute and an array as a dataset, and the two stay
%   different across a round trip.  MATLAB cannot tell a scalar from a
%   one-element array, so this wrapper marks the array case: every
%   dataset leaf a dictionary holds is a mestra.Array and every
%   attribute leaf is a bare MATLAB scalar.
%
%   The contents are held with the file's own subscripts, so
%   A.data(i, j) is the element the file stores at (i-1, j-1).  The
%   shape is taken from the data unless it is given:
%
%       an N-by-1 column, or an empty, or a 1-by-1   ->  shape (N)
%       anything else                                ->  size(data)
%
%   so a column vector is a list and a row vector is a one-row matrix.
%   Pass the shape when neither is what you mean.
%
%   Allowed contents are double (float64), int64, int32, logical
%   (stored as int8, which means boolean there), and a string array or
%   cell array of char (a list of fixed-length UTF-8 strings).  A
%   zero-dimensional array is not representable: write the number.
%
%   Examples
%
%       b = mestra.Array(0.05);                 % a dataset of shape (1)
%       A = mestra.Array([2.0 0.1]);            % shape (1, 2)
%       s = mestra.Array(int64([6; 1]));        % shape (2)
%       e = mestra.Array(int64([]));            % an empty int64 dataset
%       k = mestra.Array(["mach"; "alpha"]);    % a list of two strings
%
%   See also mestra.Callable, mestra.Affine.

    properties
        % The array, with the file's own subscripts.
        data
        % The shape in file (C) axis order.
        shape
    end

    methods
        function obj = Array(data, shape)
        %Array  Wrap an array as a dictionary dataset leaf.
            if nargin == 0, data = []; end
            if ischar(data), data = {data}; end
            obj.data = data;
            if nargin >= 2 && ~isempty(shape)
                obj.shape = double(shape(:)');
            else
                obj.shape = mestra.Array.inferShape(data);
            end
        end

        function t = dtype(obj)
        %dtype  The short type name this array is stored as.
            if iscell(obj.data) || isstring(obj.data)
                t = 'string';
            elseif islogical(obj.data)
                t = 'int8';
            elseif isa(obj.data, 'int64')
                t = 'int64';
            elseif isa(obj.data, 'int32')
                t = 'int32';
            elseif isa(obj.data, 'double')
                t = 'float64';
            else
                t = '';
            end
        end

        function v = elements(obj)
        %elements  The elements flattened in C order.
        %   This is the order the conformance corpus lists them in.
            if iscell(obj.data) || isstring(obj.data)
                v = obj.data(:)';
                if isstring(v), v = cellstr(v); end
                return
            end
            if isempty(obj.data)
                v = obj.data([]);
                v = v(:)';
                return
            end
            a = reshape(obj.data, [obj.shape 1 1]);
            n = numel(obj.shape);
            if n > 1
                a = builtin('permute', a, n:-1:1);
            end
            v = reshape(a, 1, []);
        end

        function buf = buffer(obj)
        %buffer  The data in the axis order H5D.write expects, which
        %   is the reverse of the file's.
            if iscell(obj.data) || isstring(obj.data)
                buf = obj.data(:)';
                if isstring(buf), buf = cellstr(buf); end
                return
            end
            if any(obj.shape == 0)
                buf = obj.data;
                return
            end
            a = reshape(obj.data, [obj.shape 1 1]);
            n = numel(obj.shape);
            if n > 1
                buf = builtin('permute', a, n:-1:1);
            else
                buf = a(:);
            end
        end

        function disp(obj)
        %disp  One line naming the type and the shape.
            fprintf('  mestra.Array %s %s\n', obj.dtype(), ...
                    mat2str(obj.shape));
        end
    end

    methods (Static)
        function s = inferShape(data)
        %inferShape  The shape rule this class documents.
            if isempty(data)
                s = 0;
                return
            end
            sz = size(data);
            if numel(sz) == 2 && sz(2) == 1
                s = sz(1);
            elseif numel(sz) == 2 && all(sz == 1)
                s = 1;
            else
                s = sz;
            end
        end

        function obj = fromFile(elements, shape, dtype)
        %fromFile  Rebuild an array from its C-order elements.
            shape = double(shape(:)');
            if strcmp(dtype, 'string')
                obj = mestra.Array(reshape(cellstr(elements(:)), [], 1), shape);
                return
            end
            switch dtype
                case 'int8',    v = logical(elements);
                case 'int32',   v = int32(elements);
                case 'int64',   v = int64(elements);
                otherwise,      v = double(elements);
            end
            if any(shape == 0)
                obj = mestra.Array(reshape(v, [shape 1]), shape);
                return
            end
            n = numel(shape);
            a = reshape(v, [fliplr(shape) 1 1]);
            if n > 1
                a = builtin('permute', a, n:-1:1);
                a = reshape(a, [shape 1 1]);
            else
                a = reshape(a, [], 1);
            end
            obj = mestra.Array(a, shape);
        end
    end
end
