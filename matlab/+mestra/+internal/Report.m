classdef Report < handle
%Report  What a validation run found, by rule identifier.
%
%   Every finding carries the rule id of specification section 14, the
%   HDF5 path it was found at, and one line of plain language.  The
%   identifier lists come back sorted and without duplicates, which is
%   the form the conformance corpus compares against.
%
%   See also mestra.validate.

    properties
        findings = struct('id', {}, 'path', {}, 'message', {})
    end

    methods
        function add(obj, id, path, varargin)
        %add  Record one finding.  Extra arguments go to sprintf.
            if isempty(varargin)
                msg = '';
            else
                msg = sprintf(varargin{:});
            end
            obj.findings(end + 1) = struct('id', id, 'path', path, ...
                                           'message', msg);
        end

        function tf = has(obj, id)
        %has  True when that rule has already fired.
            tf = any(strcmp({obj.findings.id}, id));
        end

        function out = errors(obj)
        %errors  The error identifiers, sorted and unique.
            out = obj.byKind('E');
        end

        function out = warnings(obj)
        %warnings  The warning identifiers, sorted and unique.
            out = obj.byKind('W');
        end

        function out = byKind(obj, letter)
            ids = {obj.findings.id};
            keep = false(1, numel(ids));
            for i = 1:numel(ids)
                keep(i) = ~isempty(ids{i}) && ids{i}(1) == letter;
            end
            out = unique(ids(keep));
            out = out(:)';
            if isempty(out), out = {}; end
        end

        function s = result(obj)
        %result  The struct mestra.validate returns.
            s.errors = obj.errors();
            s.warnings = obj.warnings();
            s.findings = obj.findings;
            s.valid = isempty(s.errors);
        end
    end
end
