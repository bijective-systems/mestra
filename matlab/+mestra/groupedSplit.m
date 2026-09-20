function out = groupedSplit(dataset, fractions, varargin)
%MESTRA.GROUPEDSPLIT  Split the rows by whole units of
%   generalisation.
%
%   S = MESTRA.GROUPEDSPLIT(DATASET, FRACTIONS) assigns every unit of
%   generalisation, whole, to one named part, and returns a struct
%   whose fields are the part names and whose values are row indices.
%   No unit is ever on two sides, which is the whole point of the
%   call: a model trained on one part and scored on another has then
%   been scored on geometry it never saw.
%
%   FRACTIONS is a struct of part names to fractions,
%
%       s = mestra.groupedSplit(d, struct('train', 0.8, 'test', 0.2));
%       s.train                % row indices, counted from 1
%       s.test
%
%   or a containers.Map, or a cell array of name-value pairs in the
%   order the parts should be filled.
%
%   Row indices are counted from 1, as MATLAB counts, so that they
%   index d.keysTable and an array straight away.  A validator
%   finding counts the file's rows from 0; these are not that.
%
%   NO EMPTY PART.  When there are at least as many units as parts,
%   every named part gets at least one unit, whatever the fractions
%   say.  A split whose test part is empty is not a generalisation
%   test, and returning one silently is the failure this rule exists
%   to prevent (docs/api-conventions.md, section 4).  When there are
%   fewer units than parts, the call refuses and says how many units
%   there are.
%
%   THE UNIT OF GENERALISATION.  It must be declared: the call
%   refuses a file with no generalisation group, because without one
%   there is nothing to keep whole and the split would be an
%   ordinary shuffle wearing this call's name.
%
%   Name-value pairs
%
%       'Seed'   the seed, 0 by default.  The same seed and the same
%                units always give the same split.  The shuffle is
%                this package's own, so that it does not disturb
%                MATLAB's global random state and does not change
%                with the MATLAB release.
%
%   See also mestra.fieldStatistics, mestra.Dataset.

    p = inputParser();
    p.addParameter('Seed', 0);
    p.parse(varargin{:});
    seed = double(p.Results.Seed);

    mestra.internal.Post.dataset(dataset, 'groupedSplit');
    group = dataset.generalisationGroup;
    if isempty(group)
        error('mestra:groupedSplit', ...
              ['this file declares no unit of generalisation, so there ' ...
               'is nothing to keep whole; set one with ' ...
               'setGeneralisationGroup, or use an ordinary shuffle if ' ...
               'an ordinary shuffle is what you want']);
    end
    k = dataset.key(group);
    if isempty(k) || isempty(k.values)
        error('mestra:groupedSplit', ...
              ['the file names "%s" as its unit of generalisation and ' ...
               'carries no such column'], group);
    end

    [names, wanted] = parseFractions(fractions);
    if any(wanted < 0)
        error('mestra:groupedSplit', ...
              'a fraction cannot be negative');
    end
    total = sum(wanted);
    if total <= 0
        error('mestra:groupedSplit', 'the fractions must add to more than 0');
    end
    wanted = wanted / total;

    ids = double(reshape(k.values, 1, []));
    units = unique(ids);
    nUnits = numel(units);
    nParts = numel(names);
    if nUnits < nParts
        error('mestra:groupedSplit', ...
              ['"%s" has %d unit(s) of generalisation and the split ' ...
               'names %d part(s); a part would be empty, which is not ' ...
               'a generalisation test'], group, nUnits, nParts);
    end

    counts = shareOut(wanted, nUnits);
    order = shuffle(nUnits, seed);
    units = units(order);

    out = struct();
    at = 1;
    for i = 1:nParts
        take = units(at:at + counts(i) - 1);
        at = at + counts(i);
        rows = find(ismember(ids, take));
        out.(matlab.lang.makeValidName(names{i})) = reshape(rows, 1, []);
    end
end

function counts = shareOut(wanted, nUnits)
%shareOut  Whole units to parts by largest remainder, then one unit
%   to every part that would otherwise be empty.
    exact = wanted(:)' * nUnits;
    counts = floor(exact);
    left = nUnits - sum(counts);
    [~, order] = sort(exact - counts, 'descend');
    for i = 1:left
        j = order(mod(i - 1, numel(order)) + 1);
        counts(j) = counts(j) + 1;
    end
    % Every named part gets at least one unit; the units come from the
    % largest parts, which can spare them.
    while any(counts == 0)
        empty = find(counts == 0, 1);
        [~, biggest] = max(counts);
        counts(biggest) = counts(biggest) - 1;
        counts(empty) = counts(empty) + 1;
    end
end

function order = shuffle(n, seed)
%shuffle  A Fisher-Yates shuffle on this package's own generator, so
%   that a split does not depend on MATLAB's global random state and
%   does not change with the MATLAB release.
%
%   The generator is Lehmer's, state <- state * 16807 mod 2^31 - 1,
%   the one MINSTD fixes.  Every product it forms is below 2^53 and
%   is therefore exact in a double, so the arithmetic is the same
%   everywhere and needs no 64-bit tricks.  Consecutive seeds start
%   close together in that sequence, so the first ten draws are
%   thrown away.
    order = 1:n;
    m = 2147483647;
    state = mod(floor(abs(double(seed))), m - 1) + 1;
    for k = 1:10
        state = mod(state * 16807, m);
    end
    for i = n:-1:2
        state = mod(state * 16807, m);
        j = floor((state / m) * i) + 1;
        if j > i, j = i; end
        tmp = order(i);
        order(i) = order(j);
        order(j) = tmp;
    end
end

function [names, values] = parseFractions(fractions)
%parseFractions  A struct, a containers.Map or name-value pairs.
    if isa(fractions, 'containers.Map')
        names = fractions.keys();
        values = cell2mat(fractions.values());
    elseif isstruct(fractions) && isscalar(fractions)
        names = fieldnames(fractions)';
        values = cellfun(@(f) double(fractions.(f)), names);
    elseif iscell(fractions)
        if mod(numel(fractions), 2) ~= 0
            error('mestra:groupedSplit', ...
                  ['the fractions are name-value pairs and %d ' ...
                   'argument(s) came in'], numel(fractions));
        end
        names = fractions(1:2:end);
        values = cellfun(@double, fractions(2:2:end));
    else
        error('mestra:groupedSplit', ...
              ['the fractions are a struct of part names to fractions, ' ...
               'a containers.Map, or a cell array of name-value pairs; ' ...
               'a %s came in'], class(fractions));
    end
    names = cellfun(@char, names, 'UniformOutput', false);
    names = reshape(names, 1, []);
    values = reshape(double(values), 1, []);
    if isempty(names)
        error('mestra:groupedSplit', 'the split names no parts');
    end
end
