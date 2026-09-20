classdef Registry
%mestra.Registry  Callable types, keyed by the public type string.
%
%   A file names a callable's type in a string attribute so that a
%   reader knows which tool can evaluate it (specification section
%   10).  The registry turns that string into a MATLAB object.  A
%   reader that does not know a type keeps the dictionary unchanged
%   and must not interpret it, which is what mestra.read does.
%
%   The one type this package defines is `affine` (section 27).
%
%   Usage
%
%       mestra.Registry.register('my_type', @MyType.fromDict, 'MyType');
%       types = mestra.Registry.types();
%       obj   = mestra.Registry.create('affine', dict);
%
%   See also mestra.Callable, mestra.Affine.

    methods (Static)

        function register(type, fromDict, className)
        %register  Add or replace a callable type.
        %   `fromDict` takes a dictionary and returns a
        %   mestra.Callable.  `className` is the MATLAB class, used
        %   only so that an object can name its own type.
            if nargin < 3, className = ''; end
            map = mestra.Registry.store();
            entry = struct('fromDict', fromDict, 'class', className);
            map(type) = entry; %#ok<NASGU>
        end

        function tf = isKnown(type)
        %isKnown  True when a type has been registered.
            map = mestra.Registry.store();
            tf = map.isKey(type);
        end

        function out = types()
        %types  Every registered type string.
            map = mestra.Registry.store();
            out = map.keys();
        end

        function obj = create(type, dict)
        %create  Build a callable from its type and its dictionary.
            map = mestra.Registry.store();
            if ~map.isKey(type)
                error('mestra:unknownCallable', ...
                      ['no callable type "%s" is registered; the ' ...
                       'dictionary is kept unchanged'], type);
            end
            entry = map(type);
            obj = entry.fromDict(dict);
        end

        function t = typeOf(className)
        %typeOf  The type string a MATLAB class was registered under.
            map = mestra.Registry.store();
            t = '';
            for key = map.keys()
                entry = map(key{1});
                if strcmp(entry.class, className)
                    t = key{1};
                    return
                end
            end
        end

        function map = store()
        %store  The registry itself, built on first use.
            persistent registry
            if isempty(registry)
                registry = containers.Map('KeyType', 'char', ...
                                          'ValueType', 'any');
                registry('affine') = struct( ...
                    'fromDict', @mestra.Affine.fromDict, ...
                    'class', 'mestra.Affine');
            end
            map = registry;
        end
    end
end
