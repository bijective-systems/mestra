function out = permute(array, names, wanted)
%MESTRA.PERMUTE  Reorder an array's axes by dimension name.
%
%   OUT = MESTRA.PERMUTE(ARRAY, NAMES, WANTED) returns ARRAY with its
%   axes in the order WANTED names.  NAMES names the axes of ARRAY, one
%   entry per axis and in the array's own order; WANTED names the axes
%   of the result.
%
%   This is the only safe way to move between the file's logical axis
%   order and MATLAB's.  Specification section 4 requires a reader in a
%   column-major language to expose the dimension names so that a user
%   permutes by name and never by position; section 29 requires the
%   reader to offer it.  A mestra.Dataset hands you NAMES with every
%   array, as the `dims` field.
%
%   A name in WANTED that ARRAY does not have becomes an axis of length
%   one, so a two-dimensional field can be asked for with a component
%   axis.  A name in NAMES that WANTED leaves out is dropped when its
%   length is one and is an error otherwise, so nothing is silently
%   folded away.
%
%   Example
%
%       a = d.nodeArray('s0', 'pressure');
%       a.dims                                  % component node row
%       p = mestra.permute(a.values, a.dims, {'row', 'node'});
%       p(2, 4)                                 % row 2, node 4
%
%   See also mestra.Dataset, mestra.read.

    if ischar(names), names = {names}; end
    if ischar(wanted), wanted = {wanted}; end
    if isstring(names), names = cellstr(names); end
    if isstring(wanted), wanted = cellstr(wanted); end
    names = reshape(names, 1, []);
    wanted = reshape(wanted, 1, []);

    nd = max(numel(names), 1);
    sz = size(array);
    if numel(sz) > numel(names)
        if any(sz(numel(names) + 1:end) ~= 1)
            error('mestra:dims', ...
                  'the array has %d axes and %d names; name every axis', ...
                  numel(sz), numel(names));
        end
        sz = sz(1:nd);
    elseif numel(sz) < nd
        sz(end + 1:nd) = 1;
    end

    for i = 1:numel(names)
        if ~ismember(names{i}, wanted) && sz(i) ~= 1
            error('mestra:dims', ...
                  ['dimension "%s" has length %d and is not in the ' ...
                   'wanted order; nothing may be folded away'], ...
                  names{i}, sz(i));
        end
    end

    present = [];
    outSize = ones(1, max(numel(wanted), 2));
    for i = 1:numel(wanted)
        j = find(strcmp(names, wanted{i}), 1);
        if isempty(j)
            outSize(i) = 1;
        else
            present(end + 1) = j; %#ok<AGROW>
            outSize(i) = sz(j);
        end
    end
    rest = setdiff(1:nd, present);
    order = [present rest];

    padded = [sz ones(1, max(0, 2 - nd))];
    array = reshape(array, padded);
    if numel(order) < numel(padded)
        order = [order numel(order) + 1:numel(padded)];
    end
    permuted = builtin('permute', array, order);
    out = reshape(permuted, outSize);
end
