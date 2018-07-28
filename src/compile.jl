## tape compilation

# function to_expr(op::Call)
#     if op.var.val isa AbstractArray
#         return :($(op.var).val .= $(op.fn)(map(getvalue, $(op.args))...; $(op.kwargs)...))
#     else
#         return :($(op.var).val = $(op.fn)(map(getvalue, $(op.args))...; $(op.kwargs)...))
#     end
# end
# function to_expr(op::Call{typeof(*), Tuple{TArray{T,N}, TArray{T,N}}}) where {T,N}
#     return :(mul!($(op.var).val, $(op.args[1]).val, $(op.args[2]).val))
# end

# function to_expr(op::Bcast)
#     if op.var.val isa AbstractArray
#         return :($(op.var).val .= $(op.fn).(map(getvalue, $(op.args))...))
#     else
#         return :($(op.var).val = $(op.fn).(map(getvalue, $(op.args))...))
#     end
# end
# # to_expr(op::Bcast) = :($(op.var).val .= $(op.fn).(map(getvalue, $(op.args))...))
# to_expr(op::Assign) = :($(op.var).val = $(op.src).val)
# to_expr(op::Constant) = :()    # constants don't change anyway


# function compile(tape::Tape)
#     fn_ex = :(function $(gensym("tape_fn"))() end)
#     body = fn_ex.args[2]
#     for op in tape
#         if !isa(op, Input)
#             ex = to_expr(op)
#             push!(body.args, ex)
#         end
#     end
#     return Core.eval(@__MODULE__, fn_ex)
# end


make_name(op::AbstractOp) = Symbol("%$(getid(getvar(op)))")
make_name(var::TAny) = Symbol("%$(getid(var))")

to_exnode(op::Input) = ExNode{:input}(make_name(op), make_name(op); val=getvalue(op))
to_exnode(op::Constant) = ExNode{:constant}(make_name(op), getvalue(op); val=getvalue(op))
to_exnode(op::Assign) = ExNode{:(=)}(make_name(op), make_name(op.src); val=getvalue(op))

const OK_SYMBOL_FUNCS = Set([*, ^, exp, log])

# Espresso operates on symbols, not function objects.
# Although it's fragile for many functions, it's useful for a number of standard functions.
# Later it lets us use a number of useful code transformations during code generation,
# specifically convert * to mul! and rewrite some functions to CUDAnative
# without adding it to dependencies
# An alternative approach would be to reimplement Espresso's optimizations
# for function objects instead of function names, leaving only CUDAnative stuff symbolic.
maybe_to_symbol(f::Function) = f in OK_SYMBOL_FUNCS ? Symbol(f) : f


function to_exnode(op::Call)
    arg_names = map(make_name, op.args)
    fns = maybe_to_symbol(op.fn)
    if isempty(op.kwargs)
        ex = Expr(:call, fns, arg_names...)
    else
        ex = Expr(:call, fns, Espresso.make_kw_params(op.kwargs), arg_names...)
    end
    return ExNode{:call}(make_name(op), ex; val=getvalue(op))
end

function to_exnode(op::Bcast)
    arg_names = map(make_name, op.args)
    fns = maybe_to_symbol(op.fn)
    ex = Expr(:., fns, Expr(:tuple, arg_names...))
    ExNode{:bcast}(make_name(op), ex; val=getvalue(op))
end


function to_exgraph(tape::Tape)
    g = ExGraph()
    for op in tape
        push!(g, to_exnode(op))
    end
    return g
end


function replace_names_with_places(tape::Tape, ex)
    st = Dict(Symbol("%$id") => :($(tape[id].var).val) for id=1:length(tape))
    return subs(ex, st)
end


function make_expr(tape::Tape)
    exg = to_exgraph(tape)
    ret_var_ids = vcat(values(tape.derivs) |> collect, [tape.resultid]) 
    ret_var_names = [Symbol("%$id") for id in ret_var_ids]
    # push final tuple to avoid their removal as unused
    push!(exg, ExNode{:tuple}(gensym(), Expr(:tuple, ret_var_names...)))
    ex = generate_code(BufCodeGen(), exg)
    ex_with_places = replace_names_with_places(tape, ex)
    # remove tuple
    deleteat!(ex_with_places.args, length(ex_with_places.args))
    return ex_with_places
end


function compile(tape::Tape)
    fn_ex = :(function $(gensym("tape_fn"))() end)
    body = fn_ex.args[2]
    ex = make_expr(tape)
    body.args = ex.args
    return Core.eval(@__MODULE__, fn_ex), ex
end


function compile!(tape::Tape)
    compiled, ex = compile(tape)
    tape.meta[:ex] = ex
    tape.compiled = compiled
end


function rerecord_inputs!(tape::Tape, args...)
    minitape = Tape()
    targs = make_tracked_args(minitape, args...)
    for i=1:length(minitape)
        val = getvalue(minitape[i])
        setvalue!(tape[i], val)
    end
end


function play!(tape::Tape, args...; use_compiled=true)
    rerecord_inputs!(tape, args...)
    if use_compiled && tape.compiled != nothing
        Base.invokelatest(tape.compiled)
    else
        for op in tape
            exec!(tape, op)
        end
    end
end
