function timeMestra(slot, r0, r1, varargin)
%TIMEMESTRA  Time the MATLAB reader on a list of files.
%
%   timeMestra(SLOT, R0, R1, FILE1, FILE2, ...)
%
%   Prints one line per file:
%
%     <file> open=<s> validate=<s> rows=<s> full=<s> rss=-
%
%   OPEN is mestra.open, the metadata open of section 29; VALIDATE is
%   mestra.validate; ROWS is readRows over the half-open row range
%   [R0, R1) given in the zero-based terms the other drivers use, and
%   FULL is readRows over every row. Each is timed three times and the
%   smallest is kept, unless the first attempt took more than five
%   seconds. R1 may be -1 for the file's row count. There is no peak
%   resident size here, so the column is a dash.

reps = 3;
long = 5.0;
if ischar(r0) || isstring(r0), r0 = str2double(r0); end
if ischar(r1) || isstring(r1), r1 = str2double(r1); end

% MATLAB loads a class and compiles a function the first time it is
% used, so run everything once, untimed, on the first file.
warm = varargin{1};
dw = mestra.open(warm);
mestra.validate(warm);
dw.readRows(slot, [1, 1]);
clear dw

for k = 1:numel(varargin)
    path = varargin{k};

    tOpen = bestOf(@() mestra.open(path), reps, long);
    tVal = bestOf(@() mestra.validate(path), reps, long);

    d = mestra.open(path);
    n = d.nRows;
    last = r1;
    if last < 0
        last = n;
    end
    tRows = bestOf(@() d.readRows(slot, [r0 + 1, last]), reps, long);
    tFull = bestOf(@() d.readRows(slot, [1, n]), reps, long);

    [~, name, ext] = fileparts(path);
    fprintf('%s%s open=%.4f validate=%.4f rows=%.4f full=%.4f rss=-\n', ...
            name, ext, tOpen, tVal, tRows, tFull);
end
end


function t = bestOf(fn, reps, long)
times = zeros(1, reps);
used = 0;
for i = 1:reps
    tic;
    fn();
    times(i) = toc;
    used = i;
    if times(i) > long
        break
    end
end
t = min(times(1:used));
end
