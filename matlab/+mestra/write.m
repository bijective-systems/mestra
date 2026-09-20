function write(dataset, path)
%MESTRA.WRITE  Write a mestra.Dataset to a conforming file.
%
%   MESTRA.WRITE(DATASET, PATH) writes the file specification sections
%   13 to 25 define:
%
%     * every string, in an attribute or a dataset, fixed length,
%       UTF-8, padded on the right with NUL bytes, and never variable
%       length (section 18);
%     * a dimension scale on every axis of every dataset, named as
%       section 21 requires and written as netCDF-C writes a dimension
%       with no coordinate variable;
%     * `row` unlimited in every file, every row-dimensioned dataset
%       chunked with its non-row extents full, and the default chunk
%       length of section 23 unless the dataset carries another one;
%     * gzip and shuffle as the only filters (section 23);
%     * no HDF5 fill value anywhere (section 19);
%     * object time tracking off on every object, so that two runs
%       given the same dataset differ only where the data differs.
%
%   A slot whose `source` is a callable is written as an empty group
%   with the slot's attributes and no data; a slot holding data is a
%   dataset (section 19).  Callables go through the dictionary codec
%   of sections 17 and 25, with the dictionary's keys visited in
%   ascending order of their UTF-8 bytes so that two writers given the
%   same dictionary produce the same file.
%
%   /notes, /private and any group this version does not know are
%   written back exactly as they were read, so a read-then-write loses
%   nothing.
%
%   The file is created fresh; an existing file at PATH is replaced.
%
%   Example
%
%       d = mestra.read('in.mes');
%       mestra.write(d, 'out.mes');       % structurally equal
%
%   See also mestra.read, mestra.validate, mestra.Dataset.

    if ~isa(dataset, 'mestra.Dataset')
        error('mestra:write', ...
              'the first argument must be a mestra.Dataset');
    end
    mestra.internal.Writer.save(dataset, path);
end
