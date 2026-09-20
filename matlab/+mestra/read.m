function d = read(path, varargin)
%MESTRA.READ  Read a mestra file into a mestra.Dataset.
%
%   D = MESTRA.READ(PATH) reads everything: the keys with their roles
%   and bounds, the scalars, the supports with their coordinates, cell
%   types, offsets, connectivity, labels and ids, the node and cell
%   arrays, the category tables, the alignment flag, the per-row
%   support column, the callables and the metadata.
%
%   AXIS ORDER.  HDF5 stores an array in C order and MATLAB is column
%   major, so every array comes back with its axes REVERSED with
%   respect to the file.  A node array stored as
%
%       (row, node, component)
%
%   is returned as a MATLAB array of size
%
%       (component, node, row)
%
%   and its `dims` field names those axes in that same order.  This is
%   correct and expected (specification section 4): what two readers
%   in two languages must agree on is the value at (row r, node n,
%   component c), found by the dimension names and never by the axis
%   positions.  Use MESTRA.PERMUTE to get the order you want.
%
%       d = mestra.read('mesh_two_rows.mes');
%       a = d.nodeArray('s0', 'pressure');
%       a.dims                          % {'component', 'node', 'row'}
%       p = mestra.permute(a.values, a.dims, {'row', 'node', 'component'});
%       p(2, 4, 1)                      % 204
%
%   UNTRUSTED INPUT.  A file this package did not write is not
%   trusted.  A link that is not a hard link is never followed, an
%   object that cannot be read is never guessed at, nesting is
%   bounded, and an eager read refuses a dataset above
%   mestra.limits('maxElements').  By default such a file is REFUSED
%   rather than half read: the identifier is mestra:E40 for a link,
%   mestra:E41 for anything else, mestra:E01 for another major
%   version, and mestra:reader for a file that will not open at all.
%
%   D = MESTRA.READ(PATH, 'Strict', false) returns what could be read
%   instead, with one line in D.skipped for everything passed over.
%   An attribute or a group this version does not know is always
%   ignored, kept, and reported by MESTRA.VALIDATE as W11.
%
%   MESTRA.OPEN reads the same file without reading any array, which
%   is what section 29 asks of a reader that is only being asked what
%   is in the file.
%
%   See also mestra.open, mestra.write, mestra.validate,
%   mestra.evaluate, mestra.permute, mestra.Dataset.

    strict = mestra.internal.Reader.strictOption(varargin);
    d = mestra.internal.Reader.load(path, true, strict);
end
