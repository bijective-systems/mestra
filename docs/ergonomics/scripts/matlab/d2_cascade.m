function d2_cascade(out)
%D2_CASCADE  Dataset 2, varying geometry, several fields, a split key and
%   a status column whose withheld outputs are NaN.

n_rows = 8; n_nodes = 6;
d = mestra.Dataset();
d.addCategory('split', {'train', 'validation', 'test'});
d.addCategory('status', {'converged', 'partial'});
cases = cell(1, n_rows);
for i = 1:n_rows, cases{i} = sprintf('c%02d', i - 1); end
d.addCategory('case', cases);

d.addKey('angle_in', 'condition', 30:2:44, 'Units', 'degree');
d.addKey('mach_out', 'condition', 0.70:0.05:1.05, 'Units', '1');
d.addKey('split', 'split', int32([0 0 0 0 1 1 2 2]), 'Category', 'split');
d.addKey('case', 'group', int32(0:n_rows-1), 'Category', 'case');
d.addKey('status', 'status', int32([0 0 0 0 0 0 1 1]), 'Category', 'status');
d.generalisationGroup = 'case';

d.addScalar('power', [100 110 120 130 140 150 NaN NaN], 'Units', 'W');
d.addScalar('angle_out', [-60 -61 -62 -63 -64 -65 NaN NaN], ...
            'Units', 'degree');

rng(1);
base = [0 1 2 0 1 2; 0 0 0 1 1 1];          % (component, node)
coords = zeros(2, n_nodes, n_rows);
for i = 1:n_rows
    coords(:, :, i) = base + randn(2, n_nodes) * 0.02;
end
d.addMeshSupport('s0', coords, uint8([9 9]), int64([0 4 8]), ...
                 int64([0 1 4 3 1 2 5 4]), 'Units', 'm', ...
                 'Varies', 'row', 'Dims', {'component', 'node', 'row'});

d.addNodeArray('s0', 'mach', 0.5 + rand(n_rows, n_nodes), 'field', ...
               'Units', '1', 'Dims', {'row', 'node'});
d.addNodeArray('s0', 'nut', 1e-5 * rand(n_rows, n_nodes), 'field', ...
               'Units', 'm^2/s', 'Dims', {'row', 'node'});

mestra.write(d, out);
fprintf('wrote %s\n', out);
r = mestra.validate(out);
fprintf('validate: valid=%d\n', r.valid);
for f = r.findings
    fprintf('    %s %s %s\n', f.id, f.path, f.message);
end
end
