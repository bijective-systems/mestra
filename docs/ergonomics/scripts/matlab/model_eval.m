function model_eval(path, out)
%MODEL_EVAL  Evaluate a Python-written callable file in MATLAB, exactly
%   as matlab/README.md spells it, and check 1.45 and the six pressures.

d = mestra.read(path);
t = table(0.5, 4.0, 'VariableNames', {'mach', 'alpha'});
e = mestra.evaluate(d, t);

cl = e.scalar('cl').values;
fprintf('    cl = %.17g\n', cl);

a = e.nodeArray('s0', 'pressure');
fprintf('    pressure dims: %s\n', strjoin(a.dims, ', '));
p = mestra.permute(a.values, a.dims, {'row', 'node', 'component'});
fprintf('    pressure =');
fprintf(' %g', p(1, :, 1));
fprintf('\n');

fprintf('    support id: %s\n', d.support('s0').supportId(1:16));
mestra.write(e, out);
fprintf('    wrote %s\n', out);
end
