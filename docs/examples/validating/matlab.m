% Validating: a mistake refused while building, and a warning that is
% reported but does not stop a file. See README.md for the output.
cl = [0.21 0.25 0.30 0.36 0.41 0.48];
d = mestra.Dataset();
d.writer = 'mestra examples 1';
d.addKey('mach', [0.4 0.8 0.4 0.8 0.4 0.8], 'condition', '1');
d.addCategoryTable('member', {'wing_a', 'wing_b', 'wing_c'});
d.addKey('member', int32([0 0 1 1 2 2]), 'group', 'Category', 'member');
d.setGeneralisationGroup('member');
try
    d.addScalar('cl', cl);
catch refusal
    fprintf('refused: %s\n', refusal.message);
end
d.addScalar('cl', cl, '1');
d.addCategoryTable('split', {'train', 'test'});
d.addKey('split', int32([0 0 0 1 1 1]), 'split', 'Category', 'split');
mestra.write(d, 'family.mes');

report = mestra.validate('family.mes');
yes = {'False', 'True'};
quoted = @(c) strjoin(cellfun(@(s) ['''' s ''''], c, ...
                              'UniformOutput', false), ', ');
fprintf('ok: %s\n', yes{report.valid + 1});
fprintf('errors: [%s] warnings: [%s]\n', quoted(report.errors), ...
        quoted(report.warnings));
for finding = report.findings
    fprintf('%s %s: %s\n', finding.id, finding.path, finding.message);
end
