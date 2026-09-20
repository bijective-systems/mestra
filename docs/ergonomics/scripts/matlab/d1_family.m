function d1_family(out)
%D1_FAMILY  Dataset 1, the parametric family, built from matlab/README.md.
%   Three members, two conditions, six rows, a six-node mesh of two
%   quadrilaterals with each member's own coordinates.

d = mestra.Dataset();
d.addCategory('member', {'cone_a', 'cone_b', 'cone_c'});
d.addCategory('status', {'converged', 'failed'});

d.addKey('total_length', 'design', [2 2 3 3 4 4], 'Units', 'm');
d.addKey('half_angle', 'design', [10 10 15 15 20 20], 'Units', 'degree');
d.addKey('nose_radius', 'design', [.05 .05 .08 .08 .11 .11], 'Units', 'm');
d.addKey('mach', 'condition', [.5 .8 .5 .8 .5 .8], 'Units', '1');
d.addKey('altitude', 'condition', [1000 1000 5000 5000 9000 9000], ...
         'Units', 'm');
d.addKey('member', 'group', int32([0 0 1 1 2 2]), 'Category', 'member');
d.addKey('status', 'status', int32([0 0 0 0 0 1]), 'Category', 'status');
d.generalisationGroup = 'member';

% (component, node) per member, then stacked along the third axis
base = [0 1 2 0 1 2; 0 0 0 1 1 1; 0 0 0 0 0 0];
coords = cat(3, base .* [1; 1; 1], base .* [1.5; 1; 1], base .* [2; 1; 1]);

d.addMeshSupport('s0', coords, uint8([9 9]), int64([0 4 8]), ...
                 int64([0 1 4 3 1 2 5 4]), 'Units', 'm', ...
                 'Varies', 'group:member', ...
                 'Dims', {'component', 'node', 'group:member'});

rng(0);
pressure = 1000 + rand(6, 6) * 10;
heat_flux = 500 + rand(6, 6) * 10;

d.addNodeArray('s0', 'pressure', pressure, 'field', 'Units', 'Pa', ...
               'Dims', {'row', 'node'});
d.addNodeArray('s0', 'heat_flux', heat_flux, 'field', 'Units', 'W/m^2', ...
               'Dims', {'row', 'node'});
% attempt 2: Dims {'node'} was refused with "the array has 2 axes and 1
% names".  MATLAB has no one-dimensional array, so a plain row vector is
% 1-by-N and the leading singleton has to be named 'component' by hand.
% attempt 3: attempt 2 WROTE A FILE ITS OWN VALIDATOR REJECTS (E16 on
% all three), because Dims without a 'row' name still defaults Varies to
% 'row'.  'Varies','none' has to be said as well, and write() never
% checked.
d.addNodeArray('s0', 'cad_edge_t', linspace(0, 1, 6), 'field', ...
               'Units', '1', 'Dims', {'component', 'node'}, ...
               'Varies', 'none');
d.addNodeArray('s0', 'cad_face_id', int32([11 11 12 12 13 13]), 'label', ...
               'Dims', {'component', 'node'}, 'Varies', 'none');
d.addCellArray('s0', 'topo_face_id', int32([1 2]), 'label', ...
               'Dims', {'component', 'cell'}, 'Varies', 'none');

mestra.write(d, out);
fprintf('wrote %s\n', out);
r = mestra.validate(out);
fprintf('validate: valid=%d\n', r.valid);
for f = r.findings
    fprintf('    %s %s %s\n', f.id, f.path, f.message);
end
end
