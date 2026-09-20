function d3_scalars(out)
%D3_SCALARS  Dataset 3, scalars only, no support at all.

geom = int32([0 0 0 0 1 1 1 1 2 2 2 2]);
inc = [0 4 8 12 0 4 8 12 0 4 8 12];
camber = 0.02 + 0.01 * double(geom);
thickness = 0.10 + 0.02 * double(geom);

d = mestra.Dataset();
d.addCategory('geometry', {'g0', 'g1', 'g2'});
d.addKey('camber', 'design', camber, 'Units', '1');
d.addKey('thickness', 'design', thickness, 'Units', '1');
d.addKey('incidence', 'condition', inc, 'Units', 'degree');
d.addKey('geometry', 'group', geom, 'Category', 'geometry');
d.generalisationGroup = 'geometry';

rng(3);
d.addScalar('CL', 0.1 * inc + rand(1, 12) * 0.01, 'Units', '1');
d.addScalar('CD', 0.01 + 0.0005 * inc .^ 2, 'Units', '1');
d.addScalar('CM', -0.05 - 0.001 * inc, 'Units', '1');

mestra.write(d, out);
fprintf('wrote %s\n', out);
r = mestra.validate(out);
fprintf('validate: valid=%d\n', r.valid);
for f = r.findings
    fprintf('    %s %s %s\n', f.id, f.path, f.message);
end
end
