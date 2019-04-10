using JuMP
using Gurobi
using LinearAlgebra
using SparseArrays

# Functions for solving the LP-relaxation of correlation clustering
# (and specifically, the LambdaCC LP relaxation) using Gurobi optimization software
#
# Last updated by Nate Veldt on 02-11-2019

# find_violations
# Given a candidate distance matrix D, iterate through all 3-tuples of nodes
# and return the tuples where triangle inequality constraints have been violated.
#
# Output is stored in vector 'violations'
#
# Heuristic speed ups:
#       - Only grab Dij, Dik, Djk once per tuple
#       - if a - b - c > 0, then a>b and a>c. By checking these first
#           we rule out a lot of situations where constraints do not need to be
#           be added, so in all test cases this gave a speed up
#
# Note that we want D to be lower triangular here, though if it is symmetric
# this will work fine as well. We just need to make sure the distance information
# in D is not just stored in the upper triangular portion
function find_violations!(D::Matrix{Float64}, violations::Vector{Tuple{Int,Int,Int}})
  n = size(D,1)

  # We only need this satisfied to within a given tolerance, since the
  # optimization software will only solve it to within a certain tolerance
  # anyways. This can be tweaked if necessary.
  epsi = 1e-8
  @inbounds for i = 1:n-2
       for j = i+1:n-1
          a = D[j,i]
           for k = j+1:n
              b = D[k,i]
              c = D[k,j]
        if a - b > epsi && a - c > epsi && a-b-c > epsi
            push!(violations, (i,j,k))
                # @constraint(m, x[i,j] - x[i,k] - x[j,k] <= 0)
        end
        if b - a > epsi && b - c > epsi && b-a-c > epsi
            push!(violations, (i,k,j))
            # @constraint(m, x[i,k] - x[i,j] - x[j,k] <= 0)
        end

        if c - a > epsi && c-b>epsi && c-a-b > epsi
            push!(violations, (j,k,i))
            # @constraint(m, x[j,k] - x[i,k] - x[i,j] <= 0)
        end
      end
    end
  end
end

# The find function for Julia 1.0
function find(S)
    return findall(x->x!=0,S)
end

# Solve the standard LambdaCC LP relaxation in Gurobi
function LamCC_LP_Gurobi(A::SparseMatrixCSC{Float64,Int64},lam::Float64,LazyFlag::Bool = false,time_limit::Int64=Int64(1e10),FeasTol::Float64=1e-6,SolverMethod::Int64=2, CrossoverStrategy::Int64 =0, OutputFile::String = "LastGurobiOutput")
        n = size(A,1)
        numedges = sum(nonzeros(A))/2
        W = A.-lam
        for i = 1:n
            W[i,i] = 0
        end
        if LazyFlag
            D, LPbound = LazyGeneralCC(A,W,time_limit,FeasTol,SolverMethod, CrossoverStrategy, OutputFile)
        else
            D, LPbound = GurobiGeneralCC(A,W,time_limit,FeasTol,SolverMethod, CrossoverStrategy, OutputFile)
        end
        lccBound = sum((A[i,j]-lam)*D[i,j] for i=1:n-1 for j = i+1:n) + lam*(n*(n-1)/2 - numedges)
        @show LPbound, lccBound
        return D, lccBound
end



# Solve the degree-weighted LambdaCC LP relaxation in Gurobi
function Degree_Weighed_LamCC_LP_Gurobi(A::SparseMatrixCSC{Float64,Int64},lam::Float64,LazyFlag::Bool=true,time_limit::Int64=Int64(1e10),FeasTol::Float64=1e-6,SolverMethod::Int64=2, CrossoverStrategy::Int64 =0, OutputFile::String = "LastGurobiOutput")
        n = size(A,1)
        d = sum(A,dims=1)
        numedges = sum(nonzeros(A))/2
        W = A.-d'*d*lam
        for i = 1:n
            W[i,i] = 0
        end
        if LazyFlag
            D, LPbound = LazyGeneralCC(A,W,time_limit,FeasTol,SolverMethod, CrossoverStrategy, OutputFile)
        else
            D, LPbound = GurobiGeneralCC(A,W,time_limit,FeasTol,SolverMethod, CrossoverStrategy, OutputFile)
        end
        return D, LPbound
end


## Use Gurobi to solve the Correlation Clustering LP relaxation in the case
# of weighted graphs where a positve weight is given for each pair of vertices.
#
# Correlation clustering is
#
# A is the adjacency matrix indicator for the underlying graph where you consider only positive edges
#       i.e. Aij = 1 if (i,j) is a positive edge, i.e. W[i,j] > 0
#           Aij = 0 if W[i,j] < 0
#
# See Gurobi Parameter explanations online at: http://www.gurobi.com/documentation/8.0/refman/parameters.html
#
# The default is to use an interior point solver with zero crossover strategy
# (i.e. don't bother to convert an interior solution to vertex of the constraint simplex).
# Output should satisfy constraints to within FeasTol, default of 1e-6
#
# This does not use the lazy constraints method
function GurobiGeneralCC(A,W,time_limit::Int64=Int64(1e10),FeasTol::Float64=1e-6,SolverMethod::Int64=2, CrossoverStrategy::Int64 =0, OutputFile::String = "LastGurobiOutput")
    n = size(W,1)

    # Create a model that will use Gurobi to solve
    m = Model(solver=GurobiSolver(OutputFlag = 1,TimeLimit = time_limit, FeasibilityTol = FeasTol, Method = SolverMethod, Crossover = CrossoverStrategy, LogFile = OutputFile))

    @variable(m, x[1:n,1:n])

    # Minimize the weight of disagreements (relaxation)
    @objective(m, Min, sum((W[i,j])*x[i,j] for i=1:n-1 for j = i+1:n))

    # Constraints: 0 <= x_ij <= 1 for all node pairs (i,j)
    for i = 1:n-1
        for j = i:n
            @constraint(m,x[i,j] <= 1)
            @constraint(m,x[i,j] >= 0)
        end
    end

    # If we solve with no triangle inequality constraints, we would get the
    # solution D[i,j] = D[j,i] = 1 if A[i,j] = 0 and D[i,j] = D[j,i] = 1
    # otherwise.
    #
    # If we then checked all 3-tuples of nodes, we'd find that the only time
    # triangle constraints were violated is at bad triangles (++- triangles,
    # a tuple that is an unclosed wedge).
    # Hence, from the very beginning we know we must include
    # a triangle inequality constraint at every bad triangle.

    for i = 1:n-2
        for j = i+1:n-1
            for k = j+1:n
                    @constraint(m,x[i,j] - x[i,k] - x[j,k] <= 0)
                    @constraint(m,-x[i,j] + x[i,k] - x[j,k] <= 0)
                    @constraint(m,-x[i,j] - x[i,k] + x[j,k] <= 0)
            end
        end
    end


    # Find intial first solution
    solve(m)

    # Return the objective score and the distance matrix
    D = triu(getvalue(x))
    LPbound = 0.0
    for i = 1:n-1
        for j = i+1:n
            if W[i,j] > 0
                LPbound += W[i,j]*D[i,j]
            else
                LPbound += -W[i,j]*(1-D[i,j])
            end
        end
    end
    return D+collect(D'), LPbound
end


## Use Gurobi to solve the Correlation Clustering LP relaxation in the case
# of weighted graphs where a positve weight is given for each pair of vertices.
#
# Correlation clustering is
#
# A is the adjacency matrix indicator for the underlying graph where you consider only positive edges
#       i.e. Aij = 1 if (i,j) is a positive edge, i.e. W[i,j] > 0
#           Aij = 0 if W[i,j] < 0
#
# See Gurobi Parameter explanations online at: http://www.gurobi.com/documentation/8.0/refman/parameters.html
#
# The default is to use an interior point solver with zero crossover strategy
# (i.e. don't bother to convert an interior solution to vertex of the constraint simplex).
# Output should satisfy constraints to within FeasTol, default of 1e-6
function LazyGeneralCC(A,W,time_limit::Int64=Int64(1e10),FeasTol::Float64=1e-6,SolverMethod::Int64=2, CrossoverStrategy::Int64 =0, OutputFile::String = "LastGurobiOutput")
    n = size(W,1)

    # Create a model that will use Gurobi to solve
    m = Model(solver=GurobiSolver(OutputFlag = 1,TimeLimit = time_limit, FeasibilityTol = FeasTol, Method = SolverMethod, Crossover = CrossoverStrategy, LogFile = OutputFile))

    @variable(m, x[1:n,1:n])

    # Minimize the weight of disagreements (relaxation)
    @objective(m, Min, sum((W[i,j])*x[i,j] for i=1:n-1 for j = i+1:n))

    # Constraints: 0 <= x_ij <= 1 for all node pairs (i,j)
    for i = 1:n-1
        for j = i:n
            @constraint(m,x[i,j] <= 1)
            @constraint(m,x[i,j] >= 0)
        end
    end

    # If we solve with no triangle inequality constraints, we would get the
    # solution D[i,j] = D[j,i] = 1 if A[i,j] = 0 and D[i,j] = D[j,i] = 1
    # otherwise.
    #
    # If we then checked all 3-tuples of nodes, we'd find that the only time
    # triangle constraints were violated is at bad triangles (++- triangles,
    # a tuple that is an unclosed wedge).
    # Hence, from the very beginning we know we must include
    # a triangle inequality constraint at every bad triangle.

    for i = 1:n
        NeighbsI = find(A[:,i])
        numNeighbs = size(NeighbsI,1)
        for u = 1:numNeighbs-1
            j = NeighbsI[u]
            for v = u+1:numNeighbs
                k = NeighbsI[v]
                if A[j,k] == 0
                    # Then we have a bad triangle: (i,j), (i,k) \in E
                    # but (j,k) is not an edge, so D(j,k) wants to be 1
                    #assert(i<j<k)
                    @constraint(m,x[min(j,k),max(j,k)] - x[min(i,k),max(i,k)] - x[min(i,j),max(i,j)] <= 0)
                end
            end
        end
    end

    # Find intial first solution
    solve(m)

    while true
          D = collect(getvalue(x)')     # x will naturally be upper triangular, but
                                        # our 'find_violations' function wants a lower
                                        # triangular matrix

         # Store violating tuples in a vector
         violations = Vector{Tuple{Int,Int,Int}}()
         find_violations!(D,violations)

         # Iterate through and add constraints
         numvi = size(violations,1)

         # Violations (a,b,c) are ordered so that a < b, and (a,b) is the value
         # that needs to be positive in the inequality:
         # x_ab - x_ac - x_bc <= 0.
         # The other two (b and c) could satisfy either b < c or c <= b.
         # We need to make sure we are only placing constraints in the upper
         # triangular portion of the matrix.
         # We do so by just calling min and max on pairs of nodes
         for v in violations
             #assert(v[1]<v[2])
             @constraint(m,x[v[1],v[2]] - x[min(v[1],v[3]),max(v[1],v[3])] - x[min(v[2],v[3]),max(v[2],v[3])] <= 0)
         end

         if numvi == 0
             break
         end
         solve(m)
     end

    # Return the objective score and the distance matrix
    D = triu(getvalue(x))
    LPbound = 0.0
    for i = 1:n-1
        for j = i+1:n
            if W[i,j] > 0
                LPbound += W[i,j]*D[i,j]
            else
                LPbound += -W[i,j]*(1-D[i,j])
            end
        end
    end
    return D+collect(D'), LPbound
end

# LazyLamCC
# Given an input matrix A, solve the LambdaCC objective exactly
# on A by setting up an Interger Linear Program and solving it with Gurobi
# This version solves the objective with lazy constraints
function LazyLamCC(A,lam)

    n = size(A,1)
    A = A - diagm(diag(A))

    # Create a model that will use Gurobi to solve
    m = Model(solver=GurobiSolver(OutputFlag = 0))

    @variable(m, x[1:n,1:n], Bin)

    @objective(m, Min, sum((A[i,j]-lam)*x[i,j] for i=1:n-1 for j = i+1:n))

    function triangleFix(cb)
        println("Inside the triangleFix callback")

        D = getvalue(x)'  # x will naturally be upper triangular, but
                          # our check constraints function wants a lower
                          # triangular matrix

       # Store violating tuples in a vector
       violations= Vector{Tuple{Int,Int,Int}}()

       #tic()
       find_violations!(D,violations)

        # Iterate through and add constraints
       numvi = size(violations,1)
       #println("Found ", numvi, " violations: ",toc())

        for v in violations
            @lazyconstraint(cb,x[v[1],v[2]] - x[min(v[1],v[3]),max(v[1],v[3])] - x[min(v[2],v[3]),max(v[2],v[3])] <= 0)
        end

    end

    addlazycallback(m,triangleFix)
    #println("Working on solving the ILP currently")
    solve(m)
    #println("Done with ILP, working on constraint checking.")


    # Return clustering and objective value
    numedges = countnz(A)/2
    D = getvalue(x)
    Disagreements = sum((A[i,j]-lam)*D[i,j] for i=1:n-1 for j = i+1:n) + lam*(n*(n-1)/2 - numedges)
    return extractClustering(getvalue(x)), Disagreements
end  # end LazyLamCC





# LazyLamCC-Degree weighted version
function LazyLamCC_dw(A,lam)

    n = size(A,1)
    d = sum(A,dims=1)
    # Create a model that will use Gurobi to solve
    m = Model(solver=GurobiSolver(OutputFlag = 0))

    @variable(m, x[1:n,1:n], Bin)

    @objective(m, Min, sum((A[i,j]-d[i]*d[j]*lam)*x[i,j] for i=1:n-1 for j = i+1:n))

    function triangleFix(cb)
        println("Inside the triangleFix callback")

        D = collect(getvalue(x)')   # x will naturally be upper triangular, but
                                    # our check constraints function wants a lower
                                    # triangular matrix

       # Store violating tuples in a vector
       violations= Vector{Tuple{Int,Int,Int}}()

       #tic()
       find_violations!(D,violations)

        # Iterate through and add constraints
       numvi = size(violations,1)
       #println("Found ", numvi, " violations: ",toc())

        for v in violations
            @lazyconstraint(cb,x[v[1],v[2]] - x[min(v[1],v[3]),max(v[1],v[3])] - x[min(v[2],v[3]),max(v[2],v[3])] <= 0)
        end

    end

    addlazycallback(m,triangleFix)
    #println("Working on solving the ILP currently")
    solve(m)
    #println("Done with ILP, working on constraint checking.")


    # Return clustering and objective value
    D = getvalue(x)
    W = A.-d'*d*lam
    Disagreements = 0.0
    for i = 1:n-1
        for j = i+1:n
            if W[i,j] > 0
                Disagreements += W[i,j]*D[i,j]
            else
                Disagreements += -W[i,j]*(1-D[i,j])
            end
        end
    end
    return extractClustering(getvalue(x)), Disagreements
end  # end LazyLamCC


# extractClustering
# Given a 0,1 indicator matrix for node clustering, extract the n x 1
# cluster indicator vector
function extractClustering(x)
    # Assuming the triangle inequality results work, we just have to go through
    # each row of x, and if an element hasn't been placed in a cluster yet, it
    # it starts its own new one and adds everything that is with it.
    n = size(x,1)
    NotClustered = fill(true,n)
    c = zeros(n,1)
    clusnum = 1
    for i = 1:n
        if NotClustered[i]
            for j = i:n
                if x[i,j] < .01 # must be zero, they are clustered together
                    c[j] = clusnum
                    NotClustered[j] = false;
                end
            end
            clusnum +=1
        end
    end
    return c
end
