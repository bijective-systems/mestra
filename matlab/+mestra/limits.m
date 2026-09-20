function previous = limits(varargin)
%MESTRA.LIMITS  Read or change what the reader refuses to do.
%
%   S = MESTRA.LIMITS() returns the current limits as a struct.
%
%   OLD = MESTRA.LIMITS(NAME, VALUE) changes one limit and returns the
%   whole set as it was, so it can be put back.
%
%   MESTRA.LIMITS(OLD) restores a set returned earlier.
%
%   MESTRA.LIMITS('reset') puts every limit back to its default.
%
%   A file is untrusted input: its declared shapes, its nesting and
%   its string sizes are numbers someone else chose. These are the
%   numbers this package will not go past, whatever a file asks for.
%
%       maxElements    2147483648 elements in one eager read, which is
%                                 the 2^31 specification section 29
%                                 says a reader should state
%       maxDepth       64         levels of group nesting a walk
%                                 follows
%       maxObjects     200000     objects a walk visits in one file
%       maxStringSize  65536      bytes in one fixed-length string
%
%   Going past one raises mestra:E41 in MESTRA.READ, MESTRA.OPEN and
%   the dataset's readRows method, and is the error E41 in
%   MESTRA.VALIDATE, which carries on with the rest of the file.
%   maxElements is the exception: it is the cap on one eager read, so
%   MESTRA.OPEN meets it only on a category table, which it reads, and
%   not on a slot or a dictionary dataset, which it does not.
%
%   Example
%
%       old = mestra.limits('maxElements', 2^31);
%       d = mestra.read('genuinely_enormous.mes');
%       mestra.limits(old);
%
%   See also mestra.read, mestra.open, mestra.validate.

    if nargin == 0
        previous = mestra.internal.Limits.get();
        return
    end
    if nargin == 1 && ischar(varargin{1}) && strcmp(varargin{1}, 'reset')
        previous = mestra.internal.Limits.get();
        mestra.internal.Limits.reset();
        return
    end
    if nargin == 1 && isstruct(varargin{1})
        previous = mestra.internal.Limits.get();
        names = fieldnames(varargin{1});
        for i = 1:numel(names)
            mestra.internal.Limits.set(names{i}, varargin{1}.(names{i}));
        end
        return
    end
    if mod(nargin, 2) ~= 0
        error('mestra:limits', ...
              'give a name and a value, a struct, or nothing at all');
    end
    previous = mestra.internal.Limits.get();
    for i = 1:2:nargin
        mestra.internal.Limits.set(varargin{i}, varargin{i + 1});
    end
end
