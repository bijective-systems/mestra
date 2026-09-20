function out = computeWeights(dataset, support, location, varargin)
%MESTRA.COMPUTEWEIGHTS  Integration weights from the connectivity.
%
%   MESTRA.COMPUTEWEIGHTS(DATASET, SUPPORT, LOCATION) computes the
%   weight array for a support and stores it on the dataset.  SUPPORT
%   is the support's name and LOCATION is 'cell' or 'node'.
%
%   Specification section 3 says a weight array is "computed from
%   connectivity, never imported", so this is the only legitimate way
%   one gets into a file.  The measure is the cell's own:
%
%       line          its length
%       triangle      the area of the triangle
%       quadrilateral the area of the quadrilateral, by Newell
%       polygon       the area of the polygon, by Newell
%       tetrahedron   its volume
%       hexahedron    its volume, as six tetrahedra
%       wedge         its volume, as three tetrahedra
%       pyramid       its volume, as two tetrahedra
%       vertex        zero
%
%   A quadratic cell, code 21 to 27, has curved edges and is refused
%   by name rather than measured by its corner nodes.  On an `axis`
%   support, which has no cells, a node weight is the trapezoidal
%   share of the segments either side of it.
%
%   A node weight is the lumped share of the adjacent cell measure:
%   every cell gives each of its nodes an equal part of its own
%   measure, and a node's weight is the sum of the parts it is given.
%   Summing a field against these weights is therefore the same
%   number at both locations for a field that is constant on a cell.
%
%   The array is stored with role `weight`, with `recomputed` set
%   (W06), with the units of the coordinates raised to the support's
%   dimension, and under the name `weight` unless 'Name' says
%   otherwise.  It varies along whatever the coordinates vary along,
%   because that is what the measure depends on.
%
%       d = mestra.read('family.mes');
%       mestra.computeWeights(d, 's0', 'cell');
%       mestra.write(d, 'with_weights.mes');
%
%   W = MESTRA.COMPUTEWEIGHTS(...) also returns the slot it stored.
%
%   Name-value pairs
%
%       'Name'    what to call the array; `weight` by default, at
%                 both locations
%       'Units'   the units to record, when the coordinates' units
%                 cannot be raised by this package
%
%   See also mestra.integrate, mestra.Dataset.

    p = inputParser();
    p.addParameter('Name', 'weight');
    p.addParameter('Units', '');
    p.parse(varargin{:});
    r = p.Results;

    if ~isa(dataset, 'mestra.Dataset')
        error('mestra:computeWeights', ...
              'the first argument must be a mestra.Dataset');
    end
    location = char(location);
    if ~any(strcmp(location, {'node', 'cell'}))
        error('mestra:computeWeights', ...
              ['the location must be ''node'' or ''cell'' and "%s" is ' ...
               'neither'], location);
    end
    i = find(strcmp({dataset.supports.name}, support), 1);
    if isempty(i)
        error('mestra:computeWeights', ...
              'there is no support called "%s" in this file; it has %s', ...
              support, mestra.internal.Post.listOf(dataset.supportNames()));
    end
    s = dataset.supports(i);
    if isempty(s.coordinates) || isempty(s.coordinates.values)
        error('mestra:computeWeights', ...
              ['the support "%s" has no coordinates to measure; a ' ...
               'weight is computed from connectivity and coordinates ' ...
               'and cannot be made without them'], support);
    end

    coords = s.coordinates;
    [pts, instanceAxis] = mestra.internal.Post.instances(coords);
    nInstances = numel(pts);

    if s.nCells > 0
        dim = cellDimension(s);
        values = zeros(numelOf(location, s), nInstances);
        for k = 1:nInstances
            values(:, k) = meshWeights(s, pts{k}, location);
        end
    elseif strcmp(s.kind, 'axis')
        if strcmp(location, 'cell')
            error('mestra:computeWeights', ...
                  ['the support "%s" is an axis support and has no ' ...
                   'cells, so there are no cell weights; ask for ''node'''], ...
                  support);
        end
        dim = 1;
        values = zeros(s.nNodes, nInstances);
        for k = 1:nInstances
            values(:, k) = axisWeights(pts{k});
        end
    else
        error('mestra:computeWeights', ...
              ['the support "%s" is of kind %s and carries neither ' ...
               'cells nor an axis coordinate, so it has no measure'], ...
              support, s.kind);
    end

    units = r.Units;
    if isempty(units)
        units = mestra.internal.Post.raise(coords.units, dim);
    end

    dims = {'component', location};
    shaped = reshape(values, [1 size(values, 1) nInstances]);
    if strcmp(coords.varies, 'none')
        shaped = shaped(:, :, 1);
    else
        dims{end + 1} = coords.varies;
    end

    args = {'Units', units, 'Varies', coords.varies, ...
            'Recomputed', true, 'Components', 1};
    if strcmp(location, 'cell')
        dataset.addCellArray(support, r.Name, shaped, 'weight', ...
                             args{:}, 'Dims', dims);
        out = dataset.cellArray(support, r.Name);
    else
        dataset.addNodeArray(support, r.Name, shaped, 'weight', ...
                             args{:}, 'Dims', dims);
        out = dataset.nodeArray(support, r.Name);
    end
    if nargout == 0
        clear out
    end
    if instanceAxis == 0 && ~strcmp(coords.varies, 'none')
        % Cannot happen for a slot this package built, and says so
        % rather than storing something nobody can interpret.
        error('mestra:computeWeights', ...
              ['the coordinates of "%s" say they vary along %s and ' ...
               'carry no such axis'], support, coords.varies);
    end
end

function n = numelOf(location, s)
    if strcmp(location, 'cell')
        n = s.nCells;
    else
        n = s.nNodes;
    end
end

function dim = cellDimension(s)
%cellDimension  The topological dimension of a support's cells, which
%   is what the coordinates' units are raised by.  A support whose
%   cells are of more than one dimension has no single measure and is
%   refused.
    dims = arrayfun(@(c) mestra.internal.Measure.dimensionOf(c), ...
                    double(s.cellTypes));
    dims = unique(dims(dims > 0));
    if isempty(dims)
        dim = 0;
    elseif numel(dims) == 1
        dim = dims;
    else
        error('mestra:computeWeights', ...
              ['the support "%s" mixes cells of %s dimensions, so its ' ...
               'measure has no single unit; pass ''Units'' to say what ' ...
               'to record'], s.name, mat2str(dims));
    end
end

function w = meshWeights(s, pts, location)
%meshWeights  The measure of every cell, or its lumped share at every
%   node.
    offsets = double(s.cellOffsets);
    conn = double(s.cellConnectivity) + 1;      % the file counts from 0
    types = double(s.cellTypes);
    if strcmp(location, 'cell')
        w = zeros(s.nCells, 1);
    else
        w = zeros(s.nNodes, 1);
    end
    for j = 1:s.nCells
        nodes = conn(offsets(j) + 1:offsets(j + 1));
        m = mestra.internal.Measure.cell(types(j), pts(:, nodes));
        if strcmp(location, 'cell')
            w(j) = m;
        else
            w(nodes) = w(nodes) + m / numel(nodes);
        end
    end
end

function w = axisWeights(pts)
%axisWeights  The trapezoidal share of the segments either side of a
%   node, which is the lumped rule on a support with no cells.
    x = reshape(double(pts(1, :)), [], 1);
    n = numel(x);
    w = zeros(n, 1);
    if n < 2, return, end
    seg = abs(diff(x));
    w(1:n - 1) = w(1:n - 1) + seg / 2;
    w(2:n) = w(2:n) + seg / 2;
end
