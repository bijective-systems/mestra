function d = open(path)
%MESTRA.OPEN  Read a file's structure without reading any array.
%
%   D = MESTRA.OPEN(PATH) returns a mestra.Dataset that knows the row
%   count, every key with its role and bounds, every support with its
%   id, and every slot with its attributes and its dimension names,
%   having read attributes and dataspaces only.  Specification section
%   29 requires a reader to be able to do this.
%
%   The `values` field of every key, scalar and array is empty.  Read
%   what you need with the dataset's readRows method, which touches
%   only the chunks that hold those rows:
%
%       d = mestra.open('big.mes');
%       d.nRows
%       chunk = d.readRows('/supports/s0/node_arrays/pressure', [1 100]);
%       chunk.dims        % names the axes of chunk.values
%
%   Use MESTRA.READ when you want the whole file.
%
%   See also mestra.read, mestra.Dataset.

    d = mestra.internal.Reader.load(path, false);
end
