% Rows and roles: six rows of a three-member family, no support.
% See README.md in this directory for the data and the output.
d = mestra.Dataset();
d.writer = 'mestra examples 1';
d.addKey('mach', [0.4 0.8 0.4 0.8 0.4 0.8], 'condition', '1');
d.addCategoryTable('member', {'wing_a', 'wing_b', 'wing_c'});
d.addKey('member', int32([0 0 1 1 2 2]), 'group', 'Category', 'member');
d.setGeneralisationGroup('member');
d.addScalar('cl', [0.21 0.25 0.30 0.36 0.41 0.48], '1');
mestra.write(d, 'family.mes');

r = mestra.read('family.mes');
names = r.keyNames();
fprintf('%d rows, %d keys\n', r.nRows, numel(names));
for i = 1:numel(names)
    k = r.key(names{i});
    what = k.units;
    if isempty(what), what = k.category; end
    fprintf('%s %s %s\n', k.name, k.role, what);
end
fprintf('generalisation unit: %s\n', r.generalisationGroup);
% Rows count from 0 in the file and from 1 in MATLAB, so row 3 is the
% fourth element.
fprintf('cl at row 3: %g\n', r.scalar('cl').values(3 + 1));
fprintf('cl units: %s\n', r.scalar('cl').units);
