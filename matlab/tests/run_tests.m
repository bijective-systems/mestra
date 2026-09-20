%RUN_TESTS  Run the whole test suite, corpus and all.
%
%   Headless, from a shell:
%
%     matlab -nodisplay -batch "addpath('<repo>/matlab'); \
%         run('<repo>/matlab/tests/run_tests.m')" < /dev/null
%
%   The script adds the package to the path itself, so the addpath
%   above is a convenience and not a requirement.  It prints the
%   counts, lists every failure, and exits non-zero when anything
%   failed, which is what a continuous integration job needs.
%
%   See also CorpusTest, PackageTest.

here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));      % the +mestra package
addpath(here);                 % the tests and their helpers

import matlab.unittest.TestSuite
import matlab.unittest.TestRunner
import matlab.unittest.plugins.TestRunProgressPlugin

suite = [TestSuite.fromClass(?CorpusTest), ...
         TestSuite.fromClass(?PackageTest), ...
         TestSuite.fromClass(?ConventionsTest), ...
         TestSuite.fromClass(?PostTest), ...
         TestSuite.fromClass(?ExamplesTest), ...
         TestSuite.fromClass(?HostileTest), ...
         TestSuite.fromClass(?HostileSubsetTest)];

runner = TestRunner.withNoPlugins();
runner.addPlugin(TestRunProgressPlugin.withVerbosity(1));
result = runner.run(suite);

passed = sum([result.Passed]);
failed = sum([result.Failed]);
incomplete = sum([result.Incomplete]);

counts = CorpusTest.coverage();
fprintf('\n');
fprintf('cases in the corpus : %d (%d of them valid)\n', ...
        counts.cases, counts.valid);
fprintf('probes compared     : %d (%d instance, %d draw, %d cell axis)\n', ...
        counts.probes, counts.instanceProbes, counts.drawProbes, ...
        counts.cellProbes);
fprintf('support ids         : %d\n', counts.supportIds);
fprintf('codec round trips   : %d\n', counts.dictionaries);
fprintf('evaluation probes   : %d\n', counts.evaluationProbes);
fprintf('read-write-compare  : %d\n', counts.valid);
fprintf('hostile files       : %d own, %d shared subset\n', ...
        numel(HostileTest.allCases()), numel(HostileSubsetTest.allCases()));
fprintf('conventions checks  : %d\n', ...
        numel(TestSuite.fromClass(?ConventionsTest)));
fprintf('post-processing     : %d\n', ...
        numel(TestSuite.fromClass(?PostTest)));
fprintf('worked examples     : %d\n', ...
        numel(fieldnames(ExamplesTest.examplesShown())));
fprintf('tests run           : %d\n', numel(result));
fprintf('passed              : %d\n', passed);
fprintf('failed              : %d\n', failed);
fprintf('incomplete          : %d\n', incomplete);
fprintf('total time          : %.1f s\n', sum([result.Duration]));

if failed > 0 || incomplete > 0
    fprintf('\nfailures:\n');
    for i = 1:numel(result)
        if result(i).Failed || result(i).Incomplete
            fprintf('  %s\n', result(i).Name);
        end
    end
    disp(table(result));
    exit(1);
end
fprintf('\nall tests passed\n');
