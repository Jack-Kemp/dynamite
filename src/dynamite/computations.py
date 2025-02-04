
from . import config
from .states import State
from .tools import complex_enabled
from .msc_tools import dnm_int_t

import numpy as np

def evolve(H, state, t, result=None, tol=None, ncv=None, algo=None, max_its=None):
    r"""
    Evolve a quantum state according to the Schrodinger equation
    under the Hamiltonian H. The units are natural, that is, the
    evolution is simply

    .. math::
        \Psi_t = e^{-iHt} \Psi_0

    Parameters
    ----------

    H : Operator
        The Hamiltonian

    state : dynamite.states.State
        A dynamite State object containing the state to be evolved.

    t : float
        The time for which to evolve. Can be negative to evolve
        backwards in time.

    result : dynamite.states.State, optional
        Where to store the result state. If not given, a new vector
        is created in which to store the result. If evolving repeatedly
        many times, it is a good idea to pass a result vector to avoid
        repeatedly allocating a lot of memory. Will be overwritten.

    tol : float, optional
        The tolerance for the evolution. Error estimation is difficult
        for Krylov exponentiation; this merely requests that the error
        be somewhat close to ``tol``. There is no guarantee that it will
        actually be smaller.

    ncv : int, optional
        The Krylov subspace size to use. Increasing subspace size can
        increase performance by reducing the number of iterations necessary,
        but also linearly increases memory usage and the number of matrix
        multiplies performed. Optimizing this parameter can significantly
        affect performance.

    algo : string, optional
        Allowed options: 'krylov' or 'expokit'. Which SLEPc algorithm to
        use to compute the matrix exponential. Default is 'expokit'.

    max_its : int, optional
        Maximum number of iterations for the solver.

    Returns
    -------
    dynamite.states.State
        The result state
    """
    state.assert_initialized()

    config._initialize()
    from slepc4py import SLEPc

    H.establish_L()

    if not H.has_subspace(state.subspace, state.subspace):
        raise ValueError('Hamiltonian and state are defined on different '
                         'subspaces.')

    if result is None:
        result = State(L=H.L, subspace=state.subspace)
    elif state.subspace != result.subspace:
        raise ValueError('input and result states are on different subspaces.')

    if t == 0.0:
        state.copy(result)
        return result

    if not complex_enabled() and t.real != 0:
        raise ValueError('configure PETSc to use complex numbers to '
                         'perform real time evolution')

    mfn = SLEPc.MFN().create()
    f = mfn.getFN()
    f.setType(SLEPc.FN.Type.EXP)

    scale = -1j*t
    if scale.imag == 0:  # imaginary time evolution, scale is real
        scale = scale.real
    f.setScale(scale)

    if algo is not None:
        mfn.setType(algo)
    else:
        mfn.setType('expokit')

    if ncv is not None:
        mfn.setDimensions(ncv)

    mfn.setTolerances(tol=tol, max_it=max_its)

    mfn.setFromOptions()
    mfn.setOperator(H.get_mat(subspaces=(state.subspace, state.subspace)))

    mfn.solve(state.vec,result.vec)

    conv = mfn.getConvergedReason()
    if conv == SLEPc.MFN.ConvergedReason.DIVERGED_ITS:
        raise MaxIterationsError('solver reached maximum number of iterations without '
                                 'converging. perhaps try increasing the max iterations with '
                                 'the options to config.initialize ["-mfn_max_it","<maxits>"].')
    elif conv == SLEPc.MFN.ConvergedReason.DIVERGED_BREAKDOWN:
        raise ConvergenceError('solver failed to converge with MFN_DIVERGED_BREAKDOWN.')
    elif conv <= 0:
        raise ConvergenceError('solver failed to converge.')

    result.set_initialized()

    return result

def eigsolve(H, getvecs=False, nev=1, which='smallest', target=None, tol=None, subspace=None, max_its=None):
    r"""
    Solve for a subset of the eigenpairs of the Hamiltonian.

    By default, solves for the eigenvalue with the smallest (most
    negative) real part, e.g. the ground state. Which eigenvalues
    are sought and how many can be adjusted with the options.

    .. note::
        Krylov algorithms have difficulty with degenerate or very nearly degenerate
        eigenvalues. Degenerate eigenvalues may be missed, and near-degenerate
        eigenstates may be inaccurate.

    .. note::
        Do not try to use this function to solve for the whole spectrum!
        It's very efficient at finding a few eigenvalues, but no
        faster than other routines for finding all of them. In the
        future an efficient solver for the whole spectrum may be
        included with dynamite.

    Parameters
    ----------

    getvecs : Bool
        Whether to return eigenvectors as well as eigenvalues.

    nev : int
        The number of eigenvalues sought. The algorithm may
        return more eigenvalues than ``nev`` if more happen to
        converge.

    which : str
        Which eigenvalues to seek. Options are\:

        - ``"smallest"``, to find the eigenvalues with smallest real part (i.e. most negative)

        - ``"largest"``, to find the eigenvalues with largest real part (i.e. most positive)

        - ``"exterior"``, to find eigenvalues largest in absolute magnitude

        - ``"target"``, to find eigenvalues closest to the given target

        If ``target`` is set, ``which`` can be omitted and will
        automatically be set to ``"target"``.

    target : float
        Using the shift-invert method, the eigensolver can seek
        the eigenvalues with real part closest to some target value.
        This requires a linear solve and so will be slower than solving
        for exterior eigenvalues.
        PETSc must be configured with a parallel linear solver
        (e.g. ``--download-mumps`` option in ``configure``) to use
        this option in parallel.

    tol : float
        The tolerance for the computation.

    subspace : dynamite.subspaces.Subspace, optional
        The subspace on which to solve for eigenvalues. If not given, defaults
        to the most recent subspace set with Operator.add_subspace, or config.subspace
        if no subspaces have been added.

    Returns
    -------
    numpy.array or tuple(numpy.array, list(dynamite.states.State))
        Either a 1D numpy array of eigenvalues, or a pair containing that array
        and a list of the corresponding eigenvectors.
    """

    H.establish_L()

    if subspace is None:
        subspace = H.subspace
    elif not H.has_subspace(subspace):
        raise ValueError('Requested subspace has not been added to operator.')

    config._initialize()
    from slepc4py import SLEPc

    eps = SLEPc.EPS().create()
    eps.setProblemType(SLEPc.EPS.ProblemType.HEP)

    if target is not None:
        which = 'target'

        if H.shell:
            raise TypeError('Shift-invert ("target") not supported for shell matrices.')

        st = eps.getST()
        st.setType(SLEPc.ST.Type.SINVERT)
        eps.setTarget(target)

    else:
        if which=='target':
            raise ValueError("Must specify target when setting which='target'")

    eps.setOperators(H.get_mat(subspaces=(subspace, subspace)))

    eps.setDimensions(nev)

    eps.setWhichEigenpairs({
        'smallest':SLEPc.EPS.Which.SMALLEST_REAL,
        'largest':SLEPc.EPS.Which.LARGEST_REAL,
        'exterior':SLEPc.EPS.Which.LARGEST_MAGNITUDE,
        'target':SLEPc.EPS.Which.TARGET_MAGNITUDE,
        }[which])

    eps.setTolerances(tol=tol, max_it=max_its)

    eps.setFromOptions()
    eps.solve()
    nconv = eps.getConverged()
    reason = eps.getConvergedReason()

    if reason == SLEPc.EPS.ConvergedReason.DIVERGED_ITS:
        _, max_its = eps.getTolerances()
        raise MaxIterationsError('eigensolver reached maximum number of '
                                 'iterations without converging. Try '
                                 'increasing the maximum iterations of the '
                                 'eigensolver via the "max_its" argument to '
                                 f'eigsolve() (current value: {max_its})')
    elif reason == SLEPc.EPS.ConvergedReason.DIVERGED_BREAKDOWN:
        raise ConvergenceError('eigsolver failed to converge with reason '
                               'EPS_DIVERGED_BREAKDOWN')
    elif reason == SLEPc.EPS.ConvergedReason.DIVERGED_SYMMETRY_LOST:
        raise ConvergenceError('eigsolver failed to converge with reason '
                               'EPS_DIVERGED_SYMMETRY_LOST')
    elif reason <= 0 or nconv < nev:
        raise ConvergenceError('eigsolver failed to converge')

    evals = np.ndarray((nconv,), dtype=float)
    evecs = []

    for i in range(nconv):
        evals[i] = eps.getEigenpair(i, None).real
        if getvecs:
            v = State(L=H.L, subspace=H.subspace)
            eps.getEigenpair(i, v.vec)
            v.set_initialized()
            evecs.append(v)

    if getvecs:
        return (evals,evecs)
    else:
        return evals

def reduced_density_matrix(state, keep):
    """
    Compute the reduced density matrix of a state vector by
    tracing out some set of spins. The spins to be kept (not traced out)
    are specified in the ``keep`` array.

    The density matrix is returned on process 0, the function
    returns a 1x1 matrix containing the value -1 on all other processes.

    Parameters
    ----------

    state : dynamite.states.State
        A dynamite State object.

    keep : array-like
        A list of spin indices to keep. Must be sorted. Note that the returned matrix
        will have dimension :math:`2^{\mathrm{len(keep)}}`, so too long a list will generate
        a huge matrix.

    Returns
    -------
    numpy.ndarray[np.complex128]
        The density matrix
    """
    state.assert_initialized()

    config._initialize()
    from ._backend import bpetsc

    if not state.subspace.product_state_basis:
        raise ValueError('reduced density matrices currently only supported '
                         'for product state basis subspace types.')

    keep = np.array(keep, dtype=dnm_int_t)

    if keep.size == 0:
        return np.array([[1]], dtype=np.complex128)

    for n in range(1, keep.size):
        if keep[n] <= keep[n-1]:
            raise ValueError('keep array must be strictly increasing')

    if any(idx < 0 for idx in keep):
        raise ValueError('spin index less than zero. keep: %s' % str(keep))

    if any(idx > state.L for idx in keep):
        raise ValueError('spin index greater than spin chain length minus one. keep: %s'
                         % str(keep))

    dm = bpetsc.reduced_density_matrix(
        state.vec, state.subspace._to_c(), keep
    )

    return dm

def entanglement_entropy(state, keep):
    """
    Compute the entanglement of a state across some cut on the
    spin chain. To be precise, this is the bipartite entropy of
    entanglement.

    Currently, this quantity is computed entirely on process 0.
    As a result, the function returns ``-1`` on all other processes.

    Parameters
    ----------
    state : dynamite.states.State
        A dynamite State object.

    keep : array-like
        A list of spin indices to keep. See :meth:`reduced_density_matrix` for
        details.

    Returns
    -------
    float
        The entanglement entropy
    """

    reduced = reduced_density_matrix(state, keep)

    # currently everything computed on process 0
    if reduced[0,0] == -1:
        return -1

    rtn = dm_entanglement_entropy(reduced)
    return rtn

def dm_entanglement_entropy(dm):
    '''
    Compute the Von Neumann entropy of a density matrix.

    Parameters
    ----------
    dm : np.array
        A density matrix

    Returns
    -------
    float
        The Von Neumann entropy
    '''
    w = np.linalg.eigvalsh(dm)

    # this is required because numpy leaves uninitialized data in the
    # out vector unless you explicitly zero it :-(
    log = np.zeros(w.shape)
    np.log(w, where=w > 0, out=log)

    rtn = -np.sum(w * log)
    return rtn

def renyi_entropy(state, keep, alpha, method='eigsolve'):
    r"""
    Compute the Renyi entropy of the density matrix that results from tracing out
    some spins. The Renyi entropy is

    .. math::

        H_{\alpha} = \frac{1}{1 - \alpha} \log \mathrm{Tr} \left[ \rho ^ \alpha \right]

    Arbitrary non-negative values of ``alpha`` are allowed; in the special cases
    of :math:`\alpha \in \{ 0, 1 \}` the function is computed in the limit.

    Currently, this quantity is computed entirely on process 0.
    As a result, the function returns ``-1`` on all other processes.

    Parameters
    ----------
    state : dynamite.states.State
        A dynamite State object.

    keep : array-like
        A list of spin indices to keep. See :meth:`reduced_density_matrix` for
        details.

    alpha : float, int, or str
        The value of :math:`\alpha` from the definition of Renyi entropy.

    method : str, optional
        Whether to compute the Renyi entropy by solving for eigenvalues, or computing
        a matrix power and doing a trace. One or the other may be faster depending on the
        specific problem. Options: ``eigsolve`` or ``matrix_power``.

    Returns
    -------
    float
        The Renyi entropy
    """

    reduced = reduced_density_matrix(state, keep)

    # currently everything computed on process 0
    if reduced[0,0] == -1:
        return -1

    rtn = dm_renyi_entropy(reduced, alpha, method)
    return rtn

def dm_renyi_entropy(dm, alpha, method='eigsolve'):
    '''
    Compute the Renyi entropy of a density matrix. See :meth:`renyi_entropy`
    for details.

    Parameters
    ----------
    dm : np.array
        A density matrix

    alpha : int, float, or str
        The value of alpha in the definition of Renyi entropy.

    method : str
        Whether to compute the Renyi entropy by solving for eigenvalues, or computing
        a matrix power and doing a trace. One or the other may be faster depending on the
        specific problem. Options: ``eigsolve`` or ``matrix_power``.

    Returns
    -------
    float
        The Renyi entropy
    '''

    # special cases
    if alpha == 0: # H_0 = log|X|
        eps = 1E-10
        eigs = np.linalg.eigvalsh(dm)
        support = np.sum(eigs > eps)
        return np.log(support)

    elif alpha == 1: # H_1 = Von Neumann entropy
        return dm_entanglement_entropy(dm)

    elif alpha == 'inf':
        eigs = np.linalg.eigvalsh(dm)
        return -np.log(np.max(eigs))

    # compute the trace of rho**alpha
    if method == 'matrix_power':
        if alpha == int(alpha):
            powered = np.linalg.matrix_power(dm, int(alpha))
        else:
            raise TypeError('alpha must be an integer for matrix_power method.')
        trace = np.trace(powered).real

    elif method == 'eigsolve':
        w = np.linalg.eigvalsh(dm)
        trace = np.sum(w**alpha)

    else:
        raise ValueError('Valid methods are "eigsolve" and "matrix_power"')

    return 1/(1-alpha) * np.log(trace)

def get_tstep(ncv,nrm,tol=1E-7):
    """
    Compute the length of a sub-step in a Expokit matrix
    exponential solve.
    """
    f = ((ncv+1)/2.72)**(ncv+1) * np.sqrt(2*np.pi*(ncv+1))
    t = ((1/nrm)*(f*tol)/(4.0*nrm))**(1/ncv)
    s = 10.0**(np.floor(np.log10(t))-1)
    return np.ceil(t/s)*s

def estimate_compute_time(t,ncv,nrm,tol=1E-7):
    """
    Estimate compute time in units of matrix multiplies, for
    an expokit exponential solve.
    """
    tstep = get_tstep(ncv,nrm,tol)
    iters = np.ceil(t/tstep)
    return ncv*iters

class ConvergenceError(Exception):
    pass

class MaxIterationsError(ConvergenceError):
    pass
