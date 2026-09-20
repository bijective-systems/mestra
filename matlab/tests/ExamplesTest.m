classdef ExamplesTest < matlab.unittest.TestCase
%ExamplesTest  Every docs/examples/<name>/matlab.m, run and compared
%   to the "Expected output" block of that directory's README.
%
%   The seven examples are the guide's worked examples, one per
%   concept, and the same small dataset in every language.  They are
%   run by every language's suite so that they cannot rot: an example
%   that stops printing what its README says it prints is a failure
%   here, whether the example changed or the package did.
%
%   Each one runs in a fresh temporary directory, because the
%   examples write their files into the working directory, and in a
%   fresh workspace, because a variable left over from another
%   example would make one pass that would not pass alone.
%
%   WHERE MATLAB CANNOT PRINT THE LINE.  Two of the four languages
%   print some lines differently, and the deviations below are the
%   whole list: a line that differs and is not listed is a failure,
%   and a listed deviation that no longer happens is a failure too,
%   so neither side of this can rot quietly.
%
%   See also CorpusTest, PostTest, run_tests.

    properties (TestParameter)
        example = ExamplesTest.examplesShown()
    end

    methods (Test)

        function printsWhatTheReadmeSays(testCase, example)
        %printsWhatTheReadmeSays  Run it, and compare it line by line.
            got = ExamplesTest.runExample(example);
            want = ExamplesTest.expectedOutput(example);
            allowed = ExamplesTest.deviations();
            allowed = allowed(strcmp({allowed.example}, example));
            testCase.verifyEqual(numel(got), numel(want), ...
                sprintf(['%s printed %d line(s) and its README expects ' ...
                         '%d:\n--- got ---\n%s\n--- want ---\n%s'], ...
                        example, numel(got), numel(want), ...
                        strjoin(got, newline), strjoin(want, newline)));
            if numel(got) ~= numel(want), return, end
            for i = 1:numel(want)
                if strcmp(got{i}, want{i}), continue, end
                hit = find(strcmp({allowed.expected}, want{i}) & ...
                           strcmp({allowed.actual}, got{i}), 1);
                testCase.verifyNotEmpty(hit, sprintf( ...
                    ['%s, line %d:\n  README: %s\n  MATLAB: %s\n' ...
                     'A line that differs is either a mistake or a ' ...
                     'deviation ExamplesTest.deviations names.'], ...
                    example, i, want{i}, got{i}));
            end
        end

        function everyExampleIsUnderThirtyLines(testCase, example)
        %everyExampleIsUnderThirtyLines  One example per concept, each
        %   under thirty lines, so that the concept is what the
        %   reader meets and not the code.
            text = fileread(fullfile(ExamplesTest.root(), example, ...
                                     'matlab.m'));
            lines = strsplit(text, newline);
            code = 0;
            for i = 1:numel(lines)
                one = strtrim(lines{i});
                if ~isempty(one) && one(1) ~= '%'
                    code = code + 1;
                end
            end
            testCase.verifyLessThan(code, 30, sprintf( ...
                '%s/matlab.m has %d lines of code', example, code));
        end

        function everyDeviationStillHappens(testCase)
        %everyDeviationStillHappens  A deviation that has been fixed,
        %   in this package or in the README it is measured against,
        %   must be struck out rather than left standing.
            allowed = ExamplesTest.deviations();
            for i = 1:numel(allowed)
                got = ExamplesTest.runExample(allowed(i).example);
                testCase.verifyTrue(any(strcmp(got, allowed(i).actual)), ...
                    sprintf(['%s no longer prints "%s"; strike this ' ...
                             'deviation out of ExamplesTest.deviations'], ...
                            allowed(i).example, allowed(i).actual));
            end
        end
    end

    methods (Static)

        function out = examplesShown()
        %examplesShown  The seven directories, in the guide's order.
        %   A struct and not a cell array, so that a test is named
        %   after the concept and not after an index.
            out = struct( ...
                'rowsAndRoles', 'rows-and-roles', ...
                'aSupportAndAField', 'a-support-and-a-field', ...
                'groupsAndSplits', 'groups-and-splits', ...
                'callablesAndEvaluation', 'callables-and-evaluation', ...
                'uncertaintyAsDraws', 'uncertainty-as-draws', ...
                'validating', 'validating', ...
                'readingSomeoneElsesFile', 'reading-someone-elses-file');
        end

        function out = root()
        %root  docs/examples, from here, as a relative walk.
            here = fileparts(mfilename('fullpath'));
            repo = fileparts(fileparts(here));
            out = fullfile(repo, 'docs', 'examples');
        end

        function out = deviations()
        %deviations  Every line a MATLAB example prints that its
        %   README does not, with the reason.  The list is closed:
        %   printsWhatTheReadmeSays fails on anything else.
            out = struct('example', {}, 'expected', {}, 'actual', {}, ...
                         'why', {});
            out(end + 1) = struct( ...
                'example', 'validating', ...
                'expected', ['refused: E11: cl: a scalar carries units; ' ...
                             'pass units= ("1" for a dimensionless one)'], ...
                'actual', ['refused: E11: /scalars/cl: a scalar requires ' ...
                           'units; give them as the third argument, "1" ' ...
                           'when it is dimensionless'], ...
                'why', ['section 6 of docs/api-conventions.md holds ' ...
                        'every language to the shape of a message and ' ...
                        'to Python''s wording for E04 and W01 alone; ' ...
                        'the builder messages name the argument of ' ...
                        'the language they are raised in']);
        end

        function lines = expectedOutput(example)
        %expectedOutput  The indented block under "Expected output" in
        %   that example's README, with the four spaces taken off.
            text = fileread(fullfile(ExamplesTest.root(), example, ...
                                     'README.md'));
            all = strsplit(text, newline);
            at = find(strcmp(strtrim(all), 'Expected output'), 1);
            if isempty(at)
                error('mestra:examples', ...
                      '%s/README.md has no "Expected output" heading', ...
                      example);
            end
            lines = {};
            for i = at + 2:numel(all)
                one = all{i};
                if isempty(strtrim(one))
                    if ~isempty(lines), break, end
                    continue
                end
                if ~strncmp(one, '    ', 4), break, end
                lines{end + 1} = one(5:end); %#ok<AGROW>
            end
            if isempty(lines)
                error('mestra:examples', ...
                      '%s/README.md expects no output', example);
            end
        end

        function lines = runExample(mestraExample__)
        %runExample  One matlab.m, in a fresh directory and a fresh
        %   workspace, with everything it printed split into lines.
        %
        %   The example is copied into a temporary tree of the same
        %   shape and run from there, because `run` makes the
        %   script's own folder the working directory and the
        %   examples write their files into the working directory:
        %   running the file where it lies would leave .mes files in
        %   the repository.  The tree is the same shape because
        %   reading-someone-elses-file reads ../mesh_two_rows.mes.
        %
        %   The local names are spelt the way they are because the
        %   script runs in this function's workspace and must not
        %   meet a variable of its own name here.
            mestraTemp__ = tempname();
            mkdir(fullfile(mestraTemp__, mestraExample__));
            copyfile(fullfile(ExamplesTest.root(), mestraExample__, ...
                              'matlab.m'), ...
                     fullfile(mestraTemp__, mestraExample__, 'matlab.m'));
            copyfile(fullfile(ExamplesTest.root(), 'mesh_two_rows.mes'), ...
                     fullfile(mestraTemp__, 'mesh_two_rows.mes'));
            mestraWhere__ = fullfile(mestraTemp__, mestraExample__, ...
                                     'matlab.m');
            mestraBack__ = pwd();
            mestraHome__ = onCleanup(@() ExamplesTest.leave( ...
                mestraBack__, mestraTemp__)); %#ok<NASGU>
            mestraText__ = evalc('run(mestraWhere__)');
            lines = strsplit(mestraText__, newline);
            while ~isempty(lines) && isempty(strtrim(lines{end}))
                lines(end) = [];
            end
        end

        function leave(back, temp)
        %leave  Back to where we were, and the copy and everything it
        %   wrote away with it.
            cd(back);
            try
                rmdir(temp, 's');
            catch
            end
        end
    end
end
