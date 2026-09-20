function out = groupedSplit(dataset, fractions, varargin)
%MESTRA.GROUPEDSPLIT  Split the rows by whole units of
%   generalisation, by the algorithm of specification section 31.
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
%   or a containers.Map, or a cell array of name-value pairs.  The
%   fractions are normalised by their sum, so 8 and 2 mean what 0.8
%   and 0.2 mean; a negative fraction, or a set that sums to zero or
%   less, is refused.
%
%   Row indices are counted from 1, as MATLAB counts, so that they
%   index d.keysTable and an array straight away.  A validator
%   finding counts the file's rows from 0; these are not that.
%
%   ONE SEED, ONE SPLIT, IN EVERY LANGUAGE.  Section 31 fixes the
%   algorithm down to the generator, because four implementations
%   each chose their own and no two agreed on a split.  This is that
%   algorithm and nothing else:
%
%     * the units are the distinct category ids the unit-of-
%       generalisation key holds, put in order by the entries those
%       ids name in its category table, compared as UTF-8 bytes.
%       Table order is not the order, so two files that hold the same
%       units in tables written in two orders split the same way;
%     * one 64-bit draw per unit comes from splitmix64 seeded with
%       'Seed', in that order, and the units are sorted by the draw
%       as unsigned integers, ties broken by the unit name;
%     * the parts are taken in order of their names as UTF-8 bytes,
%       which is the order they are filled in and the order of the
%       result, whatever order FRACTIONS names them in;
%     * a part's size is the floor of its share, the units left over
%       go one each to the largest remainders, ties by part name, and
%       then any empty part takes one unit from the largest;
%     * the sorted units are dealt out as consecutive blocks in part
%       name order, and a part's rows are the rows of its units, in
%       ascending row order.
%
%   MATLAB's uint64 arithmetic saturates instead of wrapping, so the
%   generator is done in 32-bit halves here.  The five draws of the
%   worked example in section 31 are reproduced in PostTest.
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
%       'Seed'   the generator's starting state, 0 by default: a
%                non-negative integer below 2^64.  The same seed and
%                the same units always give the same split, in every
%                language, and MATLAB's global random state neither
%                moves it nor is moved by it.
%
%   See also mestra.fieldStatistics, mestra.Dataset.

    p = inputParser();
    p.addParameter('Seed', 0);
    p.parse(varargin{:});
    seed = seedState(p.Results.Seed);

    mestra.internal.Post.dataset(dataset, 'groupedSplit');
    group = dataset.generalisationGroup;
    if isempty(group)
        error('mestra:groupedSplit', ...
              ['this file declares no unit of generalisation, so there ' ...
               'is nothing to keep whole; set one with ' ...
               'setGeneralisationGroup, or use an ordinary shuffle if ' ...
               'an ordinary shuffle is what you want']);
    end
    k = [];
    i = find(strcmp({dataset.keys.name}, group), 1);
    if ~isempty(i), k = dataset.keys(i); end
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
    order = orderByBytes(names);
    names = names(order);
    wanted = wanted(order) / total;

    ids = double(reshape(k.values, 1, []));
    units = unique(ids);
    labels = unitLabels(dataset, k, units);
    order = orderByBytes(labels);
    units = units(order);
    labels = labels(order);

    nUnits = numel(units);
    nParts = numel(names);
    if nUnits < nParts
        error('mestra:groupedSplit', ...
              ['"%s" has %d unit(s) of generalisation and the split ' ...
               'names %d part(s); a part would be empty, which is not ' ...
               'a generalisation test'], group, nUnits, nParts);
    end

    % One draw per unit, in unit order, then sorted by the draw.  The
    % sort is stable and the units arrive in name order, so two equal
    % draws stay in name order, which is section 31's tie-break.
    draws = splitmix64(seed, nUnits);
    [~, order] = sort(draws);
    units = units(order);

    counts = shareOut(wanted, nUnits);

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
%   to every part that would otherwise be empty.  The parts arrive in
%   name order and every sort here is stable, and min and max return
%   the first of equals, so every tie is broken by part name.
    exact = wanted(:)' * nUnits;
    counts = floor(exact);
    left = round(nUnits - sum(counts));
    [~, order] = sort(exact - counts, 'descend');
    counts(order(1:left)) = counts(order(1:left)) + 1;
    % Every named part gets at least one unit; the units come from the
    % largest part, which can spare one.
    while any(counts == 0)
        [~, poor] = min(counts);
        [~, rich] = max(counts);
        counts(rich) = counts(rich) - 1;
        counts(poor) = counts(poor) + 1;
    end
end

function draws = splitmix64(state, n)
%splitmix64  The generator of section 31, in 32-bit halves because
%   MATLAB's uint64 addition and multiplication saturate at the top
%   of the range instead of wrapping round it.  Every shift here is
%   to the right, so nothing is ever shifted off the top either.
    a = u64('9E3779B9', '7F4A7C15');
    b = u64('BF58476D', '1CE4E5B9');
    c = u64('94D049BB', '133111EB');
    draws = zeros(1, n, 'uint64');
    for i = 1:n
        state = add64(state, a);
        z = state;
        z = mul64(bitxor(z, bitshift(z, -30)), b);
        z = mul64(bitxor(z, bitshift(z, -27)), c);
        draws(i) = bitxor(z, bitshift(z, -31));
    end
end

function v = u64(hi, lo)
%u64  One 64-bit constant from its two hexadecimal halves.
    v = uint64(hex2dec(hi)) * uint64(4294967296) + uint64(hex2dec(lo));
end

function z = add64(a, b)
%add64  a + b modulo 2^64.
    m = uint64(4294967295);
    low = bitand(a, m) + bitand(b, m);
    high = bitshift(a, -32) + bitshift(b, -32) + bitshift(low, -32);
    z = bitand(high, m) * uint64(4294967296) + bitand(low, m);
end

function z = mul64(a, b)
%mul64  a * b modulo 2^64.  Each partial product is below 2^64, so
%   none of them saturates.
    m = uint64(4294967295);
    al = bitand(a, m);
    ah = bitshift(a, -32);
    bl = bitand(b, m);
    bh = bitshift(b, -32);
    cross = bitand(bitand(ah * bl, m) + bitand(al * bh, m), m);
    z = add64(al * bl, cross * uint64(4294967296));
end

function s = seedState(seed)
%seedState  The generator's starting state, as an unsigned 64-bit
%   integer.  The seed itself is never a draw (section 31).
    if ~isnumeric(seed) || ~isscalar(seed) || ~isreal(seed) || ...
            seed < 0 || seed ~= floor(seed)
        error('mestra:groupedSplit', ...
              ['the seed is a non-negative integer below 2^64 and the ' ...
               'generator starts from it']);
    end
    s = uint64(seed);
end

function labels = unitLabels(dataset, key, units)
%unitLabels  The category entry each unit id names.  Section 31 puts
%   the units in the order of those entries and not of the ids, so a
%   file whose table was written in another order splits the same
%   way.  A file that names no table for its group key is not
%   conforming (E10); its ids stand in for the entries.
    entries = {};
    if ~isempty(key.category)
        j = find(strcmp({dataset.categories.name}, key.category), 1);
        if ~isempty(j), entries = dataset.categories(j).entries; end
    end
    labels = cell(1, numel(units));
    for i = 1:numel(units)
        at = units(i) + 1;
        if at >= 1 && at <= numel(entries)
            labels{i} = entries{at};
        else
            labels{i} = sprintf('%d', units(i));
        end
    end
end

function order = orderByBytes(names)
%orderByBytes  The permutation that sorts names by their UTF-8 bytes,
%   which is the one ordering every language produces identically.
    n = numel(names);
    keys = cell(1, n);
    for i = 1:n
        keys{i} = double(unicode2native(names{i}, 'UTF-8'));
    end
    order = 1:n;
    for i = 2:n
        j = i;
        while j > 1 && mestra.internal.H5.byteLess(keys{order(j)}, ...
                                                   keys{order(j - 1)})
            t = order(j);
            order(j) = order(j - 1);
            order(j - 1) = t;
            j = j - 1;
        end
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
