function out = info(path, varargin)
%MESTRA.INFO  Print what is in a file, without reading any array.
%
%   MESTRA.INFO(PATH) prints the fields every implementation prints
%   (docs/api-conventions.md, section 5):
%
%     * for every key, its name, role, units, bounds, category,
%       trajectory group and parent;
%     * for every support, its kind, its node and cell counts and its
%       id;
%     * for every slot, its shape with the axes named, its units, its
%       source, and for a callable slot the callable id and the
%       output it fills.
%
%   It goes through MESTRA.OPEN, so it reads attributes and
%   dataspaces and no array at all (specification section 29).  That
%   is what makes it usable on a file too large to read, and on the
%   files a user most needs to inspect.
%
%       mestra.info('mesh_two_rows.mes')
%       mesh_two_rows.mes
%         format mestra/0, writer mestra python 0
%         created 2026-09-19T00:00:00Z
%         2 row(s), aligned, unit of generalisation member
%
%         keys
%           mach     condition  units 1     bounds [0.4, 0.8]
%           member   group      category member
%         ...
%
%   A shape is printed in the file's own axis order with every axis
%   named, `row=2 node=6 component=1`, because that is the order the
%   file states.  What MESTRA.READ hands back in MATLAB is the
%   reverse of it; permute by name with MESTRA.PERMUTE.
%
%   S = MESTRA.INFO(PATH, 'String', true) returns the text instead of
%   printing it.
%
%   MESTRA.INFO does not validate.  MESTRA.VALIDATE and MESTRA.REPORT
%   do that, and a file with a semantic fault still prints here,
%   which is the point.
%
%   See also mestra.open, mestra.validate, mestra.report, mestra.read.

    p = inputParser();
    p.addParameter('String', false);
    p.addParameter('File', 1);
    p.parse(varargin{:});

    d = mestra.open(path, 'Strict', false);
    L = {};

    [~, base, ext] = fileparts(path);
    L{end + 1} = [base ext];
    L{end + 1} = sprintf('  format %s, writer %s', d.format, d.writer);
    L{end + 1} = sprintf('  created %s', d.created);
    line = sprintf('  %d row(s)', d.nRows);
    if ~isempty(d.supports)
        if d.aligned
            line = [line ', aligned'];
        else
            line = [line ', unaligned'];
        end
    end
    if ~isempty(d.generalisationGroup)
        line = [line ', unit of generalisation ' d.generalisationGroup];
    end
    L{end + 1} = line;

    if ~isempty(d.keys)
        L{end + 1} = '';
        L{end + 1} = '  keys';
        width = max(cellfun(@numel, {d.keys.name}));
        for i = 1:numel(d.keys)
            k = d.keys(i);
            bits = {};
            if ~isempty(k.units)
                bits{end + 1} = ['units ' k.units]; %#ok<AGROW>
            end
            if ~isempty(k.lower) || ~isempty(k.upper)
                bits{end + 1} = sprintf('bounds [%s, %s]', ...
                    num(k.lower), num(k.upper)); %#ok<AGROW>
            end
            if ~isempty(k.category)
                bits{end + 1} = ['category ' k.category]; %#ok<AGROW>
            end
            if ~isempty(k.trajectoryGroup)
                bits{end + 1} = ['trajectory group ' ...
                                 k.trajectoryGroup]; %#ok<AGROW>
            end
            if ~isempty(k.parent)
                bits{end + 1} = ['parent ' k.parent]; %#ok<AGROW>
            end
            L{end + 1} = sprintf('    %-*s  %-11s %s', width, k.name, ...
                                 k.role, strjoin(bits, '  ')); %#ok<AGROW>
        end
    end

    if ~isempty(d.categories)
        L{end + 1} = '';
        L{end + 1} = '  category tables';
        for i = 1:numel(d.categories)
            c = d.categories(i);
            L{end + 1} = sprintf('    %s  %d entr%s: %s', c.name, ...
                numel(c.entries), plural(numel(c.entries)), ...
                strjoin(c.entries, ', ')); %#ok<AGROW>
        end
    end

    if ~isempty(d.scalars)
        L{end + 1} = '';
        L{end + 1} = '  scalars';
        for i = 1:numel(d.scalars)
            L{end + 1} = ['    ' slotLine(d.scalars(i), {'row'}, ...
                                          d.nRows)]; %#ok<AGROW>
        end
    end

    if ~isempty(d.supports)
        L{end + 1} = '';
        L{end + 1} = '  supports';
        for i = 1:numel(d.supports)
            s = d.supports(i);
            L{end + 1} = sprintf('    %s  kind %s, %d node(s), %d cell(s)', ...
                                 s.name, s.kind, s.nNodes, s.nCells); %#ok<AGROW>
            L{end + 1} = sprintf('      id %s', s.supportId); %#ok<AGROW>
            if ~isempty(s.coordinates)
                L{end + 1} = ['      ' slotLine(s.coordinates)]; %#ok<AGROW>
            end
            for j = 1:numel(s.nodeArrays)
                L{end + 1} = ['      node ' ...
                              slotLine(s.nodeArrays(j))]; %#ok<AGROW>
            end
            for j = 1:numel(s.cellArrays)
                L{end + 1} = ['      cell ' ...
                              slotLine(s.cellArrays(j))]; %#ok<AGROW>
            end
        end
    end

    if ~isempty(d.callables)
        L{end + 1} = '';
        L{end + 1} = '  callables';
        for i = 1:numel(d.callables)
            c = d.callables(i);
            line = sprintf('    %s  type %s', c.id, c.type);
            if ~isempty(c.repr)
                line = [line '  ' c.repr]; %#ok<AGROW>
            end
            L{end + 1} = line; %#ok<AGROW>
        end
    end

    if ~isempty(d.skipped)
        L{end + 1} = '';
        L{end + 1} = '  passed over';
        for i = 1:numel(d.skipped)
            L{end + 1} = ['    ' d.skipped{i}]; %#ok<AGROW>
        end
    end

    text = [strjoin(L, newline) newline];
    if p.Results.String
        out = text;
        return
    end
    fprintf(p.Results.File, '%s', text);
    if nargout > 0
        out = d;
    end
end

function s = slotLine(slot, dims, rowCount)
%slotLine  One slot: its name, its shape with the axes named, its
%   units and its source.
    if nargin < 2, dims = slot.dims; end
    bits = {};
    shape = '';
    if isfield(slot, 'shape') && ~isempty(slot.shape)
        shape = namedShape(fliplr(dims), slot.shape);
    elseif nargin >= 3
        shape = sprintf('row=%d', rowCount);
    end
    if ~isempty(shape)
        bits{end + 1} = ['(' shape ')'];
    end
    if isfield(slot, 'role') && ~isempty(slot.role)
        bits{end + 1} = slot.role;
    end
    if ~isempty(slot.units)
        bits{end + 1} = ['units ' slot.units];
    end
    if isfield(slot, 'varies') && ~isempty(slot.varies)
        bits{end + 1} = ['varies ' slot.varies];
    end
    if isfield(slot, 'components') && ~isempty(slot.components)
        bits{end + 1} = sprintf('components %d', slot.components);
    end
    if isfield(slot, 'category') && ~isempty(slot.category)
        bits{end + 1} = ['category ' slot.category];
    end
    if isfield(slot, 'statistic') && ~isempty(slot.statistic)
        bits{end + 1} = ['statistic ' slot.statistic];
    end
    src = slot.source;
    if numel(src) > 9 && strncmp(src, 'callable:', 9)
        bits{end + 1} = ['source callable ' src(10:end)];
        if ~isempty(slot.output)
            bits{end + 1} = ['output ' slot.output];
        end
    else
        bits{end + 1} = ['source ' src];
    end
    s = sprintf('%s  %s', slot.name, strjoin(bits, ', '));
end

function s = namedShape(fileDims, shape)
%namedShape  `row=2 node=6 component=1`, in the file's axis order.
    n = min(numel(fileDims), numel(shape));
    bits = cell(1, n);
    for i = 1:n
        bits{i} = sprintf('%s=%d', fileDims{i}, shape(i));
    end
    s = strjoin(bits, ' ');
end

function s = num(v)
    if isempty(v)
        s = '-';
    else
        s = strtrim(sprintf('%g', double(v)));
    end
end

function s = plural(n)
    if n == 1, s = 'y'; else, s = 'ies'; end
end
