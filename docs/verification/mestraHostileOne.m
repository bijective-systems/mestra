function mestraHostileOne(path)
%MESTRAHOSTILEONE  Drive the three entry points over one hostile file.
%
%   Printed in a form the Phase 3 hostile runner parses: one line per
%   entry point saying what happened, then one giving the seconds it
%   took.  MATLAB pays about twenty seconds of start-up, so all three
%   run in one process and the outer timeout is what catches a hang.

for what = {'validate', 'info', 'read'}
    t0 = tic;
    try
        switch what{1}
            case 'validate'
                r = mestra.validate(path);
                ids = [reshape(r.errors, 1, []), reshape(r.warnings, 1, [])];
                fprintf('%s OK %s\n', what{1}, strjoin(ids, ' '));
            case 'info'
                d = mestra.open(path);
                fprintf('%s OK rows=%d\n', what{1}, d.nRows);
            case 'read'
                d = mestra.read(path);
                fprintf('%s OK rows=%d\n', what{1}, d.nRows);
        end
    catch err
        fprintf('%s REFUSED %s %s\n', what{1}, err.identifier, ...
                strrep(err.message, newline, ' '));
    end
    fprintf('%s seconds %.2f\n', what{1}, toc(t0));
end
end
