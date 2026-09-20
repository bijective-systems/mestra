function d4_transient(out)
%D4_TRANSIENT  Dataset 4, a time key with trajectories of unequal length.
%   Three runs of 4, 3 and 5 steps on a fixed five-node line mesh.
%
%   'TrajectoryGroup' is a guess: matlab/README.md never shows how to
%   attach a time key to its run.

steps = [4 3 5];
diffusivity = [0.10 0.25 0.40];
amplitude = [1 2 3];
run_of_row = []; t_of_row = []; diff_of_row = []; amp_of_row = [];
for ri = 1:3
    for s = 1:steps(ri)
        run_of_row(end+1) = ri - 1;          %#ok<AGROW>
        t_of_row(end+1) = 0.1 * s;           %#ok<AGROW>
        diff_of_row(end+1) = diffusivity(ri);%#ok<AGROW>
        amp_of_row(end+1) = amplitude(ri);   %#ok<AGROW>
    end
end
n_rows = numel(run_of_row);
n_nodes = 5;
x = linspace(0, 1, n_nodes);

u = zeros(n_rows, n_nodes);
for r = 1:n_rows
    u(r, :) = amp_of_row(r) * exp(-diff_of_row(r) * t_of_row(r)) ...
              .* sin(pi * x);
end

d = mestra.Dataset();
d.addCategory('run', {'r000', 'r001', 'r002'});
d.addKey('diffusivity', 'design', diff_of_row, 'Units', 'm^2/s');
d.addKey('amplitude', 'design', amp_of_row, 'Units', 'K');
d.addKey('t', 'time', t_of_row, 'Units', 's', 'TrajectoryGroup', 'run');
d.addKey('run', 'group', int32(run_of_row), 'Category', 'run');
d.generalisationGroup = 'run';

d.addMeshSupport('s0', x, uint8([3 3 3 3]), int64([0 2 4 6 8]), ...
                 int64([0 1 1 2 2 3 3 4]), 'Units', 'm', ...
                 'Varies', 'none', 'Dims', {'component', 'node'});
d.addNodeArray('s0', 'u', u, 'field', 'Units', 'K', 'Dims', {'row', 'node'});

mestra.write(d, out);
fprintf('wrote %s\n', out);
r = mestra.validate(out);
fprintf('validate: valid=%d\n', r.valid);
for f = r.findings
    fprintf('    %s %s %s\n', f.id, f.path, f.message);
end
end
