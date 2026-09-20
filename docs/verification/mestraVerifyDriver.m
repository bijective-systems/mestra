function mestraVerifyDriver(mode, varargin)
%MESTRAVERIFYDRIVER  Phase 3 verification driver for the MATLAB package.
%
%   Speaks the same JSON as the drivers for the other three languages,
%   so that the harness can compare them without knowing anything
%   about any of them.  The result is written to a file rather than to
%   stdout, because -batch prints more than the result.
%
%     mestraVerifyDriver('check', FILE, PROBES.json, OUT.json)
%     mestraVerifyDriver('write', IN.mes, OUT.mes, OUT.json)
%     mestraVerifyDriver('eval',  FILE, SPEC.json, OUT.json)
%     mestraVerifyDriver('evalw', FILE, SPEC.json, OUT.mes, OUT.json)
%     mestraVerifyDriver('codec', FILE, OUT.json)
%     mestraVerifyDriver('batch', JOBS.json)

switch mode
    case 'batch'
        doBatch(varargin{1});
    case 'check'
        out = doCheck(varargin{1}, varargin{2});
        writeJson(out, varargin{3});
    case 'write'
        out = doWrite(varargin{1}, varargin{2});
        writeJson(out, varargin{3});
    case 'eval'
        out = doEval(varargin{1}, varargin{2}, '');
        writeJson(out, varargin{3});
    case 'evalw'
        out = doEval(varargin{1}, varargin{2}, varargin{3});
        writeJson(out, varargin{4});
    case 'codec'
        out = doCodec(varargin{1});
        writeJson(out, varargin{2});
    otherwise
        error('mestra:driver', 'unknown mode %s', mode);
end
end


function doBatch(jobsPath)
%doBatch  Run many jobs from one file, so MATLAB starts once.
jobs = jsondecode(fileread(jobsPath));
if isstruct(jobs), jobs = num2cell(jobs); end
for i = 1:numel(jobs)
    job = jobs{i};
    try
        switch job.op
            case 'check'
                out = doCheck(job.file, job.probes);
            case 'write'
                out = doWrite(job.src, job.dst);
            case 'eval'
                out = doEval(job.file, job.spec, '');
            case 'evalw'
                out = doEval(job.file, job.spec, job.mes);
            case 'codec'
                out = doCodec(job.file);
            otherwise
                error('mestra:driver', 'unknown op %s', job.op);
        end
    catch err
        out = struct('failed', sprintf('%s: %s', err.identifier, err.message));
    end
    writeJson(out, job.out);
end
end


function writeJson(value, path)
fid = fopen(path, 'w');
fwrite(fid, jsonencode(value));
fclose(fid);
end


function out = doCheck(file, probesPath)
out = struct('errors', {{}}, 'warnings', {{}}, ...
             'support_ids', containers.Map('KeyType', 'char', ...
                                           'ValueType', 'any'), ...
             'probes', {{}}, 'trouble', {{}});
try
    r = mestra.validate(file);
    out.errors = reshape(r.errors, 1, []);
    out.warnings = reshape(r.warnings, 1, []);
catch err
    out.trouble{end + 1} = sprintf('validate: %s', err.message);
end
probes = loadProbes(probesPath);
d = [];
try
    d = mestra.read(file);
catch err
    out.trouble{end + 1} = sprintf('read: %s', err.message);
end
if isempty(d)
    for i = 1:numel(probes)
        out.probes{end + 1} = [];
    end
    if isempty(out.errors), out.errors = {}; end
    return
end
try
    names = d.supportNames();
    for i = 1:numel(names)
        out.support_ids(names{i}) = mestra.supportId(d.support(names{i}));
    end
catch err
    out.trouble{end + 1} = sprintf('supportId: %s', err.message);
end
for i = 1:numel(probes)
    try
        out.probes{end + 1} = probeText(d, probes{i});
    catch err
        out.probes{end + 1} = [];
        out.trouble{end + 1} = sprintf('probe %s: %s', ...
                                       probes{i}.slot, err.message);
    end
end
if isempty(out.errors), out.errors = {}; end
if isempty(out.warnings), out.warnings = {}; end
end


function out = doWrite(src, dst)
d = mestra.read(src);
mestra.write(d, dst);
out = struct('ok', true);
end


function out = doEval(file, specPath, outMes)
spec = jsondecode(fileread(specPath));
names = fieldnames(spec.keys);
cols = cell(1, numel(names));
for i = 1:numel(names)
    raw = spec.keys.(names{i});
    if ~iscell(raw), raw = num2cell(raw); end
    v = zeros(numel(raw), 1);
    for j = 1:numel(raw)
        v(j) = fromDecimal(raw{j});
    end
    cols{i} = v;
end
t = table(cols{:}, 'VariableNames', names);
out = struct('probes', {{}}, 'trouble', {{}});
d = mestra.read(file);
got = mestra.evaluate(d, t);
probes = spec.probes;
if isstruct(probes), probes = num2cell(probes); end
for i = 1:numel(probes)
    try
        out.probes{end + 1} = probeText(got, probes{i});
    catch err
        out.probes{end + 1} = [];
        out.trouble{end + 1} = sprintf('%s: %s', probes{i}.slot, err.message);
    end
end
if ~isempty(outMes)
    mestra.write(got, outMes);
end
end


function out = doCodec(file)
d = mestra.read(file);
out = containers.Map('KeyType', 'char', 'ValueType', 'any');
ids = {d.callables.id};
for i = 1:numel(ids)
    record = d.callable(ids{i});
    out(ids{i}) = struct('type', record.type, 'dict', tagged(record.dict));
end
end


% -------------------------------------------------------------- probes

function list = loadProbes(path)
raw = jsondecode(fileread(path));
if isstruct(raw)
    list = num2cell(raw);
elseif iscell(raw)
    list = raw;
else
    list = {};
end
list = reshape(list, 1, []);
end


function s = probeText(d, p)
[values, dims] = arrayFor(d, p.slot);
if isempty(dims)
    idx = positionalIndex(p, ndims(values));
else
    idx = ones(1, numel(dims));
    for axis = 1:numel(dims)
        idx(axis) = indexFor(p, dims{axis});
    end
end
subs = num2cell(idx);
value = values(subs{:});
s = asText(value);
end


function s = asText(value)
if ischar(value)
    s = value;
elseif iscell(value)
    s = asText(value{1});
elseif islogical(value)
    s = sprintf('%d', double(value));
elseif isinteger(value)
    s = sprintf('%d', value);
elseif isa(value, 'string')
    s = char(value);
else
    s = decimal17(double(value));
end
end


function s = decimal17(x)
if isnan(x)
    s = 'nan';
elseif isinf(x)
    if x > 0, s = 'inf'; else, s = '-inf'; end
else
    s = sprintf('%.17e', x);
end
end


function x = fromDecimal(s)
if ischar(s) || isstring(s)
    s = char(s);
    switch s
        case 'nan', x = NaN;
        case 'inf', x = Inf;
        case '-inf', x = -Inf;
        otherwise, x = sscanf(s, '%lf');
    end
else
    x = double(s);
end
end


function idx = positionalIndex(p, n)
% Section 30: a dataset inside a callable's dictionary has no logical
% dimension names; the index fields apply in a fixed order to its axes
% in file order.
order = {'row', 'instance', 'draw', 'node', 'component', 'index'};
found = [];
for i = 1:numel(order)
    if isfield(p, order{i})
        found(end + 1) = double(p.(order{i})) + 1; %#ok<AGROW>
    end
end
idx = ones(1, max(n, numel(found)));
idx(1:numel(found)) = found;
end


function i = indexFor(p, dim)
switch dim
    case 'row',           i = double(p.row) + 1;
    case 'draw',          i = double(p.draw) + 1;
    case {'node', 'cell'}
        if isfield(p, 'node'), i = double(p.node) + 1;
        else, i = double(p.cell) + 1; end
    case 'component',     i = double(p.component) + 1;
    case 'index',         i = double(p.index) + 1;
    case 'cell_plus_one', i = double(p.cell_plus_one) + 1;
    case 'instance',      i = double(p.instance) + 1;
    otherwise
        if numel(dim) > 6 && strcmp(dim(1:6), 'group:')
            i = double(p.instance) + 1;
        else
            error('mestra:driver', 'no index for the dimension "%s"', dim);
        end
end
end


function [values, dims] = arrayFor(d, path)
parts = strsplit(path, '/');
parts = parts(~cellfun(@isempty, parts));
switch parts{1}
    case 'keys'
        values = d.key(parts{2}).values;  dims = {'row'};
    case 'scalars'
        values = d.scalar(parts{2}).values; dims = {'row'};
    case 'row_support'
        values = d.rowSupport; dims = {'row'};
    case 'supports'
        s = d.support(parts{2});
        switch parts{3}
            case 'cell_types'
                values = s.cellTypes; dims = {'cell'};
            case 'cell_offsets'
                values = s.cellOffsets; dims = {'cell_plus_one'};
            case 'cell_connectivity'
                values = s.cellConnectivity; dims = {'index'};
            case 'coordinates'
                values = s.coordinates.values; dims = s.coordinates.dims;
            case 'node_arrays'
                a = d.nodeArray(parts{2}, parts{4});
                values = a.values; dims = a.dims;
            case 'cell_arrays'
                a = d.cellArray(parts{2}, parts{4});
                values = a.values; dims = a.dims;
            otherwise
                error('mestra:driver', 'no slot at "%s"', path);
        end
    case 'callables'
        record = d.callable(parts{2});
        node = record.dict;
        for i = 3:numel(parts)
            node = node(parts{i});
        end
        values = node.data; dims = {};
    otherwise
        error('mestra:driver', 'no slot at "%s"', path);
end
end


% --------------------------------------------- the tagged form of s.30

function out = tagged(value)
if isa(value, 'containers.Map')
    v = containers.Map('KeyType', 'char', 'ValueType', 'any');
    k = value.keys();
    for i = 1:numel(k)
        v(k{i}) = tagged(value(k{i}));
    end
    out = struct('t', 'dict', 'v', v);
elseif isa(value, 'missing')
    out = struct('t', 'null');
elseif isa(value, 'mestra.Array')
    el = value.elements();
    dt = value.dtype();
    shape = reshape(double(value.shape), 1, []);
    if strcmp(dt, 'string')
        strs = cell(1, numel(el));
        for i = 1:numel(el)
            if iscell(el), strs{i} = char(el{i}); else, strs{i} = char(el(i)); end
        end
        out = struct('t', 'strings', 'shape', shape, 'data', {strs});
    elseif strcmp(dt, 'float64')
        cells = cell(1, numel(el));
        for i = 1:numel(el)
            cells{i} = decimal17(double(el(i)));
        end
        out = struct('t', 'array', 'dtype', 'float64', 'shape', shape, ...
                     'data', {cells});
    elseif strcmp(dt, 'int8')
        out = struct('t', 'array', 'dtype', 'bool', 'shape', shape, ...
                     'data', {num2cell(logical(el))});
    else
        out = struct('t', 'array', 'dtype', dt, 'shape', shape, ...
                     'data', {num2cell(el)});
    end
elseif ischar(value)
    out = struct('t', 'str', 'v', value);
elseif isstring(value)
    out = struct('t', 'str', 'v', char(value));
elseif islogical(value)
    out = struct('t', 'bool', 'v', logical(value));
elseif isa(value, 'int64') || isa(value, 'int32')
    out = struct('t', 'i64', 'v', value);
else
    out = struct('t', 'f64', 'v', decimal17(double(value)));
end
end
