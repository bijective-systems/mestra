% A support and a field: the same six rows on a two-quad mesh.
% See README.md in this directory for the data and the output.
xy = [0 0; 1 0; 2 0; 0 1; 1 1; 2 1];
coordinates = cat(3, [1.0; 1.5; 2.0] * xy(:, 1)', repmat(xy(:, 2)', 3, 1));
pressure = 100 * (1:6)' + (1:6);

d = mestra.Dataset();
d.writer = 'mestra examples 1';
d.addKey('mach', [0.4 0.8 0.4 0.8 0.4 0.8], 'condition', '1');
d.addCategoryTable('member', {'wing_a', 'wing_b', 'wing_c'});
d.addKey('member', int32([0 0 1 1 2 2]), 'group', 'Category', 'member');
d.setGeneralisationGroup('member');
d.addMeshSupport('s0', coordinates, uint8([9 9]), int64([0 4 8]), ...
                 int64([0 1 4 3 1 2 5 4]), 'm', ...
                 'Dims', {'group:member', 'node', 'component'});
d.addNodeArray('s0', 'pressure', pressure, 'field', 'Pa', ...
               'Dims', {'row', 'node'});
mestra.write(d, 'family.mes');

r = mestra.read('family.mes');
s = r.support('s0');
p = r.nodeArray('s0', 'pressure');
yes = {'False', 'True'};
fprintf('aligned: %s nodes: %d cells: %d\n', yes{r.aligned + 1}, ...
        s.nNodes, s.nCells);
% MATLAB hands every array back with its axes reversed, so p.dims here
% is {'component', 'node', 'row'}; printed in the file's order it is
% the same tuple the other languages print.
fprintf('pressure (''%s'') %s\n', strjoin(fliplr(p.dims), ''', '''), p.units);
v = mestra.permute(p.values, p.dims, {'row', 'node', 'component'});
fprintf('pressure at row 1 node 3: %.1f\n', v(1 + 1, 3 + 1, 0 + 1));
% The leading axis of an array that varies along a group is named
% group:<key> here; the corpus calls the same axis instance.
c = mestra.permute(s.coordinates.values, s.coordinates.dims, ...
                   {'group:member', 'node', 'component'});
fprintf('x of node 2 for wing_b: %.1f\n', c(1 + 1, 2 + 1, 0 + 1));
