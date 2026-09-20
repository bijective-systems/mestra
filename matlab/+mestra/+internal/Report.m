classdef Report < handle
%Report  What a validation run found, by rule identifier.
%
%   Every finding carries an identifier, the HDF5 path it was found
%   at, and one line of plain language.  The identifier lists come
%   back sorted and without duplicates, which is the form the
%   conformance corpus compares against.
%
%   An identifier beginning with E or W is a rule of specification
%   section 14.  One beginning with U is this reader's own, for
%   something section 14 has no rule for: an object that would not
%   read (U01), a link this reader does not follow (U02), or a limit
%   of this reader (U03).  Those are kept in their own list so that
%   they can never be mistaken for a rule of the specification.
%
%   See also mestra.validate.

    properties
        findings = struct('id', {}, 'path', {}, 'message', {})
    end

    methods
        function add(obj, id, path, varargin)
        %add  Record one finding.  Extra arguments go to sprintf.
        %
        %   One finding per rule per object (docs/api-conventions.md,
        %   section 5): a rule that has already fired at this path
        %   does not fire again, so a report has one line per thing
        %   that is wrong and not one line per way of noticing it.
            if isempty(varargin)
                msg = '';
            else
                msg = sprintf(varargin{:});
            end
            if obj.hasAt(id, path)
                return
            end
            obj.findings(end + 1) = struct('id', id, 'path', path, ...
                                           'message', msg);
        end

        function tf = hasAt(obj, id, path)
        %hasAt  True when that rule has already fired at that path.
            tf = false;
            for i = 1:numel(obj.findings)
                if strcmp(obj.findings(i).id, id) && ...
                        strcmp(obj.findings(i).path, path)
                    tf = true;
                    return
                end
            end
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

        function out = unclassified(obj)
        %unclassified  This reader's own identifiers, sorted, unique.
            out = obj.byKind('U');
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
            s.unclassified = obj.unclassified();
            s.findings = obj.findings;
            s.valid = isempty(s.errors);
        end
    end

    methods (Static)

        function s = someRows(idx, total)
        %someRows  How a per-row rule says how much and where.
        %
        %   W02, W03 and W04 could each fire once per row, and
        %   docs/api-conventions.md section 5 has them fire once with
        %   the count and the first three row indices instead, so that
        %   a report on a file of 1,800 rows is still a report.  The
        %   indices are the file's, counted from 0.
            idx = reshape(double(idx), 1, []);
            n = numel(idx);
            if n == 0
                s = '';
                return
            end
            show = idx(1:min(3, n));
            bits = strjoin(arrayfun(@(v) sprintf('%d', v), show, ...
                                    'UniformOutput', false), ', ');
            if n == 1
                where = sprintf('row %s', bits);
            elseif n > 3
                where = sprintf('rows %s and %d more', bits, n - 3);
            else
                where = sprintf('rows %s', bits);
            end
            if nargin >= 2 && ~isempty(total)
                s = sprintf('%d of %d %s', n, total, where);
            else
                s = sprintf('%d %s', n, where);
            end
        end

        function s = countOf(idx, total, what)
        %countOf  "2 of 6 rows (rows 1, 4)" for a per-row rule.
            s = sprintf('%s: %s', what, ...
                        mestra.internal.Report.someRows(idx, total));
        end
    end
end
