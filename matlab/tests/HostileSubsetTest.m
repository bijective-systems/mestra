classdef HostileSubsetTest < matlab.unittest.TestCase
%HostileSubsetTest  The corpus's own hostile subset, vectors/hostile.
%
%   Specification section 30 adds a second subset beside the cases: a
%   set of files that are malformed on purpose, with a contract that
%   is deliberately looser than the corpus's.  For each file,
%   expected.json gives
%
%       required_errors   the rule ids that must appear
%       allow_extra       true throughout: more may be reported
%       timeout_seconds   10
%
%   A validator must report at least the required ids and exit cleanly
%   inside the timeout: not crash, not hang, not exhaust memory, and
%   not stop at the first bad object.  Opening the file for its
%   metadata alone, and any operation that reads a slot, must refuse
%   with the same ids rather than return something.
%
%   Two of the fifteen files are thirty-one megabytes of nested groups
%   and are generated rather than committed.  Run
%
%       python vectors/generate.py --hostile-deep
%
%   before this suite; without them those two cases are skipped and
%   say so, rather than failing for a reason that is not the reader's.
%
%   This is the shared subset.  HostileTest is this package's own,
%   which goes further in places; both are run.
%
%   See also HostileTest, mestra.validate, mestra.limits.

    properties (TestParameter)
        subsetCase
    end

    methods (TestParameterDefinition, Static)
        function subsetCase = initialiseCases()
            subsetCase = HostileSubsetTest.allCases();
        end
    end

    methods (Static)

        function dir_ = subsetDir()
            here = fileparts(mfilename('fullpath'));
            root = fileparts(fileparts(here));
            dir_ = fullfile(root, 'vectors', 'hostile');
        end

        function names = allCases()
            names = {};
            base = HostileSubsetTest.subsetDir();
            if exist(base, 'dir') ~= 7, return, end
            listing = dir(base);
            for i = 1:numel(listing)
                n = listing(i).name;
                if n(1) == '.' || ~listing(i).isdir, continue, end
                if exist(fullfile(base, n, 'expected.json'), 'file') ~= 2
                    continue
                end
                names{end + 1} = n; %#ok<AGROW>
            end
            names = sort(names);
        end

        function e = expected(name)
            text = fileread(fullfile(HostileSubsetTest.subsetDir(), name, ...
                                     'expected.json'));
            e = jsondecode(text);
        end

        function p = caseFile(name)
            p = fullfile(HostileSubsetTest.subsetDir(), name, 'case.mes');
        end

        function out = asCellstr(v)
            if isempty(v)
                out = {};
            elseif ischar(v)
                out = {v};
            else
                out = reshape(cellstr(string(v)), 1, []);
            end
        end

        function names = generated()
        %generated  The cases that are made on demand, not committed.
            names = {'deep_groups_callables', 'deep_groups_keys'};
        end
    end

    methods (Test)

        function validatorReportsTheRequiredRules(testCase, subsetCase)
        %validatorReportsTheRequiredRules  At least, and in time.
            path = HostileSubsetTest.caseFile(subsetCase);
            testCase.assumeEqual(exist(path, 'file'), 2, ...
                sprintf(['%s is generated on demand; run ' ...
                         'vectors/generate.py --hostile-deep'], subsetCase));
            e = HostileSubsetTest.expected(subsetCase);
            required = HostileSubsetTest.asCellstr(e.required_errors);

            started = tic;
            outcome = mestra.validate(path);
            elapsed = toc(started);

            testCase.verifyLessThan(elapsed, e.timeout_seconds, ...
                sprintf('%s took %.1f s, past the %d s the subset allows', ...
                        subsetCase, elapsed, e.timeout_seconds));
            missing = setdiff(required, outcome.errors);
            testCase.verifyEmpty(missing, ...
                sprintf('%s: %s was required and not reported; got [%s]', ...
                        subsetCase, strjoin(missing, ', '), ...
                        strjoin(outcome.errors, ',')));
            testCase.verifyTrue(e.allow_extra, ...
                'this subset allows extra identifiers throughout');
            for i = 1:numel(outcome.findings)
                testCase.verifyNotEmpty(outcome.findings(i).path, ...
                    'every finding carries the path it was found at');
            end
        end

        function readAndOpenRefuseWithTheSameRules(testCase, subsetCase)
        %readAndOpenRefuseWithTheSameRules  No half-read file.
        %   A reader must refuse rather than return something.  The
        %   one exception the specification itself names is a dataset
        %   above the maximum element count: section 29 says a lazy
        %   read is not subject to it, so opening such a file for its
        %   metadata alone is allowed to succeed.
            path = HostileSubsetTest.caseFile(subsetCase);
            testCase.assumeEqual(exist(path, 'file'), 2, ...
                sprintf('%s is generated on demand', subsetCase));
            e = HostileSubsetTest.expected(subsetCase);
            required = HostileSubsetTest.asCellstr(e.required_errors);

            started = tic;
            readId = HostileSubsetTest.refusal(@() mestra.read(path));
            openId = HostileSubsetTest.refusal(@() mestra.open(path));
            testCase.verifyLessThan(toc(started), e.timeout_seconds);

            testCase.verifyNotEmpty(readId, ...
                sprintf('%s: an eager read must refuse it', subsetCase));
            testCase.verifyTrue(HostileSubsetTest.agrees(readId, required), ...
                sprintf('%s: read refused with %s where %s was required', ...
                        subsetCase, readId, strjoin(required, ',')));

            lazyOnly = isequal(required, {'E16'});
            if isempty(openId)
                testCase.verifyTrue(lazyOnly, ...
                    sprintf(['%s: opening returned; only a file whose ' ...
                             'fault is a length no lazy read touches ' ...
                             'may do that'], subsetCase));
            else
                testCase.verifyTrue( ...
                    HostileSubsetTest.agrees(openId, required), ...
                    sprintf('%s: open refused with %s', subsetCase, openId));
            end
        end

        function everySubsetCaseIsPresent(testCase)
        %everySubsetCaseIsPresent  The generated ones are named, not lost.
            names = HostileSubsetTest.allCases();
            testCase.verifyGreaterThanOrEqual(numel(names), 15, ...
                'the subset has fifteen cases');
            for name = HostileSubsetTest.generated()
                testCase.verifyTrue(ismember(name{1}, names), ...
                    sprintf('%s must at least have its expected.json', ...
                            name{1}));
            end
        end
    end

    methods (Static)

        function id = refusal(fn)
        %refusal  The identifier a call refused with, or '' if it did not.
            id = '';
            try
                fn();
            catch err
                id = err.identifier;
            end
        end

        function tf = agrees(id, required)
        %agrees  Whether a refusal names a rule it may name.
        %   One of the required ids, or E40 or E41, which section 14
        %   defines for exactly this: a link a reader will not follow
        %   and an object it could not read.  The subset's own
        %   huge_unwritten_dataset says so outright, requiring E16 of
        %   the validator and calling the eager read E41.
        %   mestra:reader is accepted for a file that will not open at
        %   all, which section 30 calls a clean exit.
            tf = any(strcmp(id, {'mestra:reader', 'mestra:E40', ...
                                 'mestra:E41'}));
            if tf, return, end
            for i = 1:numel(required)
                if strcmp(id, ['mestra:' required{i}])
                    tf = true;
                    return
                end
            end
        end
    end
end
