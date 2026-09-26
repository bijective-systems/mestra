function publishFile(source, target)
%publishFile  Publish a closed sibling file without deleting the target.
%   ATOMIC_MOVE either replaces the directory entry or fails. Do not
%   fall back to movefile: a non-atomic move has no failure-preservation
%   contract. See java.nio.file.Files.move's ATOMIC_MOVE documentation.
    if ~usejava('jvm')
        error('mestra:write', ...
              'checked writes require the JVM for atomic file replacement');
    end
    options = javaArray('java.nio.file.CopyOption', 1);
    options(1) = java.nio.file.StandardCopyOption.ATOMIC_MOVE;
    from = java.io.File(char(source));
    to = java.io.File(char(target));
    try
        java.nio.file.Files.move(from.toPath(), to.toPath(), options);
    catch cause
        problem = MException('mestra:write', ...
            'could not atomically publish the file at %s: %s', target, cause.message);
        throw(addCause(problem, cause));
    end
end
