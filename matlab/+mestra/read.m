function d = read(path)
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
%   A file whose `format` names another major version is refused
%   outright, with the identifier mestra:E01; it is never read
%   partially.  An attribute or a group this version does not know is
%   ignored, kept, and reported by MESTRA.VALIDATE as W11.
%
%   MESTRA.OPEN reads the same file without reading any array, which
%   is what section 29 asks of a reader that is only being asked what
%   is in the file.
%
%   See also mestra.open, mestra.write, mestra.validate,
%   mestra.evaluate, mestra.permute, mestra.Dataset.

    d = mestra.internal.Reader.load(path, true);
end
