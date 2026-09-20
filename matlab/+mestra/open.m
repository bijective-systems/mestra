function d = open(path, varargin)
%MESTRA.OPEN  Read a file's structure without reading any array.
%
%   D = MESTRA.OPEN(PATH) returns a mestra.Dataset that knows the row
%   count, every key with its role and bounds, every support with its
%   id, and every slot with its attributes and its dimension names,
%   having read attributes and dataspaces only.  Specification section
%   29 requires a reader to be able to do this.
%
%   Section 7 of docs/api-conventions.md says what this much is: an
%   open reads attributes, dataspaces, link types and dimension-scale
%   structure, and reads a category table in full, because tables are
%   small by construction and the open needs them to name E10, E26 and
%   E41 on the same files MESTRA.READ names them on.  It never reads a
%   slot's data and never reads a dataset inside a callable's
%   dictionary.
%
%   The `values` field of every key, scalar and array is empty, and so
%   is every callable's `dict`: the dictionary is walked, so that one
%   nested past mestra.limits('maxDepth') is still E41, and dropped
%   rather than handed back with its arrays missing.  A callable's
%   `id`, `type` and `repr` are attributes and are there.  Read what
%   you need with the dataset's readRows method, which touches only
%   the chunks that hold those rows:
%
%       d = mestra.open('big.mes');
%       d.nRows
%       chunk = d.readRows('/supports/s0/node_arrays/pressure', [1 100]);
%       chunk.dims        % names the axes of chunk.values
%
%   Opening reads no array, so a slot or a dictionary dataset larger
%   than the maxElements limit is no obstacle to it; only an eager
%   read refuses one (E41).  A category table above it is E41 from
%   both, because an open reads those.  Everything else about
%   untrusted input is as MESTRA.READ describes, including
%   'Strict', false.
%
%   Use MESTRA.READ when you want the whole file.
%
%   See also mestra.read, mestra.Dataset.

    strict = mestra.internal.Reader.strictOption(varargin);
    d = mestra.internal.Reader.load(path, false, strict);
end
