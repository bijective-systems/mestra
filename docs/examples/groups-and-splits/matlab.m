% Groups and splits: whole members move together, never single rows.
% See README.md in this directory for the data and the output.
d = mestra.Dataset();
d.writer = 'mestra examples 1';
d.addKey('mach', [0.4 0.8 0.4 0.8 0.4 0.8], 'condition', '1');
d.addCategoryTable('member', {'wing_a', 'wing_b', 'wing_c'});
d.addKey('member', int32([0 0 1 1 2 2]), 'group', 'Category', 'member');
d.setGeneralisationGroup('member');
d.addScalar('cl', [0.21 0.25 0.30 0.36 0.41 0.48], '1');
d.addCategoryTable('split', {'train', 'test'});
d.addKey('split', int32([0 0 0 1 1 1]), 'split', 'Category', 'split');
mestra.write(d, 'family.mes');

r = mestra.read('family.mes');
names = r.category('member').entries;
member = double(r.key('member').values);
side = double(r.key('split').values);
quoted = @(c) ['[''' strjoin(c, ''', ''') ''']'];
leaks = {};
for u = unique(member)
    if numel(unique(side(member == u))) > 1, leaks{end + 1} = names{u + 1}; end
end
fprintf('unit of generalisation: %s\n', r.generalisationGroup);
fprintf('the split in the file leaks: %s\n', quoted(leaks));
parts = mestra.groupedSplit(r, struct('train', 0.67, 'test', 0.33), 'Seed', 0);
for part = {'train', 'test'}
    rows = parts.(part{1});
    fprintf('%s rows [%s] members %s\n', part{1}, ...
            strjoin(compose('%d', rows - 1), ', '), ...
            quoted(unique(names(member(rows) + 1))));
end
