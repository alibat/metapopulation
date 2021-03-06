####################################################
# 	METAPOPULATION MODEL FOR INFECTION DYNAMICS
# 		   WITH ANNUAL BIRTH PULSES
# 	       DENSITY-DEPENDENT DEATH RATE
#         AND MATERNAL TRANSFER OF ANTIBODIES
#	-------------------------------------------
#			   DEFINITIONS
####################################################

# Olivier Restif, Nov 2015

# Stochastic MSIR model with seasonal Gaussian birth rate 
# Density-dependent death rate (DDD) introduced to prevent unlimited growth in the metapopulation.
# To allow comparison, a density-independent death rate is also included.

# The single-patch demographic model is:
# dN/dt = [b(t) - d - dd*N(t)] * N(t)/lambda
# Birth rate: b(t)*N(t)/lambda
# Death rate: [d + dd*N(t)] * N(t)/lambda
# where
# - b(t) is the seasonal birthing term with <b(t)> = 1. Annual births per capita = 1/lambda
# - K = 1/dd is the carrying capacity when d=0. Average population size <N> = (1-d)/dd
# - lambda is the average life span when N = <N>

# Infection dynamics in a single patch:
# dI/dt = beta*S*I/N - gamma*I - (d+dd*N)*I/lambda
# should lead to an average R0 = <N>/<S> = beta / (gamma + 1/lambda)

# MTA: a proportion rho of offspring from immune parents are born with maternal antibodies (M), which decays at rate eta.

# R version using package `adaptivetau`

library(adaptivetau)
library(foreach)
library(parallel)
library(doParallel)
library(deSolve)

source("Models/myfunctions.R")

# ================================== MODEL DEFINITIONS ===================================

# Variables: {S_i,I_i,R_i,M_i} 1≤i≤n 
# These can be handled by names (using string manipulation) or by position
# Order of variables: S_1,..., S_n, I_1, ..., I_n, R_1,... , R_n, M_1,...,M_n
# => S_i = var[i], I_i = var[i+n], R_i = var[i+2*n], M_i = var[i+3*n]

# Time unit = year

# ----------------------- Transition matrix -----------------------------------------------
# Create a transition matrix with 4*n rows (variables) and 6*n+3*k columns (events)
# where n=nrow(contact.matrix) is the number of patches and k=sum(contact.matrix) is the number of migration events
# Argument: contact.matrix: square matrix of size n with 0 and 1, M[i,j]=1 <=> migration from i to j
meta.DDD.MSIR.transitions <- function(contact.matrix){
	n <- nrow(contact.matrix)
	var <- numeric(4*n)
	moves <- which(contact.matrix==1,T) # Matrix of all possible contacts
	cbind(
		# Births into S
		sapply(1:n,function(i){replace(var,i,+1)}),
		# Births into M
		sapply(1:n,function(i){replace(var,i+3*n,+1)}),
		# Deaths (in the order of variables)
		sapply(1:(4*n),function(i){replace(var,i,-1)}),
		# Infection
		sapply(1:n,function(i){replace(var,c(i,i+n),c(-1,+1))}),
		# Recovery
		sapply(1:n,function(i){replace(var,c(i+n,i+2*n),c(-1,+1))}),
		# Loss of maternal immunity (M -> S)
		sapply(1:n,function(i){replace(var,c(i+3*n,i),c(-1,+1))}),
		# Migrations (S)
		if(nrow(moves)>0) sapply(1:nrow(moves),function(j){replace(var,moves[j,],c(-1,+1))}) else NULL,
		# Migrations (I)
		if(nrow(moves)>0) sapply(1:nrow(moves),function(j){replace(var,moves[j,]+n,c(-1,+1))}) else NULL,
		# Migrations (R)
		if(nrow(moves)>0) sapply(1:nrow(moves),function(j){replace(var,moves[j,]+2*n,c(-1,+1))}) else NULL,
		# Migrations (M)
		if(nrow(moves)>0) sapply(1:nrow(moves),function(j){replace(var,moves[j,]+3*n,c(-1,+1))}) else NULL
	)
}

# ----------------------- Transition rates -----------------------------------------------
# Calculate rates and return a vector of length 6*n+3*k 
# MSIR model with FD transmission within patches, all individuals die and reproduce equally, directional migration
# Arguments:
# - x: vector of variable values, no names required
# - par: list of parameters, with elements:
# 	- np: number of patches
#	- contact.matrix: square matrix of size np with 0 and 1, M[i,j]=1 <=> migration from i to j
#	- b() = function(t,p) returning a vector of normalised birth rates per capita: <b> = 1
# 	- b.par: list of parameters used by function b(t,p)
#	- d: density-independent death rate
#	- dd[]: density-dependent death rate (1/carrying capacity)
#	- lambda: average life-span
#	- beta: transmission rate
#	- gamma: recovery rate
#	- mu: migration rate
meta.DDD.MSIR.Rates <- function(x,par,t) with(par,{
	moves <- which(contact.matrix==1,T) # Matrix of all possible contacts
	# Calculate population size in each patch 
	N <- x[1:np] + x[(np+1):(2*np)] + x[(2*np+1):(3*np)] + x[(3*np+1):(4*np)] 
	return(as.numeric(c(
		# Births into S: assume all individuals contribute
		b(t,b.par) * (N-rho*x[(2*np+1):(3*np)])/lambda,
		# Births into M, from R only:
		b(t,b.par) * (rho*x[(2*np+1):(3*np)])/lambda,
		# Deaths: rate is independent of status or patch
		sapply(1:(4*np),function(i){
			p <- (i-1)%%np+1
			(d + N[p]*dd[p]) * x[i]/lambda }),
		# Infection: assume FD within patch -- test N>0 !!
		sapply(1:np,function(i){ if(N[i]>0) beta*x[i]*x[i+np]/N[i] else 0}),
		# Recovery
		gamma*x[(np+1):(2*np)],
		# Loss of MTA
		eta*x[(3*np+1):(4*np)],
		# Migrations
		if(nrow(moves)>0){ 
			c(sapply(1:nrow(moves),function(j){ mu*x[moves[j,1]] }),
			  sapply(1:nrow(moves),function(j){ mu*x[moves[j,1]+np] }),
			  sapply(1:nrow(moves),function(j){ mu*x[moves[j,1]+2*np] }),
			  sapply(1:nrow(moves),function(j){ mu*x[moves[j,1]+3*np] }))
		} else NULL
	)))
})



# ------------------------ Simulations -------------------------------------------------

# Return the list of parameters required from a simulation 
# Use Gauss.b() for birth pulse
# mat = metapop contact matrix 
# p: ecological parameters = list(life.span, d, K[], s[], tau[], R0, IP, rho, MP, mu)
# Note: K can be Inf to set dd=0
sim.par.DDD.MSIR <- function(mat,p) {
	list(np=nrow(mat), contact.matrix=mat, 
	     b = Gauss.b, b.par = list(s=p$s, tau=p$tau), 
	     d = p$d, dd = 1/p$K, lambda = p$life.span, 
	     beta = p$R0*(1/p$IP+1/p$life.span), gamma = 1/p$IP, rho = p$rho, eta = 1/p$MP, mu = p$mu)
}

# THIS IS THE MAIN FUNCTION FOR THE USER
# Use ssa.adaptivetau to run multiple simulations
# Parallel version
# - n.simul: positive integer
# - mat: square matrix of 0s and 1s for connections between patches
# - par: ecological parameters = list(life.span, d, K[], s[], tau[], R0, IP, rho, MP, mu)
# - t.end: positive number
# - thin: save variables at regular time steps. If NA, save all time-points
# Return a list of tables

meta.DDD.MSIR.ssa.tau <- function(n.simul, mat, par, init, t.end, thin=NA, tau.leap.par=list(epsilon=0.005)){
	foreach(1:n.simul, .inorder = F, .packages='adaptivetau') %dopar% 
	{
		sim <- ssa.adaptivetau(init,meta.DDD.MSIR.transitions(mat),meta.DDD.MSIR.Rates,sim.par.DDD.MSIR(mat,par),tf=t.end,tl.params = tau.leap.par)
		if(is.finite(thin)){
			t.vec <- seq(0,t.end,thin)
			i <- 2
			t(sapply(t.vec,function(t){
				while(sim[i,1]<t) i <<- i+1
				c(Time=t,sim[i-1,-1])
			}))
		} else sim
	}
}


# ----------------------- Statistics from stochastic simulations -----------------------------------

# Thin a simulation output at specified time steps
# sim is the output from ssa.adaptivetau(), t is a vector of time steps
ssa.thin <- function(sim,t.vec){
	i <- 2
	t(sapply(t.vec,function(t){
		while(sim[i,1]<t) i <<- i+1
		c(Time=t,sim[i-1,-1])
	}))
}

# Calculate summary statistics about infection dynamics from a single simulation
# n = number of patches
# sim = output from ssa.adaptivetau
meta.DDD.MSIR.ssa.stats <- function(sim,n){
	I.col <- (n+2):(2*n+1)
	# Matrix of presence-absence
	pres.mat <- sim[,I.col]>0
	# Global extinction
	all.ext.vec <- which(apply(pres.mat,1,sum)==0)
	all.ext.t <- if(length(all.ext.vec)==0) NA else sim[all.ext.vec[1],1]
	# 
	# RETURN
	return(list(pres.mat = pres.mat, ext = all.ext.t))
}


# ---------------------- Deterministic model -------------------------------------------
# Use transition matrix and rate function to calculate the deterministic solution
# Use deSolve package

# Calculate the derivatives dX/dt = f(t,X,p)
stoch.diff <- function(t,var,par,trans.mat,rate.fun){
	list(trans.mat %*% rate.fun(var,par,t))
}

meta.DDD.MSIR.ode <- function(meta.mat,par,init,t.end,dt=0.005){
	ode(init,seq(0,t.end,dt),stoch.diff,sim.par.DDD.MSIR(meta.mat,par),trans.mat=meta.DDD.MSIR.transitions(meta.mat),rate.fun=meta.DDD.MSIR.Rates)
}

# Use the birth-death deterministic model to calculate S(0) on a stable cycle in the absence of infection and migration.
meta.DDD.MSIR.init <- function(par){
	np <- length(par$s)
	meta.mat <- matrix(0,np,np)
	foreach(i=1:np, .combine=c) %dopar%{
		optimize(function(x){
			init <- rep(0,4*np)
			init[i] <- x
			(meta.DDD.MSIR.ode(meta.mat,par,init,t.end=1,dt=1)[2,i+1]-x)^2},
			par$K[i]*c(0.5,1.5),tol=1E-4)$minimum
	}
}

	