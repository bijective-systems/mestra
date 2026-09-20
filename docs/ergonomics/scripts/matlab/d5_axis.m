function d5_axis(out)
%D5_AXIS  Dataset 5, an axis support: a ground signature over a time axis.
%
%   matlab/README.md documents addMeshSupport and nothing else, so
%   addAxisSupport is a guess made from SPEC.md's vocabulary.

n_rows = 6; n_samples = 8;
ground_time = linspace(0, 0.35, n_samples);

rng(5);
amps = [50 55 60 65 70 75];
overpressure = zeros(n_rows, n_samples);
for i = 1:n_rows
    overpressure(i, :) = amps(i) * sin(2 * pi * ground_time / 0.35) ...
                         + randn(1, n_samples) * 0.5;
end

d = mestra.Dataset();
d.addCategory('design', {'d0', 'd1', 'd2'});
d.addKey('area_1', 'design', [.10 .10 .15 .15 .20 .20], 'Units', 'm^2');
d.addKey('area_2', 'design', [.30 .30 .35 .35 .40 .40], 'Units', 'm^2');
d.addKey('mach', 'condition', [1.4 1.6 1.4 1.6 1.4 1.6], 'Units', '1');
d.addKey('altitude', 'condition', ...
         [12000 12000 14000 14000 16000 16000], 'Units', 'm');
d.addKey('design', 'group', int32([0 0 1 1 2 2]), 'Category', 'design');
d.generalisationGroup = 'design';

d.addScalar('loudness', [78 80 82 84 86 88], 'Units', 'dB');

d.addAxisSupport('s0', ground_time, 'Units', 's');
d.addNodeArray('s0', 'overpressure', overpressure, 'field', ...
               'Units', 'Pa', 'Dims', {'row', 'node'});

mestra.write(d, out);
fprintf('wrote %s\n', out);
r = mestra.validate(out);
fprintf('validate: valid=%d\n', r.valid);
for f = r.findings
    fprintf('    %s %s %s\n', f.id, f.path, f.message);
end
end
