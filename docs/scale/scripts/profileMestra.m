function profileMestra(op, path, top)
%PROFILEMESTRA  Where the MATLAB reader spends the time.
%
%   profileMestra(OP, PATH, TOP)
%
%   OP is 'open' or 'validate'. Runs it once to load the classes, then
%   once more under the MATLAB profiler, and prints the TOP functions
%   by total time with their call counts beside them, which is what
%   says whether a function runs once per dataset or once per dataset
%   per dataset.

if nargin < 3
    top = 12;
elseif ischar(top) || isstring(top)
    top = str2double(top);
end

run_once(op, path);
profile('off');
profile('clear');
profile('on');
run_once(op, path);
profile('off');
info = profile('info');

[~, order] = sort([info.FunctionTable.TotalTime], 'descend');
fprintf('%-42s %10s %10s\n', 'function', 'seconds', 'calls');
for i = 1:min(top, numel(order))
    f = info.FunctionTable(order(i));
    name = f.FunctionName;
    if numel(name) > 42
        name = name(1:42);
    end
    fprintf('%-42s %10.3f %10d\n', name, f.TotalTime, f.NumCalls);
end
end


function run_once(op, path)
switch op
    case 'open'
        mestra.open(path);
    case 'validate'
        mestra.validate(path);
    otherwise
        error('open or validate');
end
end
