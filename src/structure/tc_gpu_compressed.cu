// Copyright (c) 2022 MIT
// Author: Xuhao Chen
#include "graph_gpu.h"
#include "cuda_launch_config.hpp"

typedef cub::BlockReduce<AccType, BLOCK_SIZE> BlockReduce;
#define WARP_CENTRIC
//#define USE_HINDEX
#define VERTEX_PARALLEL
#define USE_ZERO_COPY 1

#ifdef USE_HINDEX
#ifdef WARP_CENTRIC
#ifdef VERTEX_PARALLEL
#include "triangle_hindex_warp_vertex_compressed.cuh"
#else
#include "triangle_hindex_warp_edge_compressed.cuh"
#endif
#else
#ifdef VERTEX_PARALLEL
#include "triangle_hindex_cta_vertex_compressed.cuh"
#else
#include "triangle_hindex_cta_edge_compressed.cuh"
#endif
#endif
#else // USE_BinarySearch
#ifdef VERTEX_PARALLEL
#include "triangle_bs_warp_vertex_compressed.cuh"
#else
#include "triangle_bs_warp_edge_compressed.cuh"
#endif
#endif

void triangle_count(Graph &g, uint64_t &total) {}

void triangle_count_compressed(Graph &g, uint64_t &total, vidType num_cached = 5000) {
  size_t memsize = print_device_info(0);
#ifndef VERTEX_PARALLEL
  if (!USE_ZERO_COPY && g.is_compressed_only()) g.decompress(); 
#endif
  GraphGPU gg(g);

  // kernel launch configuration
  size_t nthreads = BLOCK_SIZE, nblocks = (g.V()-1)/nthreads+1;
  if (nblocks > 65536) nblocks = 65536;
#ifdef VERTEX_PARALLEL
#ifdef USE_HINDEX
  refine_kernel_config(nthreads, nblocks, hindex_warp_vertex_compressed);
#else
  refine_kernel_config(nthreads, nblocks, bs_warp_vertex_compressed);
  //refine_kernel_config(nthreads, nblocks, bs_warp_vertex_compressed_cached);
#endif
#else
  auto nnz = gg.init_edgelist(g, 0, 0, USE_ZERO_COPY); // streaming edgelist using zero-copy
  nblocks = (nnz-1)/WARPS_PER_BLOCK+1;
  if (nblocks > 65536) nblocks = 65536;
#ifdef USE_HINDEX
  refine_kernel_config(nthreads, nblocks, hindex_warp_edge_compressed);
#else
  refine_kernel_config(nthreads, nblocks, bs_warp_edge_compressed);
#endif
#endif
  std::cout << "CUDA kernel (" << nblocks << " CTAs, " << nthreads << " threads/CTA)\n";

  std::cout << "Allocating buffer for decompressed adjacency lists\n";
  vidType *buffer;
  size_t num_per_block = WARPS_PER_BLOCK;
#ifndef WARP_CENTRIC
  num_per_block = 1;
#endif
  allocate_gpu_buffer(3 * size_t(g.get_max_degree()) * num_per_block * nblocks, buffer);

#ifdef USE_HINDEX
  std::cout << "Allocating buckets for the hash map\n";
  vidType *bins;
  allocate_gpu_buffer(NUM_BUCKETS * BUCKET_SIZE * WARPS_PER_BLOCK * nblocks, bins);
  auto bins_mem = NUM_BUCKETS * BUCKET_SIZE * WARPS_PER_BLOCK * nblocks * sizeof(vidType);
  CUDA_SAFE_CALL(cudaMemset(bins, 0, bins_mem));
#endif

  AccType h_total = 0, *d_total;
  CUDA_SAFE_CALL(cudaMalloc((void **)&d_total, sizeof(AccType)));
  CUDA_SAFE_CALL(cudaMemcpy(d_total, &h_total, sizeof(AccType), cudaMemcpyHostToDevice));
  CUDA_SAFE_CALL(cudaDeviceSynchronize());

  Timer t;
  t.Start();
#ifdef USE_HINDEX
  std::cout << "Using HINDEX ";
#ifdef VERTEX_PARALLEL
  std::cout << "vertex-parallel ";
#ifdef WARP_CENTRIC
  std::cout << "warp-centric\n";
  hindex_warp_vertex_compressed<<<nblocks, nthreads>>>(gg, bins, buffer, d_total);
#else // cta centric
  std::cout << "cta-centric\n";
  hindex_cta_vertex_compressed<<<nblocks, nthreads>>>(gg, bins, buffer, d_total, num_cached);
#endif
#else // edge parallel
  std::cout << "edge-parallel ";
#ifdef WARP_CENTRIC
  std::cout << "warp-centric\n";
  hindex_warp_edge_compressed<<<nblocks, nthreads>>>(gg, bins, buffer, d_total);
  //hindex_warp_edge_compressed_cache<<<nblocks, nthreads>>>(gg, bins, buffer, d_total, num_cached);
#else // cta centric
  std::cout << "cta-centric\n";
  hindex_cta_edge_compressed<<<nblocks, nthreads>>>(gg, bins, buffer, d_total);
#endif
#endif // end vertex/edge parallel
#else // USE_BinarySearch
  std::cout << "Using BinarySearch ";
#ifdef VERTEX_PARALLEL
  std::cout << "vertex-parallel ";
#ifdef WARP_CENTRIC
  std::cout << "warp-centric\n";
  bs_warp_vertex_compressed<<<nblocks, nthreads>>>(gg, buffer, d_total);
  //bs_warp_vertex_compressed_cached<<<nblocks, nthreads>>>(gg, buffer, d_total, num_cached);
#else // cta centric
  std::cout << "cta-centric\n";
  bs_cta_vertex_compressed<<<nblocks, nthreads>>>(gg, buffer, d_total);
#endif
#else // edge parallel
  std::cout << "edge-parallel ";
#ifdef WARP_CENTRIC
  std::cout << "warp-centric\n";
  bs_warp_edge_compressed<<<nblocks, nthreads>>>(gg, buffer, d_total, num_cached);
#else // cta centric
  std::cout << "cta-centric\n";
  bs_cta_edge_compressed<<<nblocks, nthreads>>>(gg, buffer, d_total);
#endif // end cta/warp centric
#endif // end vertex/edge parallel
#endif // end hindex/binarySearch
  CUDA_SAFE_CALL(cudaDeviceSynchronize());
  t.Stop();

  std::cout << "runtime = " << t.Seconds() << " sec\n";
  std::cout << "throughput = " << double(g.E()) / t.Seconds() / 1e9 << " billion Traversed Edges Per Second (TEPS)\n";
  CUDA_SAFE_CALL(cudaMemcpy(&h_total, d_total, sizeof(AccType), cudaMemcpyDeviceToHost));
  total = h_total;
  CUDA_SAFE_CALL(cudaFree(d_total));
  CUDA_SAFE_CALL(cudaFree(buffer));
#ifdef USE_HINDEX
  CUDA_SAFE_CALL(cudaFree(bins));
#endif
}

