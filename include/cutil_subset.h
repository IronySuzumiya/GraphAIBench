#pragma once
#include <cuda_runtime.h>

#define CUDA_RT_CALL(call)                                                                  \
    {                                                                                       \
        cudaError_t cudaStatus = call;                                                      \
        if (cudaSuccess != cudaStatus) {                                                    \
            fprintf(stderr,                                                                 \
                    "ERROR: CUDA RT call \"%s\" in line %d of file %s failed "              \
                    "with "                                                                 \
                    "%s (%d).\n",                                                           \
                    #call, __LINE__, __FILE__, cudaGetErrorString(cudaStatus), cudaStatus); \
            exit( cudaStatus );                                                             \
        }                                                                                   \
    }

#  define CUDA_SAFE_CALL_NO_SYNC( call) {                                      \
    cudaError err = call;                                                      \
    if( cudaSuccess != err) {                                                  \
        fprintf(stderr, "error %d: Cuda error in file '%s' in line %i : %s.\n",\
                err, __FILE__, __LINE__, cudaGetErrorString( err) );           \
        exit(EXIT_FAILURE);                                                    \
    } }

#  define CUDA_SAFE_CALL( call)     CUDA_SAFE_CALL_NO_SYNC(call);              \

#  define CUDA_SAFE_THREAD_SYNC( ) {                                           \
    cudaError err = CUT_DEVICE_SYNCHRONIZE();                                  \
    if ( cudaSuccess != err) {                                                 \
        fprintf(stderr, "Cuda error in file '%s' in line %i : %s.\n",          \
                __FILE__, __LINE__, cudaGetErrorString( err) );                \
    } }

#if __CUDACC_VER_MAJOR__ >= 9
#define SHFL_DOWN(a,b) __shfl_down_sync(0xFFFFFFFF,a,b)
#define SHFL(a,b) __shfl_sync(0xFFFFFFFF,a,b)
#else
#define SHFL_DOWN(a,b) __shfl_down(a,b)
#define SHFL(a,b) __shfl(a,b)
#endif

// you must first call the cudaGetDeviceProperties() function, then pass
// the devProp structure returned to this function:
int getSPcores(cudaDeviceProp devProp) {
  int cores = 0;
  int mp = devProp.multiProcessorCount;
  switch (devProp.major){
    case 2: // Fermi
      if (devProp.minor == 1) cores = mp * 48;
      else cores = mp * 32;
      break;
    case 3: // Kepler
      cores = mp * 192;
      break;
    case 5: // Maxwell
      cores = mp * 128;
      break;
    case 6: // Pascal
      if ((devProp.minor == 1) || (devProp.minor == 2)) cores = mp * 128;
      else if (devProp.minor == 0) cores = mp * 64;
      else printf("Unknown device type\n");
      break;
    case 7: // Volta and Turing
      if ((devProp.minor == 0) || (devProp.minor == 5)) cores = mp * 64;
      else printf("Unknown device type\n");
      break;
    case 8: // Ampere
      if (devProp.minor == 0) cores = mp * 64;
      else if (devProp.minor == 6) cores = mp * 128;
      else printf("Unknown device type\n");
      break;
    default:
      printf("Unknown device type\n");
      break;
  }
  return cores;
}

static size_t print_device_info(int print_num, bool disable = false) {
  int deviceCount = 0;
  CUDA_SAFE_CALL(cudaGetDeviceCount(&deviceCount));
  if (!disable) printf("Found %d devices\n", deviceCount);
  // Another way to get the # of cores: #include <helper_cuda.h> in this link:
  // https://github.com/NVIDIA/cuda-samples/blob/6be514679b201c8a0f0cda050bc7c01c8cda32ec/Common/helper_cuda.h
  //int CUDACores = _ConvertSMVer2Cores(props.major, props.minor) * props.multiProcessorCount;
  size_t mem_size = 0;
  for (int device = 0; device < deviceCount; device++) {
    cudaDeviceProp prop;
    CUDA_SAFE_CALL(cudaSetDevice(device));
    CUDA_SAFE_CALL(cudaGetDeviceProperties(&prop, device));
    if (device == 0) mem_size = prop.totalGlobalMem;
    if (disable) break;
    printf("  Device[%d]: %s\n", device, prop.name);
    if (device == 0 || print_num > 0) {
      printf("  Compute capability: %d.%d\n", prop.major, prop.minor);
      printf("  Warp size: %d\n", prop.warpSize);
      printf("  Total # SM: %d\n", prop.multiProcessorCount);
      printf("  Total # CUDA cores: %d\n", getSPcores(prop));
      printf("  Total amount of shared memory per block: %lu bytes\n", prop.sharedMemPerBlock);
      printf("  Total # registers per block: %d\n", prop.regsPerBlock);
      printf("  Total amount of constant memory: %lu bytes\n", prop.totalConstMem);
      printf("  Total global memory: %.1f GB\n", float(prop.totalGlobalMem)/float(1024*1024*1024));
      printf("  Memory Clock Rate: %.2f GHz\n", float(prop.memoryClockRate)/float(1024*1024));
      printf("  Memory Bus Width: %d bits\n", prop.memoryBusWidth);
      //printf("  Maximum memory pitch: %u\n", prop.memPitch);
      printf("  Peak Memory Bandwidth: %.2f GB/s\n\n", 2.0*prop.memoryClockRate*(prop.memoryBusWidth/8)/1.0e6);
    }
  }
  return mem_size;
}

static size_t get_gpu_mem_size(int device = 0) {
  cudaDeviceProp prop;
  CUDA_SAFE_CALL(cudaGetDeviceProperties(&prop, device));
  return prop.totalGlobalMem;
}

template <typename NumeratorT, typename DenominatorT>
__host__ __device__ __forceinline__ constexpr NumeratorT
DivideAndRoundUp(NumeratorT n, DenominatorT d) {
  // Static cast to undo integral promotion.
  return static_cast<NumeratorT>(n / d + (n % d != 0 ? 1 : 0));
}

template <typename T = vidType>
void allocate_gpu_buffer(size_t n, T*& ptr) {
  //std::cout << "allocating GPU memory: size = " << n << "\n";
  size_t total_buffer_size = n * sizeof(T);
  std::cout << "Allocated memory for buffers: " << float(total_buffer_size)/float(1024*1024) << " MB\n";
  CUDA_SAFE_CALL(cudaMalloc((void**)&ptr, total_buffer_size));
}

