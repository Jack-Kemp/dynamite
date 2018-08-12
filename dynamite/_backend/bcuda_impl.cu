
#include "bcuda_impl.h"

#ifdef PETSC_USE_64BIT_INDICES
  #define TERM_REAL_CUDA(mask, sign) (!(__popcll((mask) & (sign)) & 1))
#else
  #define TERM_REAL_CUDA(mask, sign) (!(__popc((mask) & (sign)) & 1))
#endif

/* subspace functions for the GPU */

// TODO: use constant memory for the subspace data
// TODO: should pass each subspace data member individually to kernel?

PetscErrorCode CopySubspaceData_CUDA_Full(data_Full** out_p, const data_Full* in) {
  cudaError_t err;
  err = cudaMalloc((void **) out_p, sizeof(data_Full));CHKERRCUDA(err);
  err = cudaMemcpy(*out_p, in, sizeof(data_Full), cudaMemcpyHostToDevice);CHKERRCUDA(err);
  return 0;
}

PetscErrorCode DestroySubspaceData_CUDA_Full(data_Full* data) {
  cudaError_t err;
  err = cudaFree(data);CHKERRCUDA(err);
  return 0;
}

__device__ PetscInt S2I_CUDA_Full(PetscInt state, const data_Full* data) {
  return state;
}

__device__ PetscInt I2S_CUDA_Full(PetscInt idx, const data_Full* data) {
  return idx;
}

PetscErrorCode CopySubspaceData_CUDA_Parity(data_Parity** out_p, const data_Parity* in) {
  cudaError_t err;
  err = cudaMalloc((void **) out_p, sizeof(data_Parity));CHKERRCUDA(err);
  err = cudaMemcpy(*out_p, in, sizeof(data_Parity), cudaMemcpyHostToDevice);CHKERRCUDA(err);
  return 0;
}

PetscErrorCode DestroySubspaceData_CUDA_Parity(data_Parity* data) {
  cudaError_t err;
  err = cudaFree(data);CHKERRCUDA(err);
  return 0;
}

#define PARITY_BIT(L) (1<<((L)-1))
#define PARITY_MASK(L) (PARITY_BIT(L)-1)

__device__ PetscInt S2I_CUDA_Parity(PetscInt state, const data_Parity* data) {
  return state & PARITY_MASK(data->L);
}

__device__ PetscInt I2S_CUDA_Parity(PetscInt idx, const data_Parity* data) {
#ifdef PETSC_USE_64BIT_INDICES
  return idx | (( (data->space)^__popcll(idx)&1 ) << (data->L - 1) );
#else
  return idx | (( (data->space)^__popc(idx)&1 ) << (data->L - 1) );
#endif
}

PetscErrorCode CopySubspaceData_CUDA_Auto(data_Auto** out_p, const data_Auto* in) {
  PetscErrorCode ierr;
  cudaError_t err;

  data_Auto cpu_data;

  ierr = PetscMemcpy(&cpu_data, in, sizeof(data_Auto));CHKERRQ(ierr);

  err = cudaMalloc(&(cpu_data.state_map), sizeof(PetscInt)*in->dim);CHKERRCUDA(err);
  err = cudaMemcpy(cpu_data.state_map, in->state_map,
    sizeof(PetscInt)*in->dim, cudaMemcpyHostToDevice);CHKERRCUDA(err);

  err = cudaMalloc(&(cpu_data.state_rmap), sizeof(PetscInt)*in->rdim);CHKERRCUDA(err);
  err = cudaMemcpy(cpu_data.state_rmap, in->state_rmap,
    sizeof(PetscInt)*in->rdim, cudaMemcpyHostToDevice);CHKERRCUDA(err);

  err = cudaMalloc((void **) out_p, sizeof(data_Auto));CHKERRCUDA(err);
  err = cudaMemcpy(*out_p, &cpu_data, sizeof(data_Auto), cudaMemcpyHostToDevice);CHKERRCUDA(err);

  return ierr;
}

PetscErrorCode DestroySubspaceData_CUDA_Auto(data_Auto* data) {
  cudaError_t err;

  data_Auto cpu_data;

  err = cudaMemcpy(&cpu_data, data, sizeof(data_Auto), cudaMemcpyDeviceToHost);CHKERRCUDA(err);

  err = cudaFree(cpu_data.state_map);CHKERRCUDA(err);
  err = cudaFree(cpu_data.state_rmap);CHKERRCUDA(err);
  err = cudaFree(data);CHKERRCUDA(err);
  return 0;
}

/* this is really not well suited for GPUs */
/* but I bet we can do something clever! */
__device__ PetscInt S2I_CUDA_Auto(PetscInt state, const data_Auto* data) {
  return data->state_rmap[state];
}

__device__ PetscInt I2S_CUDA_Auto(PetscInt idx, const data_Auto* data) {
  return data->state_map[idx];
}

PetscErrorCode MatCreateVecs_GPU(Mat mat, Vec *right, Vec *left)
{
  PetscErrorCode ierr;
  PetscInt M, N;

  ierr = MatGetSize(mat, &M, &N);CHKERRQ(ierr);

  if (right) {
    ierr = VecCreate(PetscObjectComm((PetscObject)mat),right);CHKERRQ(ierr);
    ierr = VecSetSizes(*right, PETSC_DECIDE, N);CHKERRQ(ierr);
    ierr = VecSetFromOptions(*right);
  }
  if (left) {
    ierr = VecCreate(PetscObjectComm((PetscObject)mat),left);CHKERRQ(ierr);
    ierr = VecSetSizes(*left, PETSC_DECIDE, M);CHKERRQ(ierr);
    ierr = VecSetFromOptions(*left);
  }

  return 0;
}

__device__ static __inline__ void add_real(PetscScalar *x, PetscReal r) {
  PetscReal *real_part;
  real_part = (PetscReal*) x;
  (*real_part) += r;
}

__device__ static __inline__ void add_imag(PetscScalar *x, PetscReal c) {
  PetscReal *imag_part;
  imag_part = ((PetscReal*)x) + 1;
  (*imag_part) += c;
}

#define LEFT_SUBSPACE Full
  #define RIGHT_SUBSPACE Full
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE Parity
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE Auto
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE
#undef LEFT_SUBSPACE

#define LEFT_SUBSPACE Parity
  #define RIGHT_SUBSPACE Full
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE Parity
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE Auto
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE
#undef LEFT_SUBSPACE

#define LEFT_SUBSPACE Auto
  #define RIGHT_SUBSPACE Full
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE Parity
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE Auto
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE
#undef LEFT_SUBSPACE
