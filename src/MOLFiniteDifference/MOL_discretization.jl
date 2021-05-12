using ModelingToolkit: operation, istree, arguments

# Method of lines discretization scheme

@enum GridAlign center_align edge_align
struct MOLFiniteDifference{T,T2} <: DiffEqBase.AbstractDiscretization
    dxs::T
    time::T2
    upwind_order::Int
    centered_order::Int
    grid_align::GridAlign
end

# Constructors. If no order is specified, both upwind and centered differences will be 2nd order
MOLFiniteDifference(dxs, time; upwind_order = 1, centered_order = 2, grid_align=center_align) =
    MOLFiniteDifference(dxs, time, upwind_order, centered_order, grid_align)

function calculate_weights_cartesian(order::Int, x0::T, xs::AbstractVector, idxs::AbstractVector) where T<:Real
        # Cartesian domain: use Fornberg
        DiffEqOperators.calculate_weights(order, x0, vec(xs[idxs]))
 end
 function calculate_weights_spherical(order::Int, x0::T, x::AbstractVector, idxs::AbstractVector) where T<:Real
        # Spherical domain: see #367
        # https://web.mit.edu/braatzgroup/analysis_of_finite_difference_discretization_schemes_for_diffusion_in_spheres_with_variable_diffusivity.pdf
        # Only order 2 is implemented
        @assert order == 2
        # Only 2nd order discretization is implemented
        # We can't activate this assertion for now because the rules try to create the spherical Laplacian
        # before checking whether there is a spherical Laplacian
        # this could be fixed by dispatching on domain type when we have different domain types
        # but for now everything is an IntervalDomain
        # @assert length(x) == 3
        # TODO: nonlinear diffusion in a spherical domain
        i = idxs[2] 
        dx1 = x[i] - x[i-1]
        dx2 = x[i+1] - x[i]
        i0 = i - 1 # indexing starts at 0 in the paper and starts at 1 in julia
        1 / (i0 * dx1 * dx2) * [i0-1, -2i0, i0+1]
 end
 

function SciMLBase.symbolic_discretize(pdesys::ModelingToolkit.PDESystem,discretization::DiffEqOperators.MOLFiniteDifference)
    grid_align = discretization.grid_align
    pdeeqs = pdesys.eqs isa Vector ? pdesys.eqs : [pdesys.eqs]
    t = discretization.time
    nottime = filter(x->~isequal(x.val, t.val),pdesys.indvars)
    nspace = length(nottime)
    depvars = pdesys.depvars

    # Discretize space
    space = map(nottime) do x
        xdomain = pdesys.domain[findfirst(d->isequal(x.val, d.variables),pdesys.domain)]
        dx = discretization.dxs[findfirst(dxs->isequal(x.val, dxs[1].val),discretization.dxs)][2]
        dx isa Number ? (xdomain.domain.lower:dx:xdomain.domain.upper) : dx
    end
    dxs = map(nottime) do x        
        dx = discretization.dxs[findfirst(dxs->isequal(x.val, dxs[1].val),discretization.dxs)][2]
    end
    # Get tspan
    tdomain = pdesys.domain[findfirst(d->isequal(t.val, d.variables),pdesys.domain)]
    @assert tdomain.domain isa IntervalDomain
    tspan = (tdomain.domain.lower,tdomain.domain.upper)

    # Define the grid on which the dependent variables will be evaluated (see #378)
    # center_align is recommended for Dirichlet BCs
    # edge_align is recommended for Neumann BCs (spatial discretization is conservative)
    if grid_align == center_align
        grid = space
    elseif grid_align == edge_align
        # boundary conditions implementation assumes centered_order=2
        @assert discretization.centered_order==2
        # construct grid including ghost nodes beyond outer edges
        # e.g. space 0:dx:1 goes to grid -dx/2:dx:1+dx/2
        space_ext = map(s -> vcat(2s[1]-s[2],s,2s[end]-s[end-1]), space)
        grid = map(s -> (s[1:end-1]+s[2:end])/2, space_ext)
        # TODO: allow depvar-specific center/edge choice?
    end

    # Build symbolic variables
    space_indices = CartesianIndices(((axes(s)[1] for s in space)...,))
    grid_indices = CartesianIndices(((axes(g)[1] for g in grid)...,))
    depvarsdisc = map(depvars) do u
        [Num(Variable{Symbolics.FnType{Tuple{Any}, Real}}(Base.nameof(ModelingToolkit.operation(u.val)),II.I...))(t) for II in grid_indices]
    end
    spacevals = map(y->[Pair(nottime[i],space[i][y.I[i]]) for i in 1:nspace],space_indices)
    gridvals = map(y->[Pair(nottime[i],grid[i][y.I[i]]) for i in 1:nspace],grid_indices)


    ### INITIAL AND BOUNDARY CONDITIONS ###
    # Build symbolic maps for boundaries
    edges = reduce(vcat,[[vcat([Colon() for j in 1:i-1],1,[Colon() for j in i+1:nspace]),
                          vcat([Colon() for j in 1:i-1],length(space[i]),[Colon() for j in i+1:nspace])] for i in 1:nspace])

    #edgeindices = [indices[e...] for e in edges]
    get_edgevals(i) = [nottime[i]=>first(space[i]),nottime[i]=>last(space[i])]
    edgevals = reduce(vcat,[get_edgevals(i) for i in 1:length(space)])
    edgevars = [[d[e...] for e in edges] for d in depvarsdisc]

    bclocs = map(e->substitute.(pdesys.indvars,e),edgevals) # location of the boundary conditions e.g. (t,0.0,y)
    edgemaps = Dict(bclocs .=> [spacevals[e...] for e in edges])
    initmaps = substitute.(depvars,[t=>tspan[1]])

    # Generate map from variable (e.g. u(t,0)) to discretized variable (e.g. u₁(t))
    subvar(depvar) = substitute.((depvar,),edgevals)
    if grid_align == center_align
        # depvarbcmaps will dictate what to replace the variable terms with in the bcs
        # replace u(t,0) with u₁, etc
        depvarbcmaps = reduce(vcat,[subvar(depvar) .=> edgevar for (depvar, edgevar) in zip(depvars, edgevars)])
    end
    # depvarderivbcmaps will dictate what to replace the Differential terms with in the bcs
    if nspace == 1
        # 1D system
        left_weights(j) = DiffEqOperators.calculate_weights(discretization.upwind_order, grid[j][1], grid[j][1:2])
        right_weights(j) = DiffEqOperators.calculate_weights(discretization.upwind_order, grid[j][end], grid[j][end-1:end])
        central_neighbor_idxs(II,j) = [II-CartesianIndex((1:nspace.==j)...),II,II+CartesianIndex((1:nspace.==j)...)]
        left_idxs = central_neighbor_idxs(CartesianIndex(2),1)[1:2]
        right_idxs(j) = central_neighbor_idxs(CartesianIndex(length(grid[j])-1),1)[end-1:end]
        # Constructs symbolic spatially discretized terms of the form e.g. au₂ - bu₁
        derivars = [[dot(left_weights(1),depvar[left_idxs]), dot(right_weights(1),depvar[right_idxs(1)])]
        for depvar in depvarsdisc]
        # Create list of all the symbolic Differential terms evaluated at boundary e.g. Differential(x)(u(t,0))
        subderivar(depvar,s) = substitute.((Differential(s)(depvar),),edgevals)
        # Create map of symbolic Differential terms with symbolic spatially discretized terms
        depvarderivbcmaps = reduce(vcat,[subderivar(depvar, s) .=> derivars[i]
                                         for (i, depvar) in enumerate(depvars) for s in nottime])
        
        if grid_align == edge_align
            # Constructs symbolic spatially discretized terms of the form e.g. (u₁ + u₂) / 2 
            bcvars = [[dot(ones(2)/2,depvar[left_idxs]), dot(ones(2)/2,depvar[right_idxs(1)])]
                      for depvar in depvarsdisc]
            # replace u(t,0) with (u₁ + u₂) / 2, etc
            depvarbcmaps = reduce(vcat,[subvar(depvar) .=> bcvars[i]
                                  for (i, depvar) in enumerate(depvars) for s in nottime])
                                    
        end
    else
        # Higher dimension
        # TODO: Fix Neumann and Robin on higher dimension
        depvarderivbcmaps = []
    end

    # Generate initial conditions and bc equations
    u0 = []
    bceqs = []
    for bc in pdesys.bcs
        if ModelingToolkit.operation(bc.lhs) isa Sym && ~any(x -> isequal(x, t.val), ModelingToolkit.arguments(bc.lhs))
            # initial condition
            # Assume in the form `u(...) ~ ...` for now
            push!(u0,vec(depvarsdisc[findfirst(isequal(bc.lhs),initmaps)] .=> substitute.((bc.rhs,),gridvals)))
        else
            # Algebraic equations for BCs
            i = findfirst(x->occursin(x.val,bc.lhs),first.(depvarbcmaps))
            bcargs = first(depvarbcmaps[i]).val.arguments
            # Replace Differential terms in the bc lhs with the symbolic spatially discretized terms
            # TODO: Fix Neumann and Robin on higher dimension
            lhs = nspace == 1 ? substitute(bc.lhs,depvarderivbcmaps[i]) : bc.lhs

            # Replace symbol in the bc lhs with the spatial discretized term
            lhs = substitute(lhs,depvarbcmaps[i])
            rhs = substitute.((bc.rhs,),edgemaps[bcargs])
            lhs = lhs isa Vector ? lhs : [lhs] # handle 1D
            push!(bceqs,lhs .~ rhs)
        end
    end

    u0 = reduce(vcat,u0)
    bceqs = reduce(vcat,bceqs)

    #---- Count Boundary Equations --------------------
    # Count the number of boundary equations that lie at the spatial boundary on
    # both the left and right side. This will be used to determine number of
    # interior equations s.t. we have a balanced system of equations.

    # get the depvar boundary terms for given depvar and indvar index.
    get_depvarbcs(depvar, i) = substitute.((depvar,),get_edgevals(i))

    # return the counts of the boundary-conditions that reference the "left" and
    # "right" edges of the given independent variable. Note that we return the
    # max of the count for each depvar in the system of equations.
    get_bc_counts(i) =
        begin
            left = 0
            right = 0
            for depvar in depvars
                depvaredges = get_depvarbcs(depvar, i)
                counts = [map(x->occursin(x.val, bc.lhs), depvaredges) for bc in pdesys.bcs]
                left = max(left, sum([c[1] for c in counts]))
                right = max(right, sum([c[2] for c in counts]))
            end
            return [left, right]
        end
    #--------------------------------------------------

    ### PDE EQUATIONS ###
    # Create a stencil in the required dimension centered around 0
    # e.g. (-1,0,1) for 2nd order, (-2,-1,0,1,2) for 4th order, etc
    if discretization.centered_order % 2 != 0
        throw(ArgumentError("Discretization centered_order must be even, given $(discretization.centered_order)"))
    end
    approx_order = discretization.centered_order
    stencil(j, order) = CartesianIndices(Tuple(map(x -> -x:x, (1:nspace.==j) * (order÷2))))

    # TODO: Generalize central difference handling to allow higher even order derivatives
    # The central neighbour indices should add the stencil to II, unless II is too close
    # to an edge in which case we need to shift away from the edge

    # Calculate buffers
    I1 = oneunit(first(grid_indices))
    Imin(order) = first(grid_indices) + I1 * (order÷2)
    Imax(order) = last(grid_indices) - I1 * (order÷2)

    interior = grid_indices[[let bcs = get_bc_counts(i)
                             (1 + first(bcs)):length(g)-last(bcs)
                             end
                             for (i,g) in enumerate(grid)]...]
    eqs = vec(map(Base.product(interior,pdeeqs)) do p
        II,eq = p
    
        # Use max and min to apply buffers
        central_neighbor_idxs(II,j,order) = stencil(j,order) .+ max(Imin(order),min(II,Imax(order)))
        central_weights_cartesian(d_order,II,j) = calculate_weights_cartesian(d_order, grid[j][II[j]], grid[j], vec(map(i->i[j], 
                                                                              central_neighbor_idxs(II,j,approx_order))))
        central_deriv(d_order, II,j,k) = dot(central_weights(d_order, II,j),depvarsdisc[k][central_neighbor_idxs(II,j,approx_order)])

        central_deriv_cartesian(d_order,II,j,k) = dot(central_weights_cartesian(d_order,II,j),depvarsdisc[k][central_neighbor_idxs(II,j,approx_order)])
        
        # spherical Laplacian has a hardcoded order of 2 (only 2nd order is implemented)
        # both for derivative order and discretization order
        central_weights_spherical(II,j) = calculate_weights_spherical(2, grid[j][II[j]], grid[j], vec(map(i->i[j], central_neighbor_idxs(II,j,2))))
        central_deriv_spherical(II,j,k) = dot(central_weights_spherical(II,j),depvarsdisc[k][central_neighbor_idxs(II,j,2)])
        
        # get a sorted list derivative order such that highest order is first. This is useful when substituting rules
        # starting from highest to lowest order.
        d_orders(s) = reverse(sort(collect(union(differential_order(eq.rhs, s.val), differential_order(eq.lhs, s.val)))))
        
        # central_deriv_rules = [(Differential(s)^2)(u) => central_deriv(2,II,j,k) for (j,s) in enumerate(nottime), (k,u) in enumerate(depvars)]
        central_deriv_rules_cartesian = Array{Pair{Num,Num},1}()
        for (j,s) in enumerate(nottime)
            rs = [(Differential(s)^d)(u) => central_deriv_cartesian(d,II,j,k) for d in d_orders(s), (k,u) in enumerate(depvars)]
            for r in rs
                push!(central_deriv_rules_cartesian, r)
            end
        end
        central_deriv_rules_spherical = [(Differential(s))(s^2*Differential(s)(u))/s^2 => central_deriv_spherical(II,j,k) 
                                         for (j,s) in enumerate(nottime), (k,u) in enumerate(pdesys.depvars)]
        
        valrules = vcat([depvars[k] => depvarsdisc[k][II] for k in 1:length(depvars)],
                        [nottime[j] => grid[j][II[j]] for j in 1:nspace])
    
        # TODO: upwind rules needs interpolation into `@rule`
        forward_weights(II,j) = DiffEqOperators.calculate_weights(discretization.upwind_order, 0.0, grid[j][[II[j],II[j]+1]])
        reverse_weights(II,j) = DiffEqOperators.calculate_weights(discretization.upwind_order, 0.0, grid[j][[II[j]-1,II[j]]])
        # upwinding_rules = [@rule(*(~~a,$(Differential(nottime[j]))(u),~~b) => IfElse.ifelse(*(~~a..., ~~b...,)>0,
        #                         *(~~a..., ~~b..., dot(reverse_weights(II,j),depvars[k][central_neighbor_idxs(II,j)[1:2]])),
        #                         *(~~a..., ~~b..., dot(forward_weights(II,j),depvars[k][central_neighbor_idxs(II,j)[2:3]]))))
        #                         for j in 1:nspace, k in 1:length(pdesys.depvars)]

        ## Discretization of non-linear laplacian. 
        # d/dx( a du/dx ) ~ (a(x+1/2) * (u[i+1] - u[i]) - a(x-1/2) * (u[i] - u[i-1]) / dx^2
        b1(II, j, k) = dot(reverse_weights(II, j), depvarsdisc[k][central_neighbor_idxs(II, j, approx_order)[1:2]]) / dxs[j]
        b2(II, j, k) = dot(forward_weights(II, j), depvarsdisc[k][central_neighbor_idxs(II, j, approx_order)[2:3]]) / dxs[j]
        # TODO: improve interpolation of g(x) = u(x) for calculating u(x+-dx/2)
        g(II, j, k, l) = sum([depvarsdisc[k][central_neighbor_idxs(II, j, approx_order)][s] for s in (l == 1 ? [2,3] : [1,2])]) / 2.
        # iv_mid returns middle space values. E.g. x(i-1/2) or y(i+1/2).
        iv_mid(II, j, l) = (grid[j][II[j]] + grid[j][II[j]+l]) / 2.0 
        # Dependent variable rules
        r_mid_dep(II, j, k, l) = [depvars[k] => g(II, j, k, l) for k in 1:length(depvars)]
        # Independent variable rules
        r_mid_indep(II, j, l) = [nottime[j] => iv_mid(II, j, l) for j in 1:length(nottime)]
        # Replacement rules: new approach
        rules = [@rule ($(Differential(iv))(*(~~a, $(Differential(iv))(dv), ~~b))) =>
                 dot([Num(substitute(substitute(*(~~a..., ~~b...), r_mid_dep(II, j, k, -1)), r_mid_indep(II, j, -1))),
                      Num(substitute(substitute(*(~~a..., ~~b...), r_mid_dep(II, j, k, 1)), r_mid_indep(II, j, 1)))],
                     [-b1(II, j, k), b2(II, j, k)])
                 for (j, iv) in enumerate(nottime) for (k, dv) in enumerate(depvars)]
        rhs_arg = (SymbolicUtils.operation(eq.rhs) == +) ? SymbolicUtils.arguments(eq.rhs) : [eq.rhs]
        lhs_arg = (SymbolicUtils.operation(eq.lhs) == +) ? SymbolicUtils.arguments(eq.lhs) : [eq.lhs]
        nonlinlap_rules = []
        for t in vcat(lhs_arg,rhs_arg)
            for r in rules
                if r(t) !== nothing
                    push!(nonlinlap_rules, t => r(t))
                end
            end
        end

        rules = vcat(vec(nonlinlap_rules),
                     vec(central_deriv_rules_cartesian),
                     vec(central_deriv_rules_spherical),
                     valrules)

        substitute(eq.lhs,rules) ~ substitute(eq.rhs,rules)

    end)

    # Finalize
    defaults = pdesys.ps === nothing || pdesys.ps === SciMLBase.NullParameters() ? u0 : vcat(u0,pdesys.ps)
    ps = pdesys.ps === nothing || pdesys.ps === SciMLBase.NullParameters() ? Num[] : first.(pdesys.ps)
    # Combine PDE equations and BC equations
    sys = ODESystem(vcat(eqs,unique(bceqs)),t,vec(reduce(vcat,vec(depvarsdisc))),ps,defaults=Dict(defaults))
    sys, tspan
end

function SciMLBase.discretize(pdesys::ModelingToolkit.PDESystem,discretization::DiffEqOperators.MOLFiniteDifference)
    sys, tspan = SciMLBase.symbolic_discretize(pdesys,discretization)
    simpsys = structural_simplify(sys)
    prob = ODEProblem(simpsys,Pair[],tspan)
end
