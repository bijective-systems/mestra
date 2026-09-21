classdef (Abstract) Callable
%mestra.Callable  The four-method callable protocol.
%
%   A callable maps keys in to predictions out.  Specification section
%   10 fixes it at four things and nothing more:
%
%       call       a keys table in, one prediction per output out
%       toDict     a nested dictionary that fully represents it
%       fromDict   the inverse, a static method dispatched on the type
%                  string through mestra.Registry
%       disp       optional, one line for printing
%
%   Everything else a callable knows is inside its dictionary and is
%   its own business.  The format does not constrain it.
%
%   The keys table is a MATLAB table whose variable names are the key
%   names (section 26).  call returns a containers.Map from the name
%   of an output to a prediction: a struct with the fields
%
%       mean         a mestra.Array shaped as the slot is stored, with
%                    the file's own axis order: (row, node | cell,
%                    component) for an array slot and (row) for a
%                    scalar slot
%       uncertainty  a band (section 9), the half-width of the
%                    interval around the mean, of the same shape, or
%                    [] when the model has none
%       level        the coverage the band claims, in (0, 1), or []
%       method       how the band was made, one sentence, or ''
%
%   Build one with mestra.Callable.prediction, which checks that the
%   three band fields come together and that the band is never
%   negative.  How the band was computed is the model's business; what
%   it claims is on the record.
%
%   To add a type, subclass this, implement the three methods, and
%   register it:
%
%       mestra.Registry.register('my_type', @MyType.fromDict);
%
%   See also mestra.Affine, mestra.Registry, mestra.evaluate,
%   mestra.prediction.

    methods (Abstract)
        % out = call(obj, keysTable)
        out = call(obj, keysTable)

        % d = toDict(obj)  -- a containers.Map, per the codec
        d = toDict(obj)
    end

    methods (Abstract, Static)
        % obj = fromDict(d)
        obj = fromDict(d)
    end

    methods
        function s = repr(obj) %#ok<MANU>
        %repr  One line describing the callable.  Optional; override it.
            s = '';
        end

        function t = type(obj)
        %type  The public type string, taken from the registry.
            t = mestra.Registry.typeOf(class(obj));
        end

        function disp(obj)
        %disp  One line naming the type and the description.
            r = obj.repr();
            if isempty(r)
                fprintf('  %s callable\n', obj.type());
            else
                fprintf('  %s\n', r);
            end
        end
    end

    methods (Static)
        function p = prediction(meanValue, uncertainty, level, method)
        %prediction  The record a callable returns for one output.
        %   P = mestra.Callable.prediction(MEAN) is a prediction with
        %   no band.  P = mestra.Callable.prediction(MEAN, UNCERTAINTY,
        %   LEVEL, METHOD) carries one: UNCERTAINTY is a mestra.Array
        %   of the mean's shape and never negative, LEVEL the coverage
        %   it claims in (0, 1), and METHOD one sentence on how it was
        %   made.  A band missing any of the three is refused here
        %   rather than in a file (section 10).
            if nargin < 2, uncertainty = []; end
            if nargin < 3, level = []; end
            if nargin < 4, method = ''; end
            if ~isa(meanValue, 'mestra.Array')
                error('mestra:prediction', ...
                      ['the mean of a prediction is a mestra.Array ' ...
                       'shaped as the slot is stored (section 10)']);
            end
            if isstring(method), method = char(method); end
            if isempty(uncertainty)
                if ~isempty(level) || ~isempty(method)
                    error('mestra:prediction', ...
                          ['level and method go with an uncertainty; a ' ...
                           'prediction without one has neither']);
                end
                p = struct('mean', meanValue, 'uncertainty', [], ...
                           'level', [], 'method', '');
                return
            end
            if ~isa(uncertainty, 'mestra.Array')
                error('mestra:prediction', ...
                      'the uncertainty of a prediction is a mestra.Array');
            end
            if ~isequal(uncertainty.shape, meanValue.shape)
                error('mestra:prediction', ...
                      ['a band has the shape of its mean; the mean is ' ...
                       '%s and the band %s'], mat2str(meanValue.shape), ...
                      mat2str(uncertainty.shape));
            end
            if isempty(level) || ~isnumeric(level) || ~isscalar(level) ...
                    || ~(level > 0 && level < 1)
                error('mestra:prediction', ...
                      ['a band states the coverage it claims as level in ' ...
                       '(0, 1); a 1.96-sigma Gaussian band is 0.95']);
            end
            if ~ischar(method) || isempty(method)
                error('mestra:prediction', ...
                      'a band says how it was made; give method one sentence');
            end
            if any(double(uncertainty.data(:)) < 0)
                error('mestra:prediction', ...
                      'a band is a half-width and is never negative');
            end
            p = struct('mean', meanValue, 'uncertainty', uncertainty, ...
                       'level', double(level), 'method', method);
        end
    end
end
