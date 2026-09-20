function cross_read(label, dir)
%CROSS_READ  Read another language's d1_family.mes, permute by name and
%   check the one deterministic value: instance 1, node 2, component 0
%   of the coordinates is 3.0.  Indices here are one based.

fprintf('##### d1_family written by %s #####\n', label);
d = mestra.read(fullfile(dir, 'd1_family.mes'));
fprintf('    %d rows\n', d.nRows);
fprintf('    keys: %s\n', strjoin(d.keyNames(), ', '));

c = d.support('s0').coordinates;
fprintf('    coordinates dims: %s\n', strjoin(c.dims, ', '));
p = mestra.permute(c.values, c.dims, {'group:member', 'node', 'component'});
fprintf('    permuted (group:member, node, component) size: %s\n', ...
        mat2str(size(p)));
fprintf('    value at instance 1, node 2, component 0 = %g\n', p(2, 3, 1));

e = d.nodeArray('s0', 'cad_edge_t');
fprintf('    cad_edge_t dims: %s\n', strjoin(e.dims, ', '));
q = mestra.permute(e.values, e.dims, {'node', 'component'});
fprintf('    cad_edge_t node 3 = %g\n', q(4, 1));

fprintf('    mach row 1 = %g\n', d.key('mach').values(2));
end
