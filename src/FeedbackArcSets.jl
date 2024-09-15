"""
    FeedbackArcSets

Find the smallest feedback arc set in a directed graph. The smallest
feedback arc set problem is NP-hard, so the time needed to find the
solution grows quickly with the size of the graph, unless it has some
advantageous structure.

    find_feedback_arc_set(graph; kwargs)

Find the smallest feedback arc set in a Graphs directed `graph`.
"""
module FeedbackArcSets

export FeedbackArcSet, find_feedback_arc_set, fast_feedback_arc_set

import Clp
import Cbc
using Graphs: Graphs, SimpleDiGraph, add_edge!, edges, has_edge, has_self_loops,
              ne, nv, outneighbors, rem_edge!, simplecycles_iter,
              simplecycles_limited_length, vertices
using Printf: Printf, @printf
using SparseArrays: SparseArrays, SparseVector, spzeros

"""
    FeedbackArcSet

Type used for the return values of `feedback_arc_set`. See the function
documentation for more information.
"""
mutable struct FeedbackArcSet
    lower_bound::Int
    feedback_arc_set::Vector{Tuple{Int, Int}}
    internals::Dict{String, Any}
end

function Base.show(io::IO, x::FeedbackArcSet)
    upper_bound = length(x.feedback_arc_set)
    if x.lower_bound == upper_bound
        println(io, "Optimal Feedback arc set of size $(x.lower_bound).")
    else
        println(io, "Feedback arc set with lower bound $(x.lower_bound) and upper bound $(upper_bound).")
    end
end

"""
    find_feedback_arc_set(graph)

Find the smallest feedback arc set for `graph`, which must be a
directed graph from the `Graphs` package.

    find_feedback_arc_set(graph; kwargs...)

By adding keyword arguments it is possible to guide the search or
obtain non-optimal solutions and bounds in shorter time than the full
solution.

*Keyword arguments:*

* `max_iterations`: Stop search after this number of iterations.
  Defaults to a very high number.

* `time_limit`: Stop search after this number of seconds. Defaults to
  a very high number.

* `solver_time_limit`: Maximum time to spend in each iteration to
  solve integer programs. This will be gradually increased if the IP
  solver does not find a useful solution in the allowed time. Defaults
  to 10 seconds.

* `log_level`: Amount of verbosity during search. 0 is maximally
  quiet. The default value 1 only prints progress for each iteration.
  Higher values add diagnostics from the IP solver calls.

* `iteration_callback`: A function provided here is called during each
  iteration. The function should take one argument which is a named
  tuple with diagnostic information, see the code for exact
  specifications. Return `true` to continue search and `false` to stop
  search. The default is the `print_iteration_data` function.

The return value is of the `FeedbackArcSet` type and contains the
following fields:

* `lower_bound`: Lower bound for feedback arc set.

* `feedback_arc_set`: Vector of the edges in the smallest found
  feedback arc set.

* `internals`: Dict containing a variety of information about the search.

"""
function find_feedback_arc_set(graph;
                               max_iterations = typemax(Int),
                               time_limit = typemax(Int),
                               solver_time_limit = 10,
                               log_level = 1,
                               iteration_callback = print_iteration_data)
    # Remove self loops if there are any.
    if has_self_loops(graph)
        graph = copy(graph)
        for v in vertices(graph)
            if has_edge(graph, v, v)
                rem_edge!(graph, v, v)
            end
        end
    end

    O, edges = OptProblem(graph)
    reverse_edges = Dict(edges[k] => k for k = 1:length(edges))

    # There is no way getting around adding constraints for length 2
    # cycles, so may as well do it right away.
    cycles = simplecycles_limited_length(graph, 2)
    # We must have at least one cycle constraint so we have something
    # to optimize.
    if isempty(cycles)
        cycles = simplecycles_iter(graph, 4)
    end
    # No cycles found, return the trivial optimum.
    if isempty(cycles)
        return FeedbackArcSet(0, Tuple{Int, Int}[], Dict{String, Any}())
    end

    constrain_cycles!(O, cycles, edges)

    lower_bound = 1
    solution = nothing
    
    start_time = time()
    best_arc_set = fast_feedback_arc_set(graph)
    local arc_set
    
    for iteration = 1:max_iterations
        solver_time = min(solver_time_limit, time_limit - (time() - start_time))
        if solver_time < solver_time_limit / 2 && iteration > 1
            break
        end

        solution = solve_IP(O, seconds = solver_time,
                            allowableGap = 0,
                            logLevel = max(0, log_level - 1))
        
        if solution.status != :Optimal
            error("Non-optimal IP solutions are not supported yet.")
        end

        objbound = solution.attrs[:objbound]

        arc_set, cycles = extract_arc_set_and_cycles(graph, edges, solution.sol)

        if length(arc_set) < length(best_arc_set)
            best_arc_set = arc_set
        end

        lower_bound = max(lower_bound, objbound)

        iteration_data = (log_level = log_level,
                          iteration = iteration,
                          elapsed_time = time() - start_time,
                          lower_bound = lower_bound,
                          solver_time = solver_time,
                          num_cycles = length(O.cycle_constraints),
                          solution = solution,
                          objbound = objbound,
                          arc_set = arc_set,
                          best_arc_set = best_arc_set,
                          cycles = cycles)

        if !iteration_callback(iteration_data)
            break
        end

        if iteration == max_iterations
            break
        end

        if length(cycles) == 0
            break
        end

        constrain_cycles!(O, cycles, edges)
    end

    return FeedbackArcSet(lower_bound, best_arc_set,
                          Dict("O" => O, "edges" => edges,
                               "last_arcs" => arc_set,
                               "last_cycles" => cycles,
                               "last_solution" => solution))
end

function print_iteration_data(data)
    if data.log_level > 0
        @printf("%3d %5d ", data.iteration, round(Int, data.elapsed_time))
        print("[$(data.lower_bound) $(length(data.best_arc_set))] ")
        println("$(data.num_cycles) $(data.solution.status) $(data.solution.objval) $(data.objbound)")
    end
    return true
end

struct CycleConstraint
    A::SparseVector
    lb::Int
    ub::Int
end

# l and u are lower and upper bounds on the variables, i.e. the edges.
mutable struct OptProblem
    c::Vector{Float64}
    l::Vector{Int}
    u::Vector{Int}
    vartypes::Vector{Symbol}
    cycle_constraints::Vector{CycleConstraint}
end

function OptProblem(graph)
    N = nv(graph)
    M = ne(graph)

    l = zeros(Int, M)
    u = ones(Int, M)
    vartypes = fill(:Bin, M)
    edge_variables = Tuple{Int, Int}[]

    for n = 1:N
        for k in outneighbors(graph, n)
            push!(edge_variables, (n, k))
        end
    end

    c = ones(Float64, M)

    return (OptProblem(c, l, u, vartypes, CycleConstraint[]),
            edge_variables)
end

mutable struct Solution
    status
    objval
    sol
    attrs
end

function solve_IP(O::OptProblem, initial_solution = Int[],
                  use_warmstart = true; options...)
    model = Cbc.Cbc_newModel()
    Cbc.Cbc_setParameter(model, "logLevel", "0")
    for (name, value) in options
        Cbc.Cbc_setParameter(model, string(name), string(value))
    end

    A, lb, ub = add_cycle_constraints_to_formulation(O)
    cbc_loadproblem!(model, A, O.l, O.u, O.c, lb, ub)
    Cbc.Cbc_setObjSense(model, 1) # Minimize

    for i in 1:size(A, 2)
        Cbc.Cbc_setInteger(model, i - 1)
    end
    if !isempty(initial_solution) && use_warmstart
        Cbc.Cbc_setMIPStartI(model, length(initial_solution),
                             collect(Cint.(eachindex(initial_solution) .- 1)),
                             Float64.(initial_solution))
    end
    Cbc.Cbc_solve(model)
   
    attrs = Dict()
    attrs[:objbound] = Cbc.Cbc_getBestPossibleObjValue(model)
    attrs[:solver] = :ip
    solution = Solution(cbc_status(model), Cbc.Cbc_getObjValue(model),
                        copy(unsafe_wrap(Array,
                                         Cbc.Cbc_getColSolution(model),
                                         (size(A, 2),))),
                        attrs)
    Cbc.Cbc_deleteModel(model)
    return solution
end

function cbc_loadproblem!(model, A, l, u, c, lb, ub)
    Cbc.Cbc_loadProblem(model, size(A, 2), size(A, 1),
                        Cbc.CoinBigIndex.(A.colptr .- 1),
                        Int32.(A.rowval .- 1),
                        Float64.(A.nzval),
                        Float64.(l), Float64.(u), Float64.(c),
                        Float64.(lb), Float64.(ub))
end

function cbc_status(model)
    for (predicate, value) in ((Cbc.Cbc_isProvenOptimal, :Optimal),
                               (Cbc.Cbc_isProvenInfeasible, :Infeasible),
                               (Cbc.Cbc_isContinuousUnbounded, :Unbounded),
                               (Cbc.Cbc_isNodeLimitReached, :UserLimit),
                               (Cbc.Cbc_isSecondsLimitReached, :UserLimit),
                               (Cbc.Cbc_isSolutionLimitReached, :UserLimit),
                               (Cbc.Cbc_isAbandoned, :Error))
        predicate(model) != 0 && return value
    end
    return :InternalError
end

function add_cycle_constraints_to_formulation(O::OptProblem)
    n = length(O.cycle_constraints)
    m = length(first(O.cycle_constraints).A)
    A = spzeros(Int, n, m)
    lb = zeros(Int, n)
    ub = zeros(Int, n)
    i = 1
    for c in O.cycle_constraints
        A[i,:] = c.A
        lb[i] = c.lb
        ub[i] = c.ub
        i += 1
    end
    return A, lb, ub
end

# Extract the possibly partial feedback arc set from the solution and
# find some additional cycles if it is incomplete.
function extract_arc_set_and_cycles(graph, edges, solution)
    graph2 = SimpleDiGraph(nv(graph))
    arc_set = []
    for i = 1:length(solution)
        if solution[i] < 0.5
            add_edge!(graph2, edges[i]...)
        else
            push!(arc_set, edges[i])
        end
    end

    append!(arc_set, fast_feedback_arc_set(graph2))
    cycles = simplecycles_iter(graph2, 4)

    return arc_set, cycles
end

# Add constraints derived from cycles in the graph. The constraints
# just say that for each listed cycle, at least one edge must be
# included in the solution.
function constrain_cycles!(O::OptProblem, cycles, edges)
    previous_number_of_constraints = length(O.cycle_constraints)
    for cycle in cycles
        A = spzeros(Int, length(edges))
        cycle_edges = [(cycle[i], cycle[mod1(i + 1, length(cycle))])
                       for i in 1:length(cycle)]
        for i = 1:length(edges)
            v1, v2 = edges[i]
            if (v1, v2) in cycle_edges
                A[i] = 1
            end
        end
        lb = 1
        ub = length(cycle)
        push!(O.cycle_constraints, CycleConstraint(A, lb, ub))
    end

    return length(O.cycle_constraints) - previous_number_of_constraints
end

# Compute a fast feedback arc set. This doesn't have to produce a
# small feedback arc set but it must be fast and it must not include
# any edge that is not part of any cycle. As a corollary it must
# return an empty arc set for an acyclic graph.
#
# The algorithm used here is to just run DFS until all vertices are
# covered and include all found back edges into the feedback arc set.
function fast_feedback_arc_set(graph)
    marks = zeros(nv(graph))
    feedback_arc_set = Tuple{Int, Int}[]
    for vertex in vertices(graph)
        marks[vertex] == 0 || continue
        _dfs_feedback_arc_set(graph, marks, feedback_arc_set, vertex)
    end
    return feedback_arc_set
end

function _dfs_feedback_arc_set(graph, marks, feedback_arc_set, vertex)
    marks[vertex] = 1
    for neighbor in outneighbors(graph, vertex)
        if marks[neighbor] == 1
            push!(feedback_arc_set, (vertex, neighbor))
        elseif marks[neighbor] == 0
            _dfs_feedback_arc_set(graph, marks, feedback_arc_set, neighbor)
        end
    end
    marks[vertex] = 2
end

end