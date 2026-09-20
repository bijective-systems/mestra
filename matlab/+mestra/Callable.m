classdef (Abstract) Callable
%mestra.Callable  The four-method callable protocol.
%
%   A callable maps keys in to values out.  Specification section 10
%   fixes it at four things and nothing more:
%
%       call       a keys table in, the values of the slots it serves
%                  out, shaped as those slots would be stored
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
%   of an output to a mestra.Array holding that output for every row
%   of the table, with the file's own axis order:
%   (row, node | cell, component) for an array slot and (row) for a
%   scalar slot.
%
%   To add a type, subclass this, implement the three methods, and
%   register it:
%
%       mestra.Registry.register('my_type', @MyType.fromDict);
%
%   See also mestra.Affine, mestra.Registry, mestra.evaluate.

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
end
