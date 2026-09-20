function out = validate(path)
%MESTRA.VALIDATE  Check a file against the rules of section 14.
%
%   OUT = MESTRA.VALIDATE(PATH) returns a struct with
%
%       errors     a sorted cell array of the error identifiers the
%                  file produces, with no duplicates
%       warnings   the same for the warnings
%       findings   a struct array with one entry per finding: the rule
%                  id, the HDF5 path it was found at, and one line of
%                  plain language
%       valid      true when `errors` is empty
%
%   The identifiers are exactly those of specification section 14.  A
%   retired identifier is never emitted: E07 and W09 were retired on
%   2026-09-20 and nothing here produces them.
%
%   A file whose `format` names another major version produces E01 and
%   nothing else: section 28 says a reader must refuse it outright and
%   must not try to read it partially.
%
%   W10 uses a small units parser (mestra.internal.Units) that checks
%   the UDUNITS grammar and not the names, because shipping a unit
%   database is not what the rule asks for.
%
%   A file is untrusted input, so the pass is per object: an object
%   that will not open or will not read stops that object and nothing
%   else, and leaves an unclassified finding with its path.  Those
%   findings are in OUT.UNCLASSIFIED and never in OUT.ERRORS or
%   OUT.WARNINGS, so they cannot be mistaken for a rule of section 14.
%   Their identifiers are
%
%       U01   an object this reader could not read
%       U02   a link this reader does not follow: soft, external or
%             dangling.  Section 13 gives the format no links, and an
%             external link names another file, which is never opened
%       U03   a limit of this reader was reached; see mestra.limits
%
%   A file that is not HDF5 at all, or that is truncated, raises
%   mestra:reader rather than a library error.
%
%   Example
%
%       r = mestra.validate('case.mes');
%       if ~r.valid
%           for f = r.findings
%               fprintf('%s %s %s\n', f.id, f.path, f.message);
%           end
%       end
%
%   See also mestra.read, mestra.write, mestra.Dataset.

    rep = mestra.internal.Report();
    fid = mestra.internal.Reader.openFile(path);
    closeFile = onCleanup(@() H5F.close(fid)); %#ok<NASGU>
    root = H5G.open(fid, '/');
    closeRoot = onCleanup(@() H5G.close(root)); %#ok<NASGU>

    ctx = struct();
    ctx.rep = rep;
    ctx.fid = fid;
    ctx.root = root;

    if ~checkFormat(ctx)
        out = rep.result();
        return
    end
    ctx = guard(ctx, '/', @() gather(ctx), ctx);
    % Each pass is separate, so that one that cannot finish leaves the
    % others to run.  That is what makes a finding late in a file
    % reachable when something early in it will not read.
    guard(ctx, '/', @() checkRoot(ctx));
    guard(ctx, '/categories', @() checkCategories(ctx));
    guard(ctx, '/keys', @() checkKeys(ctx));
    guard(ctx, '/scalars', @() checkScalars(ctx));
    guard(ctx, '/row_support', @() checkRowSupport(ctx));
    guard(ctx, '/supports', @() checkSupports(ctx));
    guard(ctx, '/callables', @() checkCallables(ctx));
    guard(ctx, '/', @() checkUnknown(ctx));
    guard(ctx, '/private', @() checkPrivate(ctx));
    out = rep.result();
end

% ============================================== per-object recovery

function out = guard(ctx, path, fn, fallback)
%guard  Run one check; a failure is a finding and not the end.
%   A limit of this reader is U03, anything else is U01.  Both carry
%   the path, so a caller knows which object was passed over.
    if nargin < 4, fallback = []; end
    try
        if nargout > 0
            out = fn();
        else
            fn();
            out = [];
        end
    catch err
        out = fallback;
        if strcmp(err.identifier, 'mestra:reader') && ...
           ~isempty(strfind(err.message, 'this reader')) %#ok<STREMP>
            id = 'U03';
        else
            id = 'U01';
        end
        ctx.rep.add(id, path, '%s', ...
                    regexprep(strtrim(err.message), '\s+', ' '));
    end
end

function tf = followable(ctx, gid, name, path)
%followable  True for a hard link; anything else is U02 and skipped.
    kind = mestra.internal.H5.childType(gid, name);
    tf = any(strcmp(kind, {'group', 'dataset', 'other'}));
    if ~tf
        switch kind
            case 'soft'
                why = ['a soft link, which this format does not define ' ...
                       'and this reader does not follow'];
            case 'external'
                why = ['an external link, which names another file; ' ...
                       'this reader never opens one'];
            otherwise
                why = 'an object that would not open';
        end
        ctx.rep.add('U02', path, '%s', why);
    end
end

% ===================================================== the vocabulary

function m = attrKinds()
%attrKinds  The encoding section 18 requires of each named attribute.
    m = containers.Map( ...
        {'format', 'writer', 'created', 'generalisation_group', 'role', ...
         'units', 'category', 'trajectory_group', 'parent', 'kind', ...
         'support_id', 'varies', 'source', 'output', 'statistic', 'of', ...
         'derived_from', 'recipe', 'reference', 'type', 'repr', ...
         'aligned', 'recomputed', 'n_nodes', 'n_cells', 'components', ...
         'lower', 'upper', 'quantile'}, ...
        {'string', 'string', 'string', 'string', 'string', ...
         'string', 'string', 'string', 'string', 'string', ...
         'string', 'string', 'string', 'string', 'string', 'string', ...
         'string', 'string', 'string', 'string', 'string', ...
         'int8', 'int8', 'int64', 'int64', 'int64', ...
         'float64', 'float64', 'float64'});
end

function names = keyRoles()
    names = {'design', 'condition', 'time', 'categorical', 'group', ...
             'split', 'id', 'status'};
end

function names = arrayRoles()
    names = {'coordinates', 'field', 'label', 'weight', 'normal', 'derived'};
end

function t = cellTypeTable()
%cellTypeTable  The codes of section 20 and the nodes each takes.
    t = containers.Map({1, 3, 5, 7, 9, 10, 12, 13, 14, 21, 22, 23, 24, ...
                        25, 26, 27}, ...
                       {1, 2, 3, -1, 4, 4, 8, 6, 5, 3, 6, 8, 10, 20, 15, 13});
end

% ===================================================== opening checks

function ok = checkFormat(ctx)
    H5 = mestra.internal.H5;
    ok = false;
    if ~H5.hasAttr(ctx.root, 'format')
        ctx.rep.add('E01', '/', 'the root has no format attribute');
        ctx.rep.add('E17', '/', 'format is missing');
        return
    end
    [value, ok] = H5.scalarAttr(ctx.root, 'format');
    if ~ok || ~ischar(value), value = ''; end
    major = mestra.internal.Reader.majorVersion(value);
    if isnan(major) || major ~= 0
        ctx.rep.add('E01', '/', ...
            'format is "%s"; this reader accepts "mestra/0" only', value);
        return
    end
    ok = true;
end

function ctx = gather(ctx)
%gather  Read once what every check needs.
    H5 = mestra.internal.H5;
    ctx.aligned = [];
    v = mestra.internal.Reader.num(ctx.root, 'aligned');
    if ~isempty(v), ctx.aligned = v; end
    ctx.generalisationGroup = ...
        mestra.internal.Reader.str(ctx.root, 'generalisation_group');

    ctx.rowCount = 0;
    ctx.rowUnlimited = true;
    if mestra.internal.Reader.hasKind(ctx.fid, 'row', 'dataset')
        did = H5D.open(ctx.fid, 'row');
        info = H5.dsetInfo(did);
        H5D.close(did);
        if ~isempty(info.dims), ctx.rowCount = info.dims(1); end
        ctx.rowUnlimited = ~isempty(info.maxdims) && info.maxdims(1) < 0;
    end

    ctx.categories = containers.Map('KeyType', 'char', 'ValueType', 'any');
    ctx.categoryNames = {};
    if mestra.internal.Reader.hasGroup(ctx.fid, 'categories')
        g = H5.openGroup(ctx.fid, 'categories');
        for name = H5.children(g)
            ctx.categoryNames{end + 1} = name{1};
            ctx.categories(name{1}) = {};
            if ~strcmp(H5.childType(g, name{1}), 'dataset'), continue, end
            did = H5D.open(g, name{1});
            try
                info = H5.dsetInfo(did);
                if strcmp(info.type, 'string')
                    ctx.categories(name{1}) = H5.readData(did, info);
                end
            catch
                % The table cannot be read; checkCategories says so and
                % every value checked against it is simply not checked.
            end
            H5D.close(did);
        end
        H5G.close(g);
    end

    ctx.keys = struct('name', {}, 'role', {}, 'values', {}, 'type', {}, ...
                      'category', {}, 'trajectoryGroup', {});
    if mestra.internal.Reader.hasGroup(ctx.fid, 'keys')
        g = H5.openGroup(ctx.fid, 'keys');
        for name = H5.children(g)
            rec.name = name{1};
            rec.role = '';
            rec.values = [];
            rec.type = '';
            rec.category = '';
            rec.trajectoryGroup = '';
            if strcmp(H5.childType(g, name{1}), 'dataset')
                did = H5D.open(g, name{1});
                try
                    info = H5.dsetInfo(did);
                    rec.type = info.type;
                    try
                        rec.values = reshape(H5.readData(did, info), 1, []);
                    catch
                        % The values are unreadable; checkKeys reports
                        % it and every value-based rule is skipped for
                        % this key alone.
                    end
                    rec.role = strAttr(did, 'role');
                    rec.category = strAttr(did, 'category');
                    rec.trajectoryGroup = strAttr(did, 'trajectory_group');
                catch
                end
                H5D.close(did);
            end
            ctx.keys(end + 1) = rec;
        end
        H5G.close(g);
    end

    ctx.supportNames = {};
    if mestra.internal.Reader.hasGroup(ctx.fid, 'supports')
        g = H5.openGroup(ctx.fid, 'supports');
        ctx.supportNames = H5.children(g);
        H5G.close(g);
    end

    ctx.rowSupport = [];
    ctx.hasRowSupport = H5.exists(ctx.fid, '/row_support');
    if mestra.internal.Reader.hasKind(ctx.fid, 'row_support', 'dataset')
        did = H5D.open(ctx.fid, 'row_support');
        info = H5.dsetInfo(did);
        try
            ctx.rowSupport = reshape(double(H5.readData(did, info)), 1, []);
        catch
        end
        H5D.close(did);
    end

    ctx.callableIds = {};
    if mestra.internal.Reader.hasGroup(ctx.fid, 'callables')
        g = H5.openGroup(ctx.fid, 'callables');
        ctx.callableIds = H5.children(g);
        H5G.close(g);
    end

    ctx.groupKeys = {};
    for i = 1:numel(ctx.keys)
        if strcmp(ctx.keys(i).role, 'group')
            ctx.groupKeys{end + 1} = ctx.keys(i).name;
        end
    end
end

% ========================================================= root rules

function checkRoot(ctx)
    H5 = mestra.internal.H5;
    rep = ctx.rep;
    for name = {'format', 'writer', 'created'}
        if ~H5.hasAttr(ctx.root, name{1})
            rep.add('E17', '/', '%s is missing', name{1});
        end
    end
    checkAttrEncodings(ctx, ctx.root, '/');
    if ~H5.hasAttr(ctx.root, 'aligned')
        rep.add('E39', '/', 'aligned is required on the root group');
    end
    if ~isempty(ctx.groupKeys) && ...
       ~H5.hasAttr(ctx.root, 'generalisation_group')
        rep.add('E39', '/', ...
            ['the file declares a group key, so generalisation_group ' ...
             'is required']);
    end
    if H5.hasAttr(ctx.root, 'created')
        v = mestra.internal.Reader.str(ctx.root, 'created');
        if ~isempty(v) && ~mestra.internal.Text.iso8601Utc(v)
            rep.add('W14', '/', ...
                'created "%s" is not an ISO 8601 UTC timestamp', v);
        end
    end

    n = numel(ctx.supportNames);
    if n > 1
        rep.add('W05', '/supports', ...
            ['%d supports: index-aligned operations are not ' ...
             'available'], n);
    end
    if ~isempty(ctx.aligned)
        if ctx.aligned ~= 0 && n > 1
            rep.add('E37', '/', ...
                'aligned is true and the file declares %d supports', n);
        elseif ctx.aligned == 0 && n <= 1
            rep.add('E37', '/', ...
                'aligned is false and the file declares %d support(s)', n);
        end
        if ctx.aligned ~= 0 && ctx.hasRowSupport
            rep.add('E28', '/row_support', ...
                '/row_support is present in an aligned file');
        elseif ctx.aligned == 0 && ~ctx.hasRowSupport
            rep.add('E28', '/', ...
                '/row_support is missing from an unaligned file');
        end
    end
    if ~ctx.rowUnlimited
        rep.add('E27', '/row', 'row is not an unlimited dimension');
    end
end

% =================================================== category tables

function checkCategories(ctx)
    H5 = mestra.internal.H5;
    if ~mestra.internal.Reader.hasGroup(ctx.fid, 'categories'), return, end
    g = H5.openGroup(ctx.fid, 'categories');
    closer = onCleanup(@() H5G.close(g)); %#ok<NASGU>
    for name = H5.children(g)
        path = ['/categories/' name{1}];
        checkName(ctx, name{1}, path);
        if ~followable(ctx, g, name{1}, path), continue, end
        if ~strcmp(H5.childType(g, name{1}), 'dataset')
            ctx.rep.add('E20', path, 'a category table must be a dataset');
            continue
        end
        guard(ctx, path, @() checkOneCategory(ctx, g, name{1}, path));
    end
end

function checkOneCategory(ctx, g, name, path)
    H5 = mestra.internal.H5;
    did = H5D.open(g, name);
    closer = onCleanup(@() H5D.close(did)); %#ok<NASGU>
    info = H5.dsetInfo(did);
    if ~strcmp(info.type, 'string')
        ctx.rep.add('E20', path, ...
            'a category table must be a fixed-length UTF-8 string');
    else
        checkStringDataset(ctx, did, info, path);
    end
    checkAttrEncodings(ctx, did, path);
    checkScales(ctx, did, info, path);
end

function checkStringDataset(ctx, did, info, path)
%checkStringDataset  E26 and W13 over the stored bytes.
%   A string whose bytes MATLAB will not hand over is an unclassified
%   finding and not a guess: MATLAB's HDF5 interface decodes a
%   fixed-length string to text before this package sees it, so a
%   file that is not ASCII cannot be told from one that is not valid
%   UTF-8 at all, and saying E26 either way would be a fabrication.
    H5 = mestra.internal.H5;
    try
        raw = H5.readRawStrings(did, info);
    catch err
        ctx.rep.add('U01', path, ...
            'the strings could not be read as bytes: %s', ...
            regexprep(strtrim(err.message), '\s+', ' '));
        return
    end
    longest = 0;
    for i = 1:size(raw, 2)
        [ok, why] = mestra.internal.Text.checkStringBytes(raw(:, i)');
        if ~ok
            ctx.rep.add('E26', path, 'entry %d has %s', i - 1, why);
        end
        last = find(raw(:, i) ~= 0, 1, 'last');
        if isempty(last), last = 0; end
        longest = max(longest, last);
    end
    if info.strSize > max(longest, 1)
        ctx.rep.add('W13', path, ...
            'the size is %d bytes where %d would do', ...
            info.strSize, max(longest, 1));
    end
end

% ============================================================== keys

function checkKeys(ctx)
    H5 = mestra.internal.H5;
    rep = ctx.rep;
    if ~mestra.internal.Reader.hasGroup(ctx.fid, 'keys'), return, end
    g = H5.openGroup(ctx.fid, 'keys');
    closer = onCleanup(@() H5G.close(g)); %#ok<NASGU>

    counts = containers.Map(keyRoles(), num2cell(zeros(1, numel(keyRoles()))));
    for name = H5.children(g)
        path = ['/keys/' name{1}];
        checkName(ctx, name{1}, path);
        if ~followable(ctx, g, name{1}, path), continue, end
        if ~strcmp(H5.childType(g, name{1}), 'dataset')
            rep.add('E39', path, 'a key must be a dataset');
            continue
        end
        role = guard(ctx, path, @() checkOneKey(ctx, g, name{1}, path), '');
        if ~isempty(role) && ismember(role, keyRoles())
            counts(role) = counts(role) + 1;
        end
    end

    for role = {'time', 'split', 'id', 'status'}
        if counts(role{1}) > 1
            rep.add('E03', '/keys', ...
                '%d keys have the role %s where at most one may', ...
                counts(role{1}), role{1});
        end
    end

    guard(ctx, '/keys', @() checkSplitLeak(ctx));
    guard(ctx, '/keys', @() checkTrajectories(ctx));
    guard(ctx, '/keys', @() checkStatus(ctx));
    guard(ctx, '/categories', @() checkUnusedCategories(ctx));
end

function role = checkOneKey(ctx, g, name, path)
    H5 = mestra.internal.H5;
    rep = ctx.rep;
    did = H5.openDataset(g, name);
    closer = onCleanup(@() H5D.close(did)); %#ok<NASGU>
    info = H5.dsetInfo(did);
    checkAttrEncodings(ctx, did, path);
    checkKnownAttrs(ctx, did, path, ...
        {'role', 'units', 'lower', 'upper', 'category', ...
         'trajectory_group', 'parent'});
    checkScales(ctx, did, info, path);
    checkChunking(ctx, did, info, path, ctx.rowCount);

    role = strAttr(did, 'role');
    if isempty(role) || ~ismember(role, keyRoles())
        rep.add('E02', path, 'the role is "%s"', role);
    end

    units = strAttr(did, 'units');
    if ismember(role, {'design', 'condition', 'time'})
        if ~H5.hasAttr(did, 'units')
            rep.add('E39', path, 'a %s key needs units', role);
        end
    end
    if ~isempty(units) && ~mestra.internal.Units.parses(units)
        rep.add('W10', path, 'the units "%s" do not parse', units);
    end
    if ismember(role, {'categorical', 'group', 'split', 'status'})
        if ~H5.hasAttr(did, 'category')
            rep.add('E39', path, 'a %s key needs a category table', role);
        end
    end
    if strcmp(role, 'time') && ~isempty(ctx.groupKeys) && ...
       ~H5.hasAttr(did, 'trajectory_group')
        rep.add('E39', path, ...
            'the time key needs trajectory_group when the file has groups');
    end

    checkKeyDtype(ctx, role, info.type, path);
    if ~isempty(info.dims) && info.dims(1) ~= ctx.rowCount
        rep.add('E16', path, ...
            'the key holds %d values where the file has %d rows', ...
            info.dims(1), ctx.rowCount);
    end

    values = [];
    try
        values = H5.readData(did, info);
    catch err
        rep.add('U01', path, 'the values would not read: %s', ...
                regexprep(strtrim(err.message), '\s+', ' '));
    end
    checkKeyValues(ctx, did, path, role, values);
    if strcmp(info.type, 'string')
        guard(ctx, path, @() checkStringDataset(ctx, did, info, path));
    end
end

function checkKeyDtype(ctx, role, type, path)
    switch role
        case {'design', 'condition', 'time'}
            allowed = {'float64'};
        case {'categorical', 'group', 'split', 'status'}
            allowed = {'int32', 'int64'};
        case 'id'
            allowed = {'int64', 'string'};
        otherwise
            return
    end
    if ~ismember(type, allowed)
        ctx.rep.add('E20', path, ...
            'a %s key is stored as %s where section 19 allows %s', ...
            role, type, strjoin(allowed, ' or '));
    end
end

function checkKeyValues(ctx, did, path, role, values)
    H5 = mestra.internal.H5;
    rep = ctx.rep;
    if isempty(values), return, end
    if ismember(role, {'categorical', 'group', 'split', 'status'})
        table = categoryEntries(ctx, strAttr(did, 'category'));
        if ~isempty(table) || H5.hasAttr(did, 'category')
            n = numel(table);
            bad = values(values < 0 | values >= n);
            if ~isempty(bad)
                rep.add('E10', path, ...
                    'the value %g is outside a table of %d entries', ...
                    double(bad(1)), n);
            end
        end
        return
    end
    if ~isnumeric(values), return, end
    lower = numAttr(did, 'lower');
    upper = numAttr(did, 'upper');
    outside = false;
    if ~isempty(lower) && any(double(values) < lower), outside = true; end
    if ~isempty(upper) && any(double(values) > upper), outside = true; end
    if outside
        rep.add('W04', path, 'a value is outside the declared bounds');
    elseif ~isempty(lower) && ~isempty(upper) && ~isempty(values)
        observed = max(double(values)) - min(double(values));
        declared = upper - lower;
        if declared > 4 * observed
            rep.add('W08', path, ...
                ['the declared width %g is more than four times the ' ...
                 'observed width %g'], declared, observed);
        end
    end
end

function checkSplitLeak(ctx)
    split = findKey(ctx, 'split', 'role');
    if isempty(split) || isempty(ctx.generalisationGroup), return, end
    unit = findKey(ctx, ctx.generalisationGroup, 'name');
    if isempty(unit) || isempty(unit.values) || isempty(split.values)
        return
    end
    if numel(unit.values) ~= numel(split.values), return, end
    units = unique(double(unit.values));
    for i = 1:numel(units)
        sides = unique(double(split.values(double(unit.values) == units(i))));
        if numel(sides) > 1
            ctx.rep.add('W01', ['/keys/' split.name], ...
                ['rows of one generalisation unit are on both sides of ' ...
                 'the split']);
            return
        end
    end
end

function checkTrajectories(ctx)
    t = findKey(ctx, 'time', 'role');
    if isempty(t) || isempty(t.values), return, end
    times = reshape(double(t.values), 1, []);
    groups = ones(1, numel(times));
    if ~isempty(t.trajectoryGroup)
        g = findKey(ctx, t.trajectoryGroup, 'name');
        if ~isempty(g) && numel(g.values) == numel(times)
            groups = reshape(double(g.values), 1, []);
        end
    end
    for v = unique(groups)
        seq = times(groups == v);
        if any(diff(seq) <= 0)
            ctx.rep.add('E09', ['/keys/' t.name], ...
                'time is not strictly increasing within a trajectory');
            return
        end
    end
end

function checkStatus(ctx)
    s = findKey(ctx, 'status', 'role');
    if isempty(s) || isempty(s.values), return, end
    table = categoryEntries(ctx, s.category);
    converged = find(strcmp(table, 'converged'), 1) - 1;
    if isempty(converged), converged = -1; end
    if any(double(s.values) ~= converged)
        ctx.rep.add('W02', ['/keys/' s.name], ...
            'a row has a status other than converged');
    end
end

function checkUnusedCategories(ctx)
    for i = 1:numel(ctx.groupKeys)
        k = findKey(ctx, ctx.groupKeys{i}, 'name');
        if isempty(k) || isempty(k.category), continue, end
        table = categoryEntries(ctx, k.category);
        used = unique(double(k.values));
        for c = 0:numel(table) - 1
            if ~any(used == c)
                ctx.rep.add('W07', ['/categories/' k.category], ...
                    'entry %d ("%s") is used by no row', c, table{c + 1});
            end
        end
    end
end

% =========================================================== scalars

function checkScalars(ctx)
    H5 = mestra.internal.H5;
    if ~mestra.internal.Reader.hasGroup(ctx.fid, 'scalars'), return, end
    g = H5.openGroup(ctx.fid, 'scalars');
    closer = onCleanup(@() H5G.close(g)); %#ok<NASGU>
    for name = H5.children(g)
        path = ['/scalars/' name{1}];
        checkName(ctx, name{1}, path);
        if ~followable(ctx, g, name{1}, path), continue, end
        guard(ctx, path, @() checkOneScalar(ctx, g, name{1}, path));
    end
end

function checkOneScalar(ctx, g, name, path)
    H5 = mestra.internal.H5;
    kind = H5.childType(g, name);
    if strcmp(kind, 'group')
        isGroup = true;
        oid = H5.openGroup(g, name);
    elseif strcmp(kind, 'dataset')
        isGroup = false;
        oid = H5.openDataset(g, name);
    else
        ctx.rep.add('E39', path, 'a scalar must be a dataset or a group');
        return
    end
    checkAttrEncodings(ctx, oid, path);
    checkKnownAttrs(ctx, oid, path, ...
        {'units', 'source', 'output', 'statistic', 'of', 'quantile'});
    if ~H5.hasAttr(oid, 'units')
        ctx.rep.add('E11', path, 'a scalar needs units');
    else
        units = strAttr(oid, 'units');
        if ~isempty(units) && ~mestra.internal.Units.parses(units)
            ctx.rep.add('W10', path, ...
                'the units "%s" do not parse', units);
        end
    end
    checkSource(ctx, oid, path, isGroup);
    checkStatistic(ctx, oid, path);
    if isGroup
        H5G.close(oid);
        return
    end
    info = H5.dsetInfo(oid);
    if ~strcmp(info.type, 'float64')
        ctx.rep.add('E20', path, ...
            'a scalar is stored as %s where float64 is required', ...
            info.type);
    end
    if ~isempty(info.dims) && info.dims(1) ~= ctx.rowCount
        ctx.rep.add('E16', path, ...
            'the scalar holds %d values where the file has %d rows', ...
            info.dims(1), ctx.rowCount);
    end
    checkScales(ctx, oid, info, path);
    checkChunking(ctx, oid, info, path, ctx.rowCount);
    try
        values = H5.readData(oid, info);
        if isnumeric(values) && any(~isfinite(double(values)))
            ctx.rep.add('W03', path, 'a non-finite value');
        end
    catch err
        ctx.rep.add('U01', path, 'the values would not read: %s', ...
                    regexprep(strtrim(err.message), '\s+', ' '));
    end
    H5D.close(oid);
end

% ======================================================= row_support

function checkRowSupport(ctx)
    if ~ctx.hasRowSupport, return, end
    H5 = mestra.internal.H5;
    did = H5D.open(ctx.fid, '/row_support');
    closer = onCleanup(@() H5D.close(did)); %#ok<NASGU>
    info = H5.dsetInfo(did);
    if ~strcmp(info.type, 'int32')
        ctx.rep.add('E20', '/row_support', ...
            '/row_support is stored as %s where int32 is required', ...
            info.type);
    end
    checkScales(ctx, did, info, '/row_support');
    checkChunking(ctx, did, info, '/row_support', ctx.rowCount);
    n = numel(ctx.supportNames);
    bad = ctx.rowSupport(ctx.rowSupport < 0 | ctx.rowSupport >= n);
    if ~isempty(bad)
        ctx.rep.add('E06', '/row_support', ...
            'a row references support %d where the file declares %d', ...
            bad(1), n);
    end
    for i = 1:n
        if ~any(ctx.rowSupport == i - 1)
            ctx.rep.add('W15', ['/supports/' ctx.supportNames{i}], ...
                'no row references this support');
        end
    end
end

% ========================================================== supports

function checkSupports(ctx)
    H5 = mestra.internal.H5;
    if ~mestra.internal.Reader.hasGroup(ctx.fid, 'supports'), return, end
    g = H5.openGroup(ctx.fid, 'supports');
    closer = onCleanup(@() H5G.close(g)); %#ok<NASGU>
    for i = 1:numel(ctx.supportNames)
        name = ctx.supportNames{i};
        path = ['/supports/' name];
        checkName(ctx, name, path);
        if ~followable(ctx, g, name, path), continue, end
        if ~strcmp(H5.childType(g, name), 'group')
            ctx.rep.add('E39', path, 'a support must be a group');
            continue
        end
        index = i - 1;
        guard(ctx, path, @() checkOneSupport(ctx, g, name, index));
    end
end

function checkOneSupport(ctx, parent, name, index)
    H5 = mestra.internal.H5;
    rep = ctx.rep;
    path = ['/supports/' name];
    sid = H5.openGroup(parent, name);
    closer = onCleanup(@() H5G.close(sid)); %#ok<NASGU>
    checkAttrEncodings(ctx, sid, path);
    checkKnownAttrs(ctx, sid, path, ...
        {'kind', 'n_nodes', 'n_cells', 'support_id'});
    for a = {'kind', 'n_nodes', 'n_cells', 'support_id'}
        if ~H5.hasAttr(sid, a{1})
            rep.add('E39', path, '%s is required on a support', a{1});
        end
    end
    kind = strAttr(sid, 'kind');
    nNodes = numAttr(sid, 'n_nodes');
    nCells = numAttr(sid, 'n_cells');
    if isempty(nNodes), nNodes = 0; end
    if isempty(nCells), nCells = 0; end

    has = @(n) H5.exists(sid, n);
    cellNames = {'cell_types', 'cell_offsets', 'cell_connectivity'};
    present = cellfun(has, cellNames);
    if strcmp(kind, 'mesh')
        if ~all(present)
            rep.add('E38', path, ...
                'a mesh support is missing %s', ...
                strjoin(cellNames(~present), ', '));
        end
    elseif any(present) || has('cell')
        rep.add('E38', path, ...
            'a support of kind %s carries cell data', kind);
    end

    types = []; offsets = []; conn = [];
    if has('cell_types')
        types = plainValues(ctx, sid, 'cell_types', path, 'uint8');
    end
    if has('cell_offsets')
        offsets = plainValues(ctx, sid, 'cell_offsets', path, 'int64');
    end
    if has('cell_connectivity')
        conn = plainValues(ctx, sid, 'cell_connectivity', path, 'int64');
    end
    checkCells(ctx, path, types, offsets, conn, nNodes);

    % ------------------------------------------------- support_id
    record.kind = kind;
    record.nNodes = nNodes;
    record.cellTypes = types;
    record.cellOffsets = offsets;
    record.cellConnectivity = conn;
    record.coordinates = [];
    if has('coordinates')
        did = H5D.open(sid, 'coordinates');
        info = H5.dsetInfo(did);
        try
            record.coordinates.values = H5.readData(did, info);
            record.coordinates.dims = cell(1, numel(info.dims));
        catch
            record.coordinates = [];
        end
        H5D.close(did);
    end
    stored = strAttr(sid, 'support_id');
    if ~isempty(stored)
        try
            computed = mestra.supportId(record);
            if ~strcmp(computed, stored)
                rep.add('E08', path, ...
                    'the support_id does not match the stored arrays');
            end
        catch err
            rep.add('U01', path, ...
                'the support_id could not be computed: %s', ...
                regexprep(strtrim(err.message), '\s+', ' '));
        end
    end

    % ----------------------------------------------------- arrays
    if ismember(kind, {'mesh', 'axis'}) && ~has('coordinates')
        rep.add('E03', path, 'a %s support has no coordinates array', kind);
    end
    if has('coordinates')
        guard(ctx, [path '/coordinates'], @() checkSlot(ctx, sid, ...
            'coordinates', [path '/coordinates'], 'node', nNodes, ...
            nCells, kind, index));
    end
    pairs = {'node_arrays', 'node'; 'cell_arrays', 'cell'};
    for p = 1:size(pairs, 1)
        if ~has(pairs{p, 1}), continue, end
        groupPath = [path '/' pairs{p, 1}];
        if ~strcmp(H5.childType(sid, pairs{p, 1}), 'group')
            rep.add('E39', groupPath, '%s must be a group', pairs{p, 1});
            continue
        end
        ag = H5.openGroup(sid, pairs{p, 1});
        for nm = H5.children(ag)
            slotPath = [groupPath '/' nm{1}];
            checkName(ctx, nm{1}, slotPath);
            if ~followable(ctx, ag, nm{1}, slotPath), continue, end
            location = pairs{p, 2};
            guard(ctx, slotPath, @() checkSlot(ctx, ag, nm{1}, slotPath, ...
                location, nNodes, nCells, kind, index));
        end
        H5G.close(ag);
    end

    known = [cellNames {'coordinates', 'node_arrays', 'cell_arrays', ...
                        'node', 'cell', 'cell_plus_one', 'index', 'row'}];
    for nm = H5.children(sid)
        if ~ismember(nm{1}, known)
            rep.add('W11', [path '/' nm{1}], ...
                'this reader does not know this object; it is ignored');
        end
    end
end

function [values, info] = plainValues(ctx, sid, name, path, wanted)
    H5 = mestra.internal.H5;
    did = H5D.open(sid, name);
    info = H5.dsetInfo(did);
    values = [];
    if ~strcmp(info.type, wanted)
        ctx.rep.add('E20', [path '/' name], ...
            '%s is stored as %s where %s is required', name, info.type, ...
            wanted);
    end
    checkAttrEncodings(ctx, did, [path '/' name]);
    checkScales(ctx, did, info, [path '/' name]);
    try
        values = reshape(double(H5.readData(did, info)), 1, []);
    catch
    end
    H5D.close(did);
end

function checkCells(ctx, path, types, offsets, conn, nNodes)
    rep = ctx.rep;
    if isempty(types) && isempty(offsets) && isempty(conn), return, end
    table = cellTypeTable();
    for i = 1:numel(types)
        if ~table.isKey(types(i))
            rep.add('E21', [path '/cell_types'], ...
                'cell type %d is not in the table of section 20', types(i));
        end
    end
    if ~isempty(offsets)
        if offsets(1) ~= 0
            rep.add('E23', [path '/cell_offsets'], ...
                'the first offset is %d and not 0', offsets(1));
        elseif any(diff(offsets) < 0)
            rep.add('E23', [path '/cell_offsets'], ...
                'the offsets are not non-decreasing');
        elseif offsets(end) ~= numel(conn)
            rep.add('E23', [path '/cell_offsets'], ...
                'the last offset is %d and the connectivity holds %d', ...
                offsets(end), numel(conn));
        end
    end
    if numel(offsets) == numel(types) + 1
        for j = 1:numel(types)
            span = offsets(j + 1) - offsets(j);
            if ~table.isKey(types(j)), continue, end
            want = table(types(j));
            if want < 0
                if span < 3
                    rep.add('E22', [path '/cell_connectivity'], ...
                        ['polygon %d has %d nodes where 3 or more are ' ...
                         'needed'], j - 1, span);
                end
            elseif span ~= want
                rep.add('E22', [path '/cell_connectivity'], ...
                    'cell %d has %d nodes where type %d takes %d', ...
                    j - 1, span, types(j), want);
            end
        end
    end
    if ~isempty(conn) && any(conn < 0 | conn >= nNodes)
        rep.add('E24', [path '/cell_connectivity'], ...
            'a connectivity value is outside [0, %d)', nNodes);
    end
end

% ============================================================= slots

function checkSlot(ctx, parent, name, path, location, nNodes, nCells, ...
                   kind, supportIndex)
    H5 = mestra.internal.H5;
    rep = ctx.rep;
    kind_ = H5.childType(parent, name);
    isGroup = strcmp(kind_, 'group');
    if isGroup
        oid = H5G.open(parent, name);
    elseif strcmp(kind_, 'dataset')
        oid = H5D.open(parent, name);
    else
        rep.add('E39', path, 'a slot must be a dataset or a group');
        return
    end
    checkAttrEncodings(ctx, oid, path);
    checkKnownAttrs(ctx, oid, path, ...
        {'role', 'varies', 'units', 'components', 'source', 'output', ...
         'statistic', 'of', 'quantile', 'category', 'recomputed', ...
         'derived_from', 'recipe', 'reference'});

    role = strAttr(oid, 'role');
    varies = strAttr(oid, 'varies');
    units = strAttr(oid, 'units');
    if isempty(role) || ~ismember(role, arrayRoles())
        rep.add('E02', path, 'the role is "%s"', role);
    end
    if ~H5.hasAttr(oid, 'varies')
        rep.add('E39', path, 'varies is required on an array slot');
    end
    if ~H5.hasAttr(oid, 'components')
        rep.add('E31', path, 'components is required on an array slot');
    end
    if strcmp(role, 'field') && ~H5.hasAttr(oid, 'units')
        rep.add('E11', path, 'a field needs units');
    elseif any(strcmp(role, {'derived', 'coordinates'})) && ...
           ~H5.hasAttr(oid, 'units')
        rep.add('E39', path, 'a %s array needs units', role);
    end
    if ~isempty(units) && ~mestra.internal.Units.parses(units)
        rep.add('W10', path, 'the units "%s" do not parse', units);
    end
    if strcmp(role, 'derived') && ...
       (~H5.hasAttr(oid, 'derived_from') || ~H5.hasAttr(oid, 'recipe'))
        rep.add('E13', path, ...
            'a derived array needs derived_from and recipe');
    end
    if any(strcmp(role, {'weight', 'normal'})) && ...
       ~H5.hasAttr(oid, 'recomputed')
        rep.add('W06', path, ...
            'a %s array does not say it was recomputed', role);
    end
    if strcmp(kind, 'axis') && strcmp(role, 'coordinates') && ...
       ~strcmp(varies, 'none')
        rep.add('E35', path, ...
            'the coordinates of an axis support must have varies = none');
    end
    checkSource(ctx, oid, path, isGroup);
    checkStatistic(ctx, oid, path);

    if isGroup
        H5G.close(oid);
        return
    end
    info = H5.dsetInfo(oid);
    checkArrayDtype(ctx, role, info.type, path);
    checkScales(ctx, oid, info, path);
    names = mestra.internal.Reader.axisNames(oid, numel(info.dims));

    % ---- E04: the leading dimension against `varies`
    if ~any(cellfun(@isempty, names))
        leading = '';
        if ~isempty(names), leading = names{1}; end
        if strcmp(varies, 'none')
            if any(strcmp(leading, {'row'})) || ...
               (numel(leading) > 6 && strncmp(leading, 'group:', 6))
                rep.add('E04', path, ...
                    'varies is none and the leading dimension is %s', ...
                    leading);
            end
        elseif ~isempty(varies) && ~strcmp(leading, varies)
            rep.add('E04', path, ...
                'varies is %s and the leading dimension is %s', ...
                varies, leading);
        end
    end

    % ---- E05: the node or cell extent against the support
    axis = find(strcmp(names, location), 1);
    if ~isempty(axis)
        want = nNodes;
        if strcmp(location, 'cell'), want = nCells; end
        if info.dims(axis) ~= want
            rep.add('E05', path, ...
                'the %s extent is %d where the support has %d', ...
                location, info.dims(axis), want);
        end
    end

    % ---- E31: components against the component extent
    declared = numAttr(oid, 'components');
    cAxis = find(strcmp(names, 'component'), 1);
    if ~isempty(declared) && ~isempty(cAxis) && info.dims(cAxis) ~= declared
        rep.add('E31', path, ...
            'components is %d and the component dimension is %d', ...
            declared, info.dims(cAxis));
    end

    % ---- E34 and E16: the leading extent
    if ~isempty(varies) && numel(varies) > 6 && strncmp(varies, 'group:', 6)
        table = groupCategoryCount(ctx, varies(7:end));
        if ~isempty(table) && ~isempty(info.dims) && info.dims(1) ~= table
            rep.add('E34', path, ...
                'the leading extent is %d and the group has %d categories', ...
                info.dims(1), table);
        end
    elseif strcmp(varies, 'row') && ~isempty(info.dims)
        want = ctx.rowCount;
        if ~isempty(ctx.aligned) && ctx.aligned == 0 && ~isempty(ctx.rowSupport)
            want = sum(ctx.rowSupport == supportIndex);
        end
        if info.dims(1) ~= want
            rep.add('E16', path, ...
                ['the leading extent is %d where %d rows are on this ' ...
                 'support'], info.dims(1), want);
        end
        checkChunking(ctx, oid, info, path, info.dims(1));
    end

    if strcmp(role, 'label')
        checkLabelValues(ctx, oid, info, path);
    elseif strcmp(role, 'field')
        try
            values = mestra.internal.H5.readData(oid, info);
            if isnumeric(values) && any(~isfinite(double(values(:))))
                rep.add('W03', path, 'a non-finite value');
            end
        catch err
            rep.add('U01', path, 'the values would not read: %s', ...
                    regexprep(strtrim(err.message), '\s+', ' '));
        end
    end
    H5D.close(oid);
end

function checkLabelValues(ctx, oid, info, path)
    name = strAttr(oid, 'category');
    if isempty(name), return, end
    table = categoryEntries(ctx, name);
    try
        values = double(mestra.internal.H5.readData(oid, info));
    catch
        return
    end
    bad = values(values < 0 | values >= numel(table));
    if ~isempty(bad)
        ctx.rep.add('E10', path, ...
            'the label value %g is outside a table of %d entries', ...
            bad(1), numel(table));
    end
end

function checkArrayDtype(ctx, role, type, path)
    switch role
        case {'coordinates', 'field', 'derived', 'weight', 'normal'}
            allowed = {'float64'};
        case 'label'
            allowed = {'int32', 'int64'};
        otherwise
            return
    end
    if ~ismember(type, allowed)
        ctx.rep.add('E20', path, ...
            'a %s array is stored as %s where section 19 allows %s', ...
            role, type, strjoin(allowed, ' or '));
    end
end

% ========================================================= callables

function checkCallables(ctx)
    H5 = mestra.internal.H5;
    if ~mestra.internal.Reader.hasGroup(ctx.fid, 'callables'), return, end
    g = H5.openGroup(ctx.fid, 'callables');
    closer = onCleanup(@() H5G.close(g)); %#ok<NASGU>
    for name = H5.children(g)
        path = ['/callables/' name{1}];
        checkName(ctx, name{1}, path);
        if ~followable(ctx, g, name{1}, path), continue, end
        if ~strcmp(H5.childType(g, name{1}), 'group')
            ctx.rep.add('E15', path, 'a callable must be a group');
            continue
        end
        guard(ctx, path, @() checkOneCallable(ctx, g, name{1}, path));
    end
end

function checkOneCallable(ctx, g, name, path)
    H5 = mestra.internal.H5;
    cid = H5.openGroup(g, name);
    closer = onCleanup(@() H5G.close(cid)); %#ok<NASGU>
    if ~H5.hasAttr(cid, 'type')
        ctx.rep.add('E15', path, 'a callable group has no type');
    end
    [~, problems] = mestra.internal.Codec.read(cid, true);
    for i = 1:numel(problems)
        if numel(problems{i}) > 4 && strcmp(problems{i}(1:4), 'U03 ')
            ctx.rep.add('U03', path, '%s', problems{i}(5:end));
        else
            ctx.rep.add('E32', path, '%s', problems{i});
        end
    end
end

% =========================================================== general

function checkSource(ctx, oid, path, isGroup)
    H5 = mestra.internal.H5;
    rep = ctx.rep;
    if ~H5.hasAttr(oid, 'source')
        rep.add('E39', path, 'source is required on a slot');
        return
    end
    source = strAttr(oid, 'source');
    if strcmp(source, 'data')
        if isGroup
            rep.add('E30', path, ...
                'source is data and the slot is stored as a group');
        end
        return
    end
    if numel(source) > 9 && strncmp(source, 'callable:', 9)
        if ~isGroup
            rep.add('E30', path, ...
                'source names a callable and the slot is a dataset');
        end
        id = source(10:end);
        if ~ismember(id, ctx.callableIds)
            rep.add('E14', path, ...
                ['source names the callable "%s", which the file does ' ...
                 'not hold'], id);
        end
        if ~H5.hasAttr(oid, 'output')
            rep.add('E39', path, ...
                'output is required when source names a callable');
        end
        return
    end
    rep.add('E36', path, ...
        'source is "%s" and must be data or callable:<id>', source);
end

function checkStatistic(ctx, oid, path)
    H5 = mestra.internal.H5;
    if ~H5.hasAttr(oid, 'statistic'), return, end
    statistic = strAttr(oid, 'statistic');
    if strcmp(statistic, 'quantile') && ~H5.hasAttr(oid, 'quantile')
        ctx.rep.add('E12', path, ...
            'the statistic is quantile and no quantile is given');
    end
    if ~any(strcmp(statistic, {'value', 'draw'})) && ~H5.hasAttr(oid, 'of')
        ctx.rep.add('E12', path, ...
            'the statistic is %s and does not say what it is of', statistic);
    end
end

function checkAttrEncodings(ctx, oid, path)
%checkAttrEncodings  E19, E26 and the variable-length string ban.
    H5 = mestra.internal.H5;
    kinds = attrKinds();
    for name = H5.publicAttrNames(oid)
        try
            info = H5.attrInfo(oid, name{1});
        catch err
            ctx.rep.add('U01', path, ...
                'the attribute %s would not be described: %s', name{1}, ...
                regexprep(strtrim(err.message), '\s+', ' '));
            continue
        end
        if strcmp(info.type, 'vlstring')
            ctx.rep.add('E19', path, ...
                'the attribute %s is a variable-length string', name{1});
            continue
        end
        if ~info.scalar
            % Section 18 gives every attribute this format names a
            % scalar dataspace, so an array there is the wrong
            % encoding whatever its type.
            if kinds.isKey(name{1})
                ctx.rep.add('E19', path, ...
                    ['the attribute %s is an array where a scalar ' ...
                     'is required'], name{1});
            else
                ctx.rep.add('W11', path, ...
                    'the attribute %s is not a scalar and is ignored', ...
                    name{1});
            end
            continue
        end
        if kinds.isKey(name{1})
            want = kinds(name{1});
            if ~strcmp(info.type, want)
                ctx.rep.add('E19', path, ...
                    'the attribute %s is %s where %s is required', ...
                    name{1}, info.type, want);
                continue
            end
            if strcmp(want, 'int8')
                v = H5.readAttr(oid, name{1});
                if ~any(double(v) == [0 1])
                    ctx.rep.add('E19', path, ...
                        'the boolean %s has the value %g', name{1}, double(v));
                end
            end
        end
        if strcmp(info.type, 'string')
            try
                bytes = H5.readRawStrAttr(oid, name{1});
                [ok, why] = mestra.internal.Text.checkStringBytes(bytes);
                if ~ok
                    ctx.rep.add('E26', path, 'the attribute %s has %s', ...
                                name{1}, why);
                end
            catch err
                ctx.rep.add('U01', path, ...
                    'the attribute %s could not be read as bytes: %s', ...
                    name{1}, regexprep(strtrim(err.message), '\s+', ' '));
            end
        end
    end
end

function checkKnownAttrs(ctx, oid, path, known)
%checkKnownAttrs  W11 for an attribute this version does not know.
    for name = mestra.internal.H5.publicAttrNames(oid)
        if ~ismember(name{1}, known)
            ctx.rep.add('W11', path, ...
                ['the attribute %s is not one this version knows; it ' ...
                 'is ignored'], name{1});
        end
    end
end

function checkScales(ctx, did, info, path)
%checkScales  E25 for every axis of a dataset.
    H5 = mestra.internal.H5;
    for axis = 1:numel(info.dims)
        names = H5.scaleNames(did, axis - 1);
        if isempty(names)
            ctx.rep.add('E25', path, ...
                'axis %d carries no dimension scale', axis - 1);
            continue
        end
        if numel(names) > 1
            ctx.rep.add('E25', path, ...
                'axis %d carries %d dimension scales', axis - 1, numel(names));
            continue
        end
        why = scaleNameProblem(names{1}, info.dims(axis));
        if ~isempty(why)
            ctx.rep.add('E25', path, 'axis %d: %s', axis - 1, why);
        end
    end
end

function why = scaleNameProblem(name, len)
%scaleNameProblem  Whether a scale's link name is one section 21 allows.
    why = '';
    fixed = {'row', 'node', 'cell', 'cell_plus_one', 'index'};
    if ismember(name, fixed), return, end
    parameterised = {'component_', 'draw_'};
    for i = 1:numel(parameterised)
        p = parameterised{i};
        if numel(name) > numel(p) && strncmp(name, p, numel(p))
            n = str2double(name(numel(p) + 1:end));
            if isnan(n) || n ~= len
                why = sprintf(['the scale is "%s" and the axis has ' ...
                               'length %d'], name, len);
            end
            return
        end
    end
    for p = {'group_', 'category_', 'mestra_'}
        if numel(name) > numel(p{1}) && strncmp(name, p{1}, numel(p{1}))
            return
        end
    end
    why = sprintf('"%s" is not a dimension name section 21 defines', name);
end

function checkChunking(ctx, did, info, path, nRows)
%checkChunking  E27, E29 and W12 for a row-dimensioned dataset.
    rep = ctx.rep;
    if isempty(info.chunk)
        rep.add('E27', path, 'a row-dimensioned dataset is not chunked');
    end
    for i = 1:size(info.filters, 1)
        id = info.filters(i, 1);
        if id == 1
            level = info.filters(i, 2);
            if level < 1 || level > 9
                rep.add('E29', path, 'gzip at level %d', level);
            end
        elseif id ~= 2
            rep.add('E29', path, ...
                'filter %d is not gzip or shuffle', id);
        end
    end
    if isempty(info.chunk), return, end
    rest = info.dims(2:end);
    itemsize = mestra.internal.Writer.itemSize(info.type);
    if strcmp(info.type, 'string'), itemsize = info.strSize; end
    c = mestra.internal.Writer.rowChunk(itemsize, rest, nRows);
    want = [c rest];
    if numel(want) ~= numel(info.chunk) || any(want ~= info.chunk)
        rep.add('W12', path, ...
            'the chunk is %s where the default of section 23 is %s', ...
            mat2str(info.chunk), mat2str(want));
    end
end

function checkName(ctx, name, path)
%checkName  E33 for a producer-chosen name.
    if ~mestra.internal.Text.legalName(name)
        ctx.rep.add('E33', path, ...
            '"%s" is not a legal netCDF-4 name', name);
    elseif mestra.internal.Text.reserved(name)
        ctx.rep.add('E33', path, ...
            '"%s" begins with the reserved prefix mestra_', name);
    end
end

function checkUnknown(ctx)
%checkUnknown  W11 for a root attribute or group this version ignores.
    H5 = mestra.internal.H5;
    known = mestra.internal.Reader.ROOT_ATTRS;
    for name = H5.publicAttrNames(ctx.root)
        if ~ismember(name{1}, known)
            ctx.rep.add('W11', '/', ...
                'the root attribute %s is not one this version knows', ...
                name{1});
        end
    end
    for name = H5.children(ctx.root)
        if ~mestra.internal.Reader.knownRootChild(ctx.root, name{1})
            ctx.rep.add('W11', ['/' name{1}], ...
                'this reader does not know this object; it is ignored');
        end
    end
end

function checkPrivate(ctx)
%checkPrivate  E18, as far as a validator may see it.
%   Section 18 makes E18 a rule for a writer, and section 29 forbids a
%   reader to interpret /private.  What a validator can see is a
%   public attribute that should be there and is not, in a file that
%   also carries a private group; that is the only decidable reading,
%   and it is the one the corpus case err_e18 is built on.
    if ~mestra.internal.H5.exists(ctx.fid, '/private'), return, end
    if ctx.rep.has('E39')
        ctx.rep.add('E18', '/private', ...
            ['a required public attribute is missing from a file that ' ...
             'carries a private group']);
    end
end

% ========================================================== fetching

function v = strAttr(oid, name)
    v = mestra.internal.Reader.str(oid, name);
end

function v = numAttr(oid, name)
    v = mestra.internal.Reader.num(oid, name);
end

function entries = categoryEntries(ctx, name)
    entries = {};
    if ~isempty(name) && ctx.categories.isKey(name)
        entries = ctx.categories(name);
    end
end

function n = groupCategoryCount(ctx, keyName)
    n = [];
    k = findKey(ctx, keyName, 'name');
    if isempty(k) || isempty(k.category), return, end
    n = numel(categoryEntries(ctx, k.category));
end

function k = findKey(ctx, value, field)
    k = [];
    for i = 1:numel(ctx.keys)
        if strcmp(ctx.keys(i).(field), value)
            k = ctx.keys(i);
            return
        end
    end
end
