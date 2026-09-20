% Reading someone else's file: ask the file what is in it, then take
% one value by name. See README.md for the data and the output.
here = fileparts(mfilename('fullpath'));
path = fullfile(here, '..', 'mesh_two_rows.mes');
yes = {'False', 'True'};
quoted = @(c) ['[''' strjoin(c, ''', ''') ''']'];
fprintf('valid: %s\n', yes{mestra.validate(path).valid + 1});

d = mestra.read(path);
fprintf('%d rows, aligned: %s\n', d.nRows, yes{d.aligned + 1});
pairs = cellfun(@(n) sprintf('(''%s'', ''%s'')', n, d.key(n).role), ...
                d.keyNames(), 'UniformOutput', false);
fprintf('keys: [%s]\n', strjoin(pairs, ', '));
fprintf('scalars: %s\n', quoted({d.scalars.name}));
for name = d.supportNames()
    s = d.support(name{1});
    fprintf('support %s %s %d nodes %d cells\n', s.name, s.kind, ...
            s.nNodes, s.nCells);
    fprintf('  node arrays: %s\n', quoted({s.nodeArrays.name}));
    fprintf('  cell arrays: %s\n', quoted({s.cellArrays.name}));
end
p = d.nodeArray('s0', 'pressure');
fprintf('pressure (''%s'') %s %s\n', strjoin(fliplr(p.dims), ''', '''), ...
        p.units, p.varies);
v = mestra.permute(p.values, p.dims, {'row', 'node', 'component'});
fprintf('pressure at row 1 node 3: %.1f\n', v(1 + 1, 3 + 1, 0 + 1));
chunk = d.readRows('/supports/s0/node_arrays/pressure', [1 1]);
shape = arrayfun(@(i) size(chunk.values, i), numel(chunk.dims):-1:1);
fprintf('row 0 alone: (%s)\n', strjoin(compose('%d', shape), ', '));
region = d.cellArray('s0', 'region');
fprintf('region is a %s over %s\n', region.role, ...
        quoted(d.category('region').entries));
