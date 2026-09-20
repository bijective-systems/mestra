function [cases, manifest] = corpusRoot()
%CORPUSROOT  Where the conformance corpus lives, from here.
%
%   [CASES, MANIFEST] = CORPUSROOT() returns the vectors/cases
%   directory and the path of vectors/manifest.json.  The corpus sits
%   beside the matlab directory in the same repository, so this is a
%   relative walk and never a machine path.
%
%   See also CorpusTest, run_tests.

    here = fileparts(mfilename('fullpath'));
    root = fileparts(fileparts(here));      % matlab/tests -> matlab -> .
    cases = fullfile(root, 'vectors', 'cases');
    manifest = fullfile(root, 'vectors', 'manifest.json');
    if exist(cases, 'dir') ~= 7
        error('mestra:corpus', ...
              'the conformance corpus is not at %s', cases);
    end
end
