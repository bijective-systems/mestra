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
%   folded away.  'instance' in WANTED means the group axis, the one
%   name in NAMES that begins with 'group:', as it does in the corpus
%   and in the builders' Dims.
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
    wanted = instanceAlias(names, wanted);

    nd = max(numel(names), 1);
    sz = size(array);
    if numel(sz) > numel(names)
        if any(sz(numel(names) + 1:end) ~= 1)
            hint = '';
            if numel(sz) == 2 && any(sz == 1)
                % MATLAB has no one-dimensional array, so a plain
                % vector is 1-by-N or N-by-1 and always has two axes.
                % Naming one of them can never be right, and this is
                % the commonest way to arrive here.
                hint = [' A MATLAB vector is 1-by-N or N-by-1, so a ' ...
                        'plain vector has two axes and needs two ' ...
                        'names; the singleton is usually the ' ...
                        'component axis, as in {''component'', ' ...
                        '''node''}.'];
            end
            error('mestra:dims', ...
                  ['the array has %d axes and %d names; name every ' ...
                   'axis.%s'], numel(sz), numel(names), hint);
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

function wanted = instanceAlias(names, wanted)
%instanceAlias  'instance' in WANTED stands for the group axis.
    at = find(strcmp(wanted, 'instance'));
    if isempty(at), return, end
    groups = names(strncmp(names, 'group:', 6));
    if numel(groups) ~= 1
        error('mestra:dims', ...
              ['an axis called "instance" means the group axis, and ' ...
               'this array has %d axes named "group:<key>"; name the ' ...
               'axis as the array does'], numel(groups));
    end
    wanted(at) = groups(1);
end
