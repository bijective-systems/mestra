% Uncertainty as draws: four whole fields per row, and two summaries.
% See README.md in this directory for the data and the output.
xy = [0 0; 1 0; 2 0; 0 1; 1 1; 2 1];
base = [101 102 103 104 105 106; 201 202 203 204 205 206];
draws = reshape(base, 2, 1, 6) + reshape([-1 -1 1 1], 1, 4);

d = mestra.Dataset();
d.writer = 'mestra examples 1';
d.addKey('mach', [0.4 0.8], 'condition', '1');
d.addMeshSupport('s0', xy, uint8([9 9]), int64([0 4 8]), ...
                 int64([0 1 4 3 1 2 5 4]), 'm', 'Dims', {'node', 'component'});
d.addNodeArray('s0', 'pressure', draws, 'field', 'Pa', ...
               'Dims', {'row', 'draw', 'node'}, 'Statistic', 'draw');
mu = squeeze(mean(draws, 2)); sd = squeeze(std(draws, 1, 2));
d.addNodeArray('s0', 'pressure_mean', mu, 'field', 'Pa', 'Dims', ...
               {'row', 'node'}, 'Statistic', 'mean', 'Of', 'pressure');
d.addNodeArray('s0', 'pressure_std', sd, 'field', 'Pa', 'Dims', ...
               {'row', 'node'}, 'Statistic', 'std', 'Of', 'pressure');
mestra.write(d, 'draws.mes');

r = mestra.read('draws.mes');
p = r.nodeArray('s0', 'pressure');
% p.dims is MATLAB's order, the reverse of the file's; printed in the
% file's order it is the tuple the other languages print.
fprintf('pressure (''%s'') %s\n', strjoin(fliplr(p.dims), ''', '''), ...
        p.statistic);
v = mestra.permute(p.values, p.dims, {'row', 'draw', 'node', 'component'});
fprintf('draw 0 of row 0: [%s]\n', ...
        strjoin(compose('%g.', reshape(v(1, 1, :, 1), 1, [])), ' '));
for name = {'pressure_mean', 'pressure_std'}
    a = r.nodeArray('s0', name{1});
    w = mestra.permute(a.values, a.dims, {'row', 'node', 'component'});
    fprintf('%s %s of %s at row 0, node 0: %.1f\n', a.name, a.statistic, ...
            a.of, w(1, 1, 1));
end
