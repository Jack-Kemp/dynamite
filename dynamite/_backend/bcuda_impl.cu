
#include "bcuda_impl.h"

#ifdef PETSC_USE_64BIT_INDICES
  #define CUDA_POPCOUNT(x) (__popcll(x))
#else
  #define CUDA_POPCOUNT(x) (__popc(x))
#endif

#define CUDA_PARITY(x) (CUDA_POPCOUNT(x)&1)

#define TERM_REAL_CUDA(mask, sign) (!CUDA_PARITY((mask) & (sign)))

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

__device__ PetscInt S2I_CUDA_Parity(PetscInt state, const data_Parity* data) {
  return (CUDA_PARITY(state) == data->space) ? state>>1 : (PetscInt)(-1);
}

__device__ PetscInt I2S_CUDA_Parity(PetscInt idx, const data_Parity* data) {
  return (idx<<1) | (CUDA_PARITY(idx) ^ data->space);
}

PetscErrorCode CopySubspaceData_CUDA_SpinConserve(data_SpinConserve** out_p, const data_SpinConserve* in) {
  PetscErrorCode ierr;
  cudaError_t err;
  PetscInt len_nchoosek = (in->k+1)*in->ld_nchoosek;

  data_SpinConserve cpu_data;

  ierr = PetscMemcpy(&cpu_data, in, sizeof(data_SpinConserve));CHKERRQ(ierr);

  err = cudaMalloc(&(cpu_data.nchoosek), sizeof(PetscInt)*len_nchoosek);CHKERRCUDA(err);
  err = cudaMemcpy(cpu_data.nchoosek, in->nchoosek,
		   sizeof(PetscInt)*len_nchoosek, cudaMemcpyHostToDevice);CHKERRCUDA(err);

  err = cudaMalloc((void **) out_p, sizeof(data_SpinConserve));CHKERRCUDA(err);
  err = cudaMemcpy(*out_p, &cpu_data, sizeof(data_SpinConserve), cudaMemcpyHostToDevice);CHKERRCUDA(err);

  return ierr;
}

PetscErrorCode DestroySubspaceData_CUDA_SpinConserve(data_SpinConserve* data) {
  cudaError_t err;

  data_SpinConserve cpu_data;

  err = cudaMemcpy(&cpu_data, data, sizeof(data_SpinConserve), cudaMemcpyDeviceToHost);CHKERRCUDA(err);

  err = cudaFree(cpu_data.nchoosek);CHKERRCUDA(err);
  err = cudaFree(data);CHKERRCUDA(err);
  return 0;
}

__device__ PetscInt S2I_CUDA_SpinConserve(PetscInt state, const data_SpinConserve* data) {
  PetscInt idx = 0;
  PetscInt k = 0;

  if (state >> data->L) return (PetscInt)(-1);
  if (CUDA_POPCOUNT(state) != data->k) return (PetscInt)(-1);

  for (PetscInt n=0; n<data->L; ++n) {
    if (state & 1) {
      k++;
      if (k <= n) idx += data->nchoosek[k*data->ld_nchoosek + n];
    }
    state >>= 1;
    if (state == 0) return idx ;
  }
  return idx ;
}

__device__ PetscInt I2S_CUDA_SpinConserve(PetscInt idx, const data_SpinConserve* data) {
  PetscInt state = 0;
  PetscInt k = data->k;
  PetscInt current;
  for (PetscInt n=data->L; n>0; --n) {
    state <<= 1;
    current = (k > n-1) ? 0 : data->nchoosek[k*data->ld_nchoosek + n-1];
    if (idx >= current) {
        idx -= current;
        k--;
        state |= 1 ;
    }
  }
  return state;
}

PetscErrorCode CopySubspaceData_CUDA_Auto(data_Auto** out_p, const data_Auto* in) {
  PetscErrorCode ierr;
  cudaError_t err;

  data_Auto cpu_data;

  ierr = PetscMemcpy(&cpu_data, in, sizeof(data_Auto));CHKERRQ(ierr);

  err = cudaMalloc(&(cpu_data.state_map), sizeof(PetscInt)*in->dim);CHKERRCUDA(err);
  err = cudaMemcpy(cpu_data.state_map, in->state_map,
    sizeof(PetscInt)*in->dim, cudaMemcpyHostToDevice);CHKERRCUDA(err);

  err = cudaMalloc(&(cpu_data.rmap_indices), sizeof(PetscInt)*in->dim);CHKERRCUDA(err);
  err = cudaMemcpy(cpu_data.rmap_indices, in->rmap_indices,
    sizeof(PetscInt)*in->dim, cudaMemcpyHostToDevice);CHKERRCUDA(err);

  err = cudaMalloc(&(cpu_data.rmap_states), sizeof(PetscInt)*in->dim);CHKERRCUDA(err);
  err = cudaMemcpy(cpu_data.rmap_states, in->rmap_states,
    sizeof(PetscInt)*in->dim, cudaMemcpyHostToDevice);CHKERRCUDA(err);

  err = cudaMalloc((void **) out_p, sizeof(data_Auto));CHKERRCUDA(err);
  err = cudaMemcpy(*out_p, &cpu_data, sizeof(data_Auto), cudaMemcpyHostToDevice);CHKERRCUDA(err);

  return ierr;
}

PetscErrorCode DestroySubspaceData_CUDA_Auto(data_Auto* data) {
  cudaError_t err;

  data_Auto cpu_data;

  err = cudaMemcpy(&cpu_data, data, sizeof(data_Auto), cudaMemcpyDeviceToHost);CHKERRCUDA(err);

  err = cudaFree(cpu_data.state_map);CHKERRCUDA(err);
  err = cudaFree(cpu_data.rmap_indices);CHKERRCUDA(err);
  err = cudaFree(cpu_data.rmap_states);CHKERRCUDA(err);
  err = cudaFree(data);CHKERRCUDA(err);
  return 0;
}

/* TODO: this is really not well suited for GPUs */
/* but I bet we can do something clever! */
__device__ PetscInt S2I_CUDA_Auto(PetscInt state, const data_Auto* data) {
  PetscInt left, right, mid;
  left = 0;
  right = data->dim;
  while (left <= right) {
    mid = left + (right-left)/2;
    if (data->rmap_states[mid] == state) {
      return data->rmap_indices[mid];
    }

    if (data->rmap_states[mid] < state) {
      left = mid + 1;
    }
    else {
      right = mid - 1;
    }
  }
  /* element was not in the array */
  return -1;
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

  #define RIGHT_SUBSPACE SpinConserve
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

  #define RIGHT_SUBSPACE SpinConserve
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE Auto
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE
#undef LEFT_SUBSPACE

#define LEFT_SUBSPACE SpinConserve
  #define RIGHT_SUBSPACE Full
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE Parity
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE SpinConserve
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

  #define RIGHT_SUBSPACE SpinConserve
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE

  #define RIGHT_SUBSPACE Auto
    #include "bcuda_template.cu"
  #undef RIGHT_SUBSPACE
#undef LEFT_SUBSPACE
