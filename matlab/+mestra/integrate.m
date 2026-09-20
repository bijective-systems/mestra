function out = integrate(dataset, slot, varargin)
%MESTRA.INTEGRATE  Integrate a field over its support, row by row.
%
%   OUT = MESTRA.INTEGRATE(DATASET, SLOT) sums the values of the slot
%   named SLOT against the weight array at that slot's location on
%   that slot's support, giving one number per row and per component.
%
%   When the file carries no weight array at that location, one is
%   computed on the fly from the connectivity and the call says so,
%   because specification section 3 makes connectivity the only
%   legitimate source of a weight.  Nothing is stored:
%   MESTRA.COMPUTEWEIGHTS is what puts a weight array in a file.
%
%   OUT is a struct with
%
%       values     (component-by-row), the MATLAB axis order
%       dims       names those axes
%       units      the slot's units times the weight's
%       weight     the name of the weight array used, or
%                  '(computed)' when one was made for this call
%
%   Example
%
%       d = mestra.read('family.mes');
%       lift = mestra.integrate(d, 'pressure');
%       lift.values(1, 2)      % row 2
%       lift.units             % 'Pa m2'
%
%   Name-value pairs
%
%       'Weight'  the name of the weight array to use, when the
%                 support carries more than one or the one to use is
%                 not called `weight`
%       'Quiet'   true to leave out the message about a weight
%                 computed on the fly
%
%   See also mestra.computeWeights, mestra.fieldStatistics.

    p = inputParser();
    p.addParameter('Weight', '');
    p.addParameter('Quiet', false);
    p.parse(varargin{:});
    r = p.Results;

    mestra.internal.Post.dataset(dataset, 'integrate');
    found = mestra.internal.Post.findSlot(dataset, slot, 'integrate');
    if strcmp(found.kind, 'scalar')
        error('mestra:integrate', ...
              ['"%s" is a scalar, which has no support to integrate ' ...
               'over; integrate a node array or a cell array'], found.slot.name);
    end
    field = found.slot;
    support = found.support;
    location = field.location;

    [weight, weightName] = findWeight(dataset, support, location, ...
                                      r.Weight, r.Quiet);

    nRows = max(dataset.nRows, 1);
    if strcmp(field.varies, 'none') && dataset.nRows == 0
        nRows = 1;
    end
    components = max(double(field.components), 1);
    values = zeros(components, nRows);
    for i = 1:nRows
        f = mestra.internal.Post.perRow(field, dataset, i);
        w = reshape(mestra.internal.Post.perRow(weight, dataset, i), 1, []);
        f = reshape(f, components, []);
        if size(f, 2) ~= numel(w)
            error('mestra:E05', ...
                  ['E05: %s: the field has %d %ss and the weight has ' ...
                   '%d; they are not on the same support'], ...
                  found.path, size(f, 2), location, numel(w));
        end
        values(:, i) = f * w(:);
    end

    out = struct();
    out.values = values;
    out.dims = {'component', 'row'};
    out.units = mestra.internal.Post.times(field.units, weight.units);
    out.weight = weightName;
    out.slot = found.path;
end

function [weight, name] = findWeight(d, support, location, wanted, quiet)
%findWeight  The weight array to use, or one made for this call.
    i = find(strcmp({d.supports.name}, support), 1);
    s = d.supports(i);
    if strcmp(location, 'cell')
        slots = s.cellArrays;
    else
        slots = s.nodeArrays;
    end
    if ~isempty(wanted)
        j = find(strcmp({slots.name}, wanted), 1);
        if isempty(j)
            error('mestra:integrate', ...
                  ['there is no array called "%s" on the %ss of "%s"; ' ...
                   'it has %s. mestra.computeWeights puts a weight ' ...
                   'array in a file'], wanted, location, support, ...
                  mestra.internal.Post.listOf({slots.name}));
        end
        weight = slots(j);
        name = weight.name;
        return
    end
    if ~isempty(slots)
        j = find(strcmp({slots.role}, 'weight'), 1);
        if ~isempty(j)
            weight = slots(j);
            name = weight.name;
            return
        end
    end

    % No weight in the file.  Compute one, say so, and store nothing:
    % the file is the caller's to change, and mestra.computeWeights is
    % how they change it.
    if ~quiet
        warning('mestra:weightComputed', ...
                ['%s carries no weight array on its %ss, so one was ' ...
                 'computed from the connectivity for this call and not ' ...
                 'stored. mestra.computeWeights(d, ''%s'', ''%s'') ' ...
                 'stores one.'], support, location, support, location);
    end
    scratch = mestra.Dataset();
    bare = s;
    bare.nodeArrays = mestra.Dataset.emptySlot();
    bare.cellArrays = mestra.Dataset.emptySlot();
    scratch.supports = bare;
    scratch.keys = d.keys;
    scratch.categories = d.categories;
    scratch.nRows = d.nRows;
    weight = mestra.computeWeights(scratch, support, location);
    name = '(computed)';
end
