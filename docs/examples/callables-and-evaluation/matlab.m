% A callable and evaluation: a file with no rows that produces rows.
% See README.md in this directory for the data and the output.
xy = [0 0; 1 0; 2 0; 0 1; 1 1; 2 1];
model = mestra.Affine({'mach', 'alpha'}, struct( ...
    'cl', struct('A', [2.0 0.1], 'b', 0.05, 'shape', []), ...
    'pressure', struct('A', [1 0; 2 0; 3 0.5; 4 0.5; 5 1; 6 1], ...
                       'b', [0; 0.1; 0.2; 0.3; 0.4; 0.5], ...
                       'shape', [6 1])));

d = mestra.Dataset();
d.writer = 'mestra examples 1';
d.addKey('mach', [], 'condition', '1', 'Lower', 0.1, 'Upper', 0.9);
d.addKey('alpha', [], 'condition', 'degree', 'Lower', 0.0, 'Upper', 8.0);
d.addCallable('m1', model);
d.addMeshSupport('s0', xy, uint8([9 9]), int64([0 4 8]), ...
                 int64([0 1 4 3 1 2 5 4]), 'm', ...
                 'Dims', {'node', 'component'});
d.addCallableSlot('s0', 'pressure', 'field', 'Pa', 'm1', 'pressure', ...
                  'Components', 1);
d.addScalar('cl', [], '1', 'Callable', 'm1', 'Output', 'cl');
mestra.write(d, 'model.mes');

r = mestra.read('model.mes');
fprintf('rows: %d callables: [''%s'']\n', r.nRows, ...
        strjoin({r.callables.id}, ''', '''));
fprintf('cl source: %s\n', r.scalar('cl').source);
e = mestra.evaluate(r, table(0.5, 4.0, 'VariableNames', {'mach', 'alpha'}));
fprintf('evaluated rows: %d source: %s\n', e.nRows, e.scalar('cl').source);
fprintf('cl: %g\n', e.scalar('cl').values(1));
a = e.nodeArray('s0', 'pressure');
p = mestra.permute(a.values, a.dims, {'row', 'node', 'component'});
fprintf('pressure: [%s]\n', strjoin(compose('%g', p(1, :, 1)), ' '));
