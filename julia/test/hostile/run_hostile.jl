# Put one hostile file through the reader, the validator, a lazy row
# read and support_id, and print one line saying what happened.
#
# This runs in a process of its own, started by the test suite with a
# wall-clock limit, because a test that is meant to catch a hang
# cannot catch it from inside the process that is hanging.  The line
# format is
#
#     <name>|<ok|fail>|<seconds>|<errors>|<warnings>|<note>
#
# and a file the parent never sees a line for is one that hung.

using Mestra

const ALLOWED_RULES = ("E01", "E40", "E41")

"""What one call did: a value, or the rule of the MestraError it threw.
Anything else at all is a failure, and is reported as one."""
function attempt(what::AbstractString, fn)
    try
        return (:ok, fn(), "")
    catch e
        if e isa Mestra.MestraError
            rule = e.rule
            if rule === nothing || rule in ALLOWED_RULES
                return (:refused, nothing, "$(what): $(something(rule, "-"))")
            end
            return (:bad, nothing,
                    "$(what): MestraError with rule $(rule), which is not " *
                    "one this reader may refuse a file with")
        end
        return (:bad, nothing,
                "$(what): $(typeof(e)) rather than a MestraError: " *
                first(sprint(showerror, e), 160))
    end
end

function check(path::AbstractString)
    notes = String[]
    bad = false

    st, report, note = attempt("validate", () -> Mestra.validate(path))
    isempty(note) || push!(notes, note)
    st === :bad && (bad = true)
    errors = report === nothing ? String[] : report.errors
    warnings = report === nothing ? String[] : report.warnings
    # The validator returns a report; it does not throw.
    st === :refused && (bad = true;
                        push!(notes, "validate threw instead of reporting"))

    st, lazy, note = attempt("read", () -> Mestra.read(path))
    isempty(note) || push!(notes, note)
    st === :bad && (bad = true)

    st, eager, note = attempt("read eager",
                              () -> Mestra.read(path; lazy = false))
    isempty(note) || push!(notes, note)
    st === :bad && (bad = true)

    if lazy !== nothing
        for s in Mestra.all_slots(lazy)
            Mestra.is_callable_slot(s) && continue
            :row in Mestra.julia_dims(s) || continue
            st, _, note = attempt("rows $(s.path)",
                                  () -> Mestra.rows(lazy, s, 1:1))
            isempty(note) || push!(notes, note)
            st === :bad && (bad = true)
        end
        for sup in lazy.supports
            st, _, note = attempt("support_id $(sup.name)",
                                  () -> Mestra.support_id(sup))
            isempty(note) || push!(notes, note)
            st === :bad && (bad = true)
        end
        for (n, k) in lazy.keys
            st, _, note = attempt("values $(n)",
                                  () -> Mestra.values(lazy, k))
            isempty(note) || push!(notes, note)
            st === :bad && (bad = true)
        end
        append!(notes, ["found:" * f.rule for f in lazy.findings])
    end
    return (bad, errors, warnings, notes)
end

function main(argv)
    for path in argv
        name = splitext(basename(path))[1]
        t0 = time()
        bad, errors, warnings, notes = try
            check(path)
        catch e
            (true, String[], String[],
             ["the check itself failed: " *
              first(sprint(showerror, e), 160)])
        end
        elapsed = round(time() - t0; digits = 3)
        println(join([name, bad ? "fail" : "ok", string(elapsed),
                      join(errors, ","), join(warnings, ","),
                      join(unique(notes), "; ")], "|"))
        flush(stdout)
    end
    return 0
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && exit(main(ARGS))
