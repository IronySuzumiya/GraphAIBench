// Copyright 2020 MIT
// Authors: Xuhao Chen <cxh@mit.edu>
#include "graph_gpu.h"
#include "utils.cuh"
#include "worklist.cuh"
#include "cuda_launch_config.hpp"
#include <cub/cub.cuh>

typedef cub::BlockScan<int, BLOCK_SIZE> BlockScan;
typedef Worklist2<vidType, vidType> WLGPU;

__global__ void insert(vidType source, WLGPU queue) {
  int id = blockIdx.x * blockDim.x + threadIdx.x;
  if (id == 0) queue.push(source);
}

__device__ __forceinline__ void process_edge(GraphGPU g, vidType src, eidType edge, 
                                             elabel_t *dist, WLGPU &outwl) {
  auto  dst = g.getEdgeDst(edge);
  elabel_t new_dist = dist[src] + g.getEdgeData(edge);
  if (new_dist < dist[dst]) {
    atomicMin(&dist[dst], new_dist);
    outwl.push(dst);
  }
}

__device__ __forceinline__
void expandByCta(GraphGPU g, elabel_t *dist, WLGPU &inwl, WLGPU &outwl) {
  int id = blockIdx.x * blockDim.x + threadIdx.x;
  vidType vertex;
  __shared__ int owner;
  __shared__ vidType sh_vertex;
  owner = -1;
  int size = 0;
  if (inwl.pop_id(id, vertex)) {
    size = g.get_degree(vertex);
  }
  while (true) {
    if (size > BLOCK_SIZE)
      owner = threadIdx.x;
    __syncthreads();
    if (owner == -1) break;
    __syncthreads();
    if (owner == threadIdx.x) {
      sh_vertex = vertex;
      inwl.invalidate(id);
      owner = -1;
      size = 0;
    }
    __syncthreads();
    auto row_begin = g.edge_begin(sh_vertex);
    auto row_end = g.edge_end(sh_vertex);
    auto neighbor_size = row_end - row_begin;
    auto num = ((neighbor_size + blockDim.x - 1) / blockDim.x) * blockDim.x;
    for (auto i = threadIdx.x; i < num; i += blockDim.x) {
      auto edge = row_begin + i;
      if (i < neighbor_size)
        process_edge(g, sh_vertex, edge, dist, outwl);
      /*
      if (i < neighbor_size) {
      vidType dst = 0;
      vidType ncnt = 0;
      if (i < neighbor_size) {
        dst = g.getEdgeDst(edge);
        elabel_t new_dist = dist[sh_vertex] + g.getEdgeData(edge);
        if (new_dist < dist[dst]) {
          atomicMin(&dist[dst], new_dist);
          ncnt = 1;
        }
      }
      outwl.push_1item<BlockScan>(ncnt, dst);
      //*/
    }
  }
}

__device__ __forceinline__ void expandByWarp(GraphGPU g, elabel_t *dist, WLGPU &inwl, WLGPU &outwl) {
  int id = blockIdx.x * blockDim.x + threadIdx.x;
  int warp_id = threadIdx.x >> LOG_WARP_SIZE;
  unsigned lane_id = LaneId();
  __shared__ int owner[NUM_WARPS];
  __shared__ vidType sh_vertex[NUM_WARPS];
  owner[warp_id] = -1;
  int size = 0;
  vidType vertex;
  if (inwl.pop_id(id, vertex)) {
    if (vertex != -1)
      size = g.get_degree(vertex);
  }
  while (__any_sync(0xFFFFFFFF, size) >= WARP_SIZE) {
    if (size >= WARP_SIZE)
      owner[warp_id] = lane_id;
    if (owner[warp_id] == lane_id) {
      sh_vertex[warp_id] = vertex;
      inwl.invalidate(id);
      owner[warp_id] = -1;
      size = 0;
    }
    auto winner = sh_vertex[warp_id];
    auto row_begin = g.edge_begin(winner);
    auto row_end = g.edge_end(winner);
    auto neighbor_size = row_end - row_begin;
    auto num = ((neighbor_size + WARP_SIZE - 1) / WARP_SIZE) * WARP_SIZE;
    for (auto i = lane_id; i < num; i+= WARP_SIZE) {
      auto edge = row_begin + i;
      if (i < neighbor_size) {
        process_edge(g, winner, edge, dist, outwl);
      }
    }
  }
}

__global__ void bellman_ford(GraphGPU g, elabel_t *dist, WLGPU inwl, WLGPU outwl) {
  expandByCta(g, dist, inwl, outwl);
  expandByWarp(g, dist, inwl, outwl);
  int id = blockIdx.x * blockDim.x + threadIdx.x;
  vidType vertex;
  const int SCRATCHSIZE = BLOCK_SIZE;
  __shared__ BlockScan::TempStorage temp_storage;
  __shared__ eidType gather_offsets[SCRATCHSIZE];
  __shared__ vidType src[SCRATCHSIZE];
  gather_offsets[threadIdx.x] = 0;
  eidType neighboroffset = 0;
  int neighborsize = 0;
  int scratch_offset = 0;
  int total_edges = 0; // this has to be signed integer
  if (inwl.pop_id(id, vertex)) {	  
    if (vertex != -1) {
      neighboroffset = g.edge_begin(vertex);
      neighborsize = g.get_degree(vertex);
    }
  }
  BlockScan(temp_storage).ExclusiveSum(neighborsize, scratch_offset, total_edges);
  int done = 0;
  int neighborsdone = 0;
  while (total_edges > 0) {
    __syncthreads();
    int i;
    for (i = 0; neighborsdone + i < neighborsize && (scratch_offset + i - done) < SCRATCHSIZE; i++) {
      gather_offsets[scratch_offset + i - done] = neighboroffset + neighborsdone + i;
      src[scratch_offset + i - done] = vertex;
    }
    neighborsdone += i;
    scratch_offset += i;
    __syncthreads();
    auto edge = gather_offsets[threadIdx.x];
    if (threadIdx.x < total_edges) {
      process_edge(g, src[threadIdx.x], edge, dist, outwl);
    }
    total_edges -= BLOCK_SIZE;
    done += BLOCK_SIZE;
  }
}

void SSSPSolver(Graph &g, vidType source, elabel_t *h_dist, int delta) {
  size_t memsize = print_device_info(0);
  auto nv = g.num_vertices();
  auto ne = g.num_edges();
  auto md = g.get_max_degree();
  size_t mem_graph = size_t(nv+1)*sizeof(eidType) + size_t(2)*size_t(ne)*sizeof(vidType);
  std::cout << "GPU_total_mem = " << memsize << " graph_mem = " << mem_graph << "\n";

  GraphGPU gg(g);
  size_t nthreads = BLOCK_SIZE;
  size_t nblocks = (nv-1)/nthreads+1;
  assert(nblocks < 65536);
  cudaDeviceProp deviceProp;
  CUDA_SAFE_CALL(cudaGetDeviceProperties(&deviceProp, 0));
  auto max_blocks_per_SM = maximum_residency(bellman_ford, nthreads, 0);
  std::cout << "max_blocks_per_SM = " << max_blocks_per_SM << "\n";
  //size_t max_blocks = max_blocks_per_SM * deviceProp.multiProcessorCount;
  //nblocks = std::min(max_blocks, nblocks);
  std::cout << "CUDA SSSP Bellman-Ford TWC (" << nblocks << " CTAs, " << nthreads << " threads/CTA)\n";

  elabel_t zero = 0;
  elabel_t * d_dist;
  CUDA_SAFE_CALL(cudaMalloc((void **)&d_dist, nv * sizeof(elabel_t)));
  CUDA_SAFE_CALL(cudaMemcpy(d_dist, h_dist, nv * sizeof(elabel_t), cudaMemcpyHostToDevice));
  CUDA_SAFE_CALL(cudaMemcpy(&d_dist[source], &zero, sizeof(zero), cudaMemcpyHostToDevice));
  CUDA_SAFE_CALL(cudaDeviceSynchronize());
  WLGPU wl1(ne), wl2(ne);
  WLGPU *inwl = &wl1, *outwl = &wl2;

  Timer t;
  t.Start();
  int iter = 0;
  int nitems = 1;
  insert<<<1, 1>>>(source, *inwl);
  nitems = inwl->nitems();
  while(nitems > 0) {
    ++ iter;
    nblocks = (nitems + BLOCK_SIZE - 1) / BLOCK_SIZE; 
    printf("iteration %d: frontier_size = %d\n", iter, nitems);
    bellman_ford<<<nblocks, BLOCK_SIZE>>>(gg, d_dist, *inwl, *outwl);
    nitems = outwl->nitems();
    WLGPU *tmp = inwl;
    inwl = outwl;
    outwl = tmp;
    outwl->reset();
  };
  CUDA_SAFE_CALL(cudaDeviceSynchronize());
  t.Stop();

  std::cout << "iterations = " << iter << ".\n";
  std::cout << "runtime [sssp_gpu_twc] = " << t.Seconds() << " sec\n";
  std::cout << "throughput = " << double(ne) / t.Seconds() / 1e9 << " billion Traversed Edges Per Second (TEPS)\n";
 
  CUDA_SAFE_CALL(cudaMemcpy(h_dist, d_dist, nv * sizeof(elabel_t), cudaMemcpyDeviceToHost));
  CUDA_SAFE_CALL(cudaFree(d_dist));
  return;
}

void BFSSolver(Graph &g, vidType source, vidType *dist) {}
