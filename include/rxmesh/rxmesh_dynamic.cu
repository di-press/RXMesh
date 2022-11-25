#include <cooperative_groups.h>

#include "rxmesh/kernels/dynamic_util.cuh"
#include "rxmesh/kernels/for_each_dispatcher.cuh"
#include "rxmesh/kernels/loader.cuh"
#include "rxmesh/kernels/query_dispatcher.cuh"
#include "rxmesh/kernels/shmem_allocator.cuh"
#include "rxmesh/rxmesh_dynamic.h"
#include "rxmesh/util/bitmask_util.h"
#include "rxmesh/util/macros.h"
#include "rxmesh/util/util.h"

#include <thrust/copy.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>

namespace rxmesh {

namespace detail {

template <uint32_t blockThreads>
__global__ static void calc_num_elements(const Context context,
                                         uint32_t*     sum_num_vertices,
                                         uint32_t*     sum_num_edges,
                                         uint32_t*     sum_num_faces)
{
    auto sum_v = [&](VertexHandle& v_id) { ::atomicAdd(sum_num_vertices, 1u); };
    for_each_dispatcher<Op::V, blockThreads>(context, sum_v);


    auto sum_e = [&](EdgeHandle& e_id) { ::atomicAdd(sum_num_edges, 1u); };
    for_each_dispatcher<Op::E, blockThreads>(context, sum_e);


    auto sum_f = [&](FaceHandle& f_id) { ::atomicAdd(sum_num_faces, 1u); };
    for_each_dispatcher<Op::F, blockThreads>(context, sum_f);
}

template <uint32_t blockThreads>
__global__ static void check_uniqueness(const Context           context,
                                        unsigned long long int* d_check)
{
    auto block = cooperative_groups::this_thread_block();

    const uint32_t patch_id = blockIdx.x;

    if (patch_id < context.m_num_patches[0]) {

        PatchInfo patch_info = context.m_patches_info[patch_id];

        ShmemAllocator shrd_alloc;

        uint16_t* s_fe =
            shrd_alloc.alloc<uint16_t>(3 * patch_info.num_faces[0]);
        uint16_t* s_ev =
            shrd_alloc.alloc<uint16_t>(2 * patch_info.num_edges[0]);

        load_async(block,
                   reinterpret_cast<uint16_t*>(patch_info.ev),
                   2 * patch_info.num_edges[0],
                   s_ev,
                   false);

        load_async(block,
                   reinterpret_cast<uint16_t*>(patch_info.fe),
                   3 * patch_info.num_faces[0],
                   s_fe,
                   true);
        block.sync();

        // make sure an edge is connecting two unique vertices
        for (uint16_t e = threadIdx.x; e < patch_info.num_edges[0];
             e += blockThreads) {
            uint16_t v0 = s_ev[2 * e + 0];
            uint16_t v1 = s_ev[2 * e + 1];

            if (!is_deleted(e, patch_info.active_mask_e)) {

                if (v0 >= patch_info.num_vertices[0] ||
                    v1 >= patch_info.num_vertices[0] || v0 == v1) {
                    ::atomicAdd(d_check, 1);
                }
                if (is_deleted(v0, patch_info.active_mask_v) ||
                    is_deleted(v1, patch_info.active_mask_v)) {
                    ::atomicAdd(d_check, 1);
                }
            }
        }

        // make sure a face is formed by three unique edges and these edges
        // gives three unique vertices
        for (uint16_t f = threadIdx.x; f < patch_info.num_faces[0];
             f += blockThreads) {

            if (!is_deleted(f, patch_info.active_mask_f)) {
                uint16_t e0, e1, e2;
                flag_t   d0(0), d1(0), d2(0);
                Context::unpack_edge_dir(s_fe[3 * f + 0], e0, d0);
                Context::unpack_edge_dir(s_fe[3 * f + 1], e1, d1);
                Context::unpack_edge_dir(s_fe[3 * f + 2], e2, d2);

                if (e0 >= patch_info.num_edges[0] ||
                    e1 >= patch_info.num_edges[0] ||
                    e2 >= patch_info.num_edges[0] || e0 == e1 || e0 == e2 ||
                    e1 == e2) {
                    ::atomicAdd(d_check, 1);
                }

                if (is_deleted(e0, patch_info.active_mask_e) ||
                    is_deleted(e1, patch_info.active_mask_e) ||
                    is_deleted(e2, patch_info.active_mask_e)) {
                    ::atomicAdd(d_check, 1);
                }

                uint16_t v0, v1, v2;
                v0 = s_ev[(2 * e0) + (1 * d0)];
                v1 = s_ev[(2 * e1) + (1 * d1)];
                v2 = s_ev[(2 * e2) + (1 * d2)];


                if (v0 >= patch_info.num_vertices[0] ||
                    v1 >= patch_info.num_vertices[0] ||
                    v2 >= patch_info.num_vertices[0] || v0 == v1 || v0 == v2 ||
                    v1 == v2) {
                    ::atomicAdd(d_check, 1);
                }

                if (is_deleted(v0, patch_info.active_mask_v) ||
                    is_deleted(v1, patch_info.active_mask_v) ||
                    is_deleted(v2, patch_info.active_mask_v)) {
                    ::atomicAdd(d_check, 1);
                }
            }
        }
    }
}


template <uint32_t blockThreads>
__global__ static void check_not_owned(const Context           context,
                                       unsigned long long int* d_check)
{
    auto block = cooperative_groups::this_thread_block();

    const uint32_t patch_id = blockIdx.x;

    if (patch_id < context.m_num_patches[0]) {

        PatchInfo patch_info = context.m_patches_info[patch_id];

        ShmemAllocator shrd_alloc;
        uint16_t*      s_fe =
            shrd_alloc.alloc<uint16_t>(3 * patch_info.num_faces[0]);
        uint16_t* s_ev =
            shrd_alloc.alloc<uint16_t>(2 * patch_info.num_edges[0]);
        load_async(block,
                   reinterpret_cast<uint16_t*>(patch_info.ev),
                   2 * patch_info.num_edges[0],
                   s_ev,
                   false);

        load_async(block,
                   reinterpret_cast<uint16_t*>(patch_info.fe),
                   3 * patch_info.num_faces[0],
                   s_fe,
                   true);
        block.sync();


        // for every not-owned face, check that its three edges (possibly
        // not-owned) are the same as those in the face's owner patch
        for (uint16_t f = threadIdx.x; f < patch_info.num_faces[0];
             f += blockThreads) {

            if (!is_deleted(f, patch_info.active_mask_f) &&
                !is_owned(f, patch_info.owned_mask_f)) {

                uint16_t e0, e1, e2;
                flag_t   d0(0), d1(0), d2(0);
                uint32_t p0(patch_id), p1(patch_id), p2(patch_id);
                Context::unpack_edge_dir(s_fe[3 * f + 0], e0, d0);
                Context::unpack_edge_dir(s_fe[3 * f + 1], e1, d1);
                Context::unpack_edge_dir(s_fe[3 * f + 2], e2, d2);

                // if the edge is not owned, grab its local index in the owner
                // patch
                auto get_owned_e =
                    [&](uint16_t& e, uint32_t& p, const PatchInfo pi) {
                        if (!is_owned(e, pi.owned_mask_e)) {
                            auto e_pair = pi.lp_e.find(e);
                            e           = e_pair.local_id_in_owner_patch();
                            p           = pi.patch_stash.get_patch(e_pair);
                        }
                    };
                get_owned_e(e0, p0, patch_info);
                get_owned_e(e1, p1, patch_info);
                get_owned_e(e2, p2, patch_info);

                // get f's three edges from its owner patch
                auto      f_pair  = patch_info.lp_f.find(f);
                uint16_t  f_owned = f_pair.local_id_in_owner_patch();
                uint32_t  f_patch = patch_info.patch_stash.get_patch(f_pair);
                PatchInfo owner_patch_info = context.m_patches_info[f_patch];

                // the owner patch should have indicate that the owned face is
                // owned by it
                if (!is_owned(f_owned, owner_patch_info.owned_mask_f)) {
                    ::atomicAdd(d_check, 1);
                }

                // If a face is deleted, it should also be deleted in the other
                // patches that have it as not-owned
                bool is_del =
                    is_deleted(f_owned, owner_patch_info.active_mask_f);
                if (is_del) {
                    ::atomicAdd(d_check, 1);
                } else {
                    // TODO this is a scattered read from global that could be
                    // improved by using shared memory
                    uint16_t ew0, ew1, ew2;
                    flag_t   dw0(0), dw1(0), dw2(0);
                    uint32_t pw0(f_patch), pw1(f_patch), pw2(f_patch);
                    Context::unpack_edge_dir(
                        owner_patch_info.fe[3 * f_owned + 0].id, ew0, dw0);
                    Context::unpack_edge_dir(
                        owner_patch_info.fe[3 * f_owned + 1].id, ew1, dw1);
                    Context::unpack_edge_dir(
                        owner_patch_info.fe[3 * f_owned + 2].id, ew2, dw2);

                    get_owned_e(ew0, pw0, owner_patch_info);
                    get_owned_e(ew1, pw1, owner_patch_info);
                    get_owned_e(ew2, pw2, owner_patch_info);

                    if (e0 != ew0 || d0 != dw0 || p0 != pw0 || e1 != ew1 ||
                        d1 != dw1 || p1 != pw1 || e2 != ew2 || d2 != dw2 ||
                        p2 != pw2) {
                        ::atomicAdd(d_check, 1);
                    }
                }
            }
        }

        // for every not-owned edge, check its two vertices (possibly
        // not-owned) are the same as those in the edge's owner patch
        for (uint16_t e = threadIdx.x; e < patch_info.num_edges[0];
             e += blockThreads) {

            if (!is_deleted(e, patch_info.active_mask_e) &&
                !is_owned(e, patch_info.owned_mask_e)) {

                uint16_t v0 = s_ev[2 * e + 0];
                uint16_t v1 = s_ev[2 * e + 1];
                uint32_t p0(patch_id), p1(patch_id);

                auto get_owned_v =
                    [&](uint16_t& v, uint32_t& p, const PatchInfo pi) {
                        if (!is_owned(v, pi.owned_mask_v)) {
                            auto v_pair = pi.lp_v.find(v);
                            v           = v_pair.local_id_in_owner_patch();
                            p           = pi.patch_stash.get_patch(v_pair);
                        }
                    };
                get_owned_v(v0, p0, patch_info);
                get_owned_v(v1, p1, patch_info);

                // get e's two vertices from its owner patch
                auto      e_pair  = patch_info.lp_e.find(e);
                uint16_t  e_owned = e_pair.local_id_in_owner_patch();
                uint32_t  e_patch = patch_info.patch_stash.get_patch(e_pair);
                PatchInfo owner_patch_info = context.m_patches_info[e_patch];

                // the owner patch should have indicate that the owned face is
                // owned by it
                if (!is_owned(e_owned, owner_patch_info.owned_mask_e)) {
                    ::atomicAdd(d_check, 1);
                }

                // If an edge is deleted, it should also be deleted in the other
                // patches that have it as not-owned
                bool is_del =
                    is_deleted(e_owned, owner_patch_info.active_mask_e);
                if (is_del) {
                    ::atomicAdd(d_check, 1);
                } else {
                    // TODO this is a scatter read from global that could be
                    // improved by using shared memory
                    uint16_t vw0 = owner_patch_info.ev[2 * e_owned + 0].id;
                    uint16_t vw1 = owner_patch_info.ev[2 * e_owned + 1].id;
                    uint32_t pw0(e_patch), pw1(e_patch);

                    get_owned_v(vw0, pw0, owner_patch_info);
                    get_owned_v(vw1, pw1, owner_patch_info);

                    if (v0 != vw0 || p0 != pw0 || v1 != vw1 || p1 != pw1) {
                        ::atomicAdd(d_check, 1);
                    }
                }
            }
        }
    }
}


template <uint32_t blockThreads>
__global__ static void check_ribbon_edges(const Context           context,
                                          unsigned long long int* d_check)
{
    auto block = cooperative_groups::this_thread_block();

    const uint32_t patch_id = blockIdx.x;

    if (patch_id < context.m_num_patches[0]) {
        PatchInfo patch_info = context.m_patches_info[patch_id];

        ShmemAllocator shrd_alloc;
        uint16_t*      s_fe =
            shrd_alloc.alloc<uint16_t>(3 * patch_info.num_faces[0]);
        load_async(block,
                   reinterpret_cast<uint16_t*>(patch_info.fe),
                   3 * patch_info.num_faces[0],
                   s_fe,
                   true);
        uint16_t* s_mark_edges =
            shrd_alloc.alloc<uint16_t>(patch_info.num_edges[0]);

        for (uint16_t e = threadIdx.x; e < patch_info.num_edges[0];
             e += blockThreads) {
            s_mark_edges[e] = 0;
        }

        block.sync();

        // Check that each owned edge is incident to at least one owned
        // not-deleted face. We do that by iterating over faces, each face
        // (atomically) mark its incident edges only if they are owned. Then we
        // check the marked edges where we expect all owned edges to be marked.
        // If there is an edge that is owned but not marked, then this edge is
        // not incident to any owned faces
        for (uint16_t f = threadIdx.x; f < patch_info.num_faces[0];
             f += blockThreads) {

            if (!is_deleted(f, patch_info.active_mask_f) &&
                is_owned(f, patch_info.owned_mask_f)) {

                uint16_t e0 = s_fe[3 * f + 0] >> 1;
                uint16_t e1 = s_fe[3 * f + 1] >> 1;
                uint16_t e2 = s_fe[3 * f + 2] >> 1;

                auto mark_if_owned = [&](uint16_t edge) {
                    if (is_owned(edge, patch_info.owned_mask_e)) {
                        atomicAdd(s_mark_edges + edge, uint16_t(1));
                    }
                };

                mark_if_owned(e0);
                mark_if_owned(e1);
                mark_if_owned(e2);
            }
        }
        block.sync();
        for (uint16_t e = threadIdx.x; e < patch_info.num_edges[0];
             e += blockThreads) {
            if (is_owned(e, patch_info.owned_mask_e)) {
                if (s_mark_edges[e] == 0) {
                    ::atomicAdd(d_check, 1);
                }
            }
        }
    }
}


template <uint32_t blockThreads>
__global__ static void compute_vf(const Context               context,
                                  VertexAttribute<FaceHandle> output)
{
    using namespace rxmesh;

    auto store_lambda = [&](VertexHandle& v_id, FaceIterator& iter) {
        for (uint32_t i = 0; i < iter.size(); ++i) {
            output(v_id, i) = iter[i];
        }
    };

    query_block_dispatcher<Op::VF, blockThreads>(context, store_lambda);
}


template <uint32_t blockThreads>
__global__ static void compute_max_valence(const Context context,
                                           uint32_t*     d_max_valence)
{
    using namespace rxmesh;

    auto max_valence = [&](VertexHandle& v_id, VertexIterator& iter) {
        ::atomicMax(d_max_valence, iter.size());
    };

    query_block_dispatcher<Op::VV, blockThreads>(context, max_valence);
}

template <uint32_t blockThreads>
__global__ static void check_ribbon_faces(const Context               context,
                                          VertexAttribute<FaceHandle> global_vf,
                                          unsigned long long int*     d_check)
{
    auto block = cooperative_groups::this_thread_block();

    const uint32_t patch_id = blockIdx.x;

    if (patch_id < context.m_num_patches[0]) {
        PatchInfo patch_info = context.m_patches_info[patch_id];

        ShmemAllocator shrd_alloc;
        uint16_t*      s_fv =
            shrd_alloc.alloc<uint16_t>(3 * patch_info.num_faces[0]);
        uint16_t* s_fe =
            shrd_alloc.alloc<uint16_t>(3 * patch_info.num_faces[0]);
        uint16_t* s_ev =
            shrd_alloc.alloc<uint16_t>(2 * patch_info.num_edges[0]);
        load_async(block,
                   reinterpret_cast<uint16_t*>(patch_info.ev),
                   2 * patch_info.num_edges[0],
                   s_ev,
                   false);
        load_async(block,
                   reinterpret_cast<uint16_t*>(patch_info.fe),
                   3 * patch_info.num_faces[0],
                   s_fv,
                   true);
        block.sync();


        // compute FV
        f_v<blockThreads>(patch_info.num_edges[0],
                          s_ev,
                          patch_info.num_faces[0],
                          s_fv,
                          patch_info.active_mask_f);
        block.sync();

        // copy FV
        for (uint16_t i = threadIdx.x; i < 3 * patch_info.num_faces[0];
             i += blockThreads) {
            s_fe[i] = s_fv[i];
        }
        block.sync();

        // compute (local) VF by transposing FV
        uint16_t* s_vf_offset = &s_fe[0];
        uint16_t* s_vf_value  = &s_ev[0];
        block_mat_transpose<3u, blockThreads>(patch_info.num_faces[0],
                                              patch_info.num_vertices[0],
                                              s_fe,
                                              s_ev,
                                              patch_info.active_mask_f,
                                              0);

        // For every incident vertex V to an owned face, check if VF of V
        // using global_VF can be retrieved from local_VF
        for (uint16_t f = threadIdx.x; f < patch_info.num_faces[0];
             f += blockThreads) {

            // Only if the face is owned, we do the check
            if (is_owned(f, patch_info.owned_mask_f)) {

                // for the three vertices incident to this face
                for (uint16_t k = 0; k < 3; ++k) {
                    uint16_t v_id = s_fv[3 * f + k];

                    // get the vertex handle so we can index the attributes
                    uint16_t lid = v_id;
                    uint32_t pid = patch_id;
                    if (!is_owned(v_id, patch_info.owned_mask_v)) {
                        auto lp = patch_info.lp_v.find(lid);
                        lid     = lp.local_id_in_owner_patch();
                        pid     = patch_info.patch_stash.get_patch(lp);
                    }
                    VertexHandle vh(pid, lid);

                    // for every incident face to this vertex
                    for (uint16_t i = 0; i < global_vf.get_num_attributes();
                         ++i) {
                        if (global_vf(vh, i).is_valid()) {

                            // look for the face incident to the vertex in local
                            // VF
                            bool found = false;
                            for (uint16_t j = s_vf_offset[v_id];
                                 j < s_vf_offset[v_id + 1];
                                 ++j) {

                                uint16_t f_lid = s_vf_value[j];
                                uint32_t f_pid = patch_id;

                                if (!is_owned(f_lid, patch_info.owned_mask_f)) {
                                    auto lp = patch_info.lp_f.find(f_lid);
                                    f_lid   = lp.local_id_in_owner_patch();
                                    f_pid =
                                        patch_info.patch_stash.get_patch(lp);
                                }
                                FaceHandle fh(f_pid, f_lid);

                                if (global_vf(vh, i) == fh) {
                                    found = true;
                                    break;
                                }
                            }

                            if (!found) {
                                ::atomicAdd(d_check, 1);
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}

}  // namespace detail

bool RXMeshDynamic::validate()
{
    bool cached_quite = this->m_quite;
    this->m_quite     = true;

    CUDA_ERROR(cudaDeviceSynchronize());

    uint32_t num_patches;
    CUDA_ERROR(cudaMemcpy(&num_patches,
                          m_rxmesh_context.m_num_patches,
                          sizeof(uint32_t),
                          cudaMemcpyDeviceToHost));
    unsigned long long int* d_check;
    CUDA_ERROR(cudaMalloc((void**)&d_check, sizeof(unsigned long long int)));

    auto is_okay = [&]() {
        unsigned long long int h_check(0);
        CUDA_ERROR(cudaMemcpy(&h_check,
                              d_check,
                              sizeof(unsigned long long int),
                              cudaMemcpyDeviceToHost));
        if (h_check != 0) {
            return false;
        } else {
            return true;
        }
    };

    // check that the sum of owned vertices, edges, and faces per patch is equal
    // to the number of vertices, edges, and faces respectively
    auto check_num_mesh_elements = [&]() -> bool {
        uint32_t *d_sum_num_vertices, *d_sum_num_edges, *d_sum_num_faces;
        thrust::device_vector<uint32_t> d_sum_vertices(1, 0);
        thrust::device_vector<uint32_t> d_sum_edges(1, 0);
        thrust::device_vector<uint32_t> d_sum_faces(1, 0);

        constexpr uint32_t block_size = 256;
        const uint32_t     grid_size  = num_patches;

        detail::calc_num_elements<block_size>
            <<<grid_size, block_size>>>(m_rxmesh_context,
                                        d_sum_vertices.data().get(),
                                        d_sum_edges.data().get(),
                                        d_sum_faces.data().get());

        uint32_t num_vertices, num_edges, num_faces;
        CUDA_ERROR(cudaMemcpy(&num_vertices,
                              m_rxmesh_context.m_num_vertices,
                              sizeof(uint32_t),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(&num_edges,
                              m_rxmesh_context.m_num_edges,
                              sizeof(uint32_t),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(&num_faces,
                              m_rxmesh_context.m_num_faces,
                              sizeof(uint32_t),
                              cudaMemcpyDeviceToHost));
        uint32_t sum_num_vertices, sum_num_edges, sum_num_faces;
        thrust::copy(
            d_sum_vertices.begin(), d_sum_vertices.end(), &sum_num_vertices);
        thrust::copy(d_sum_edges.begin(), d_sum_edges.end(), &sum_num_edges);
        thrust::copy(d_sum_faces.begin(), d_sum_faces.end(), &sum_num_faces);

        if (num_vertices != sum_num_vertices || num_edges != sum_num_edges ||
            num_faces != sum_num_faces) {
            return false;
        } else {
            return true;
        }
    };

    // check that each edge is composed of two unique vertices and each face is
    // composed of three unique edges that give three unique vertices.
    auto check_uniqueness = [&]() -> bool {
        CUDA_ERROR(cudaMemset(d_check, 0, sizeof(unsigned long long int)));
        constexpr uint32_t block_size = 256;
        const uint32_t     grid_size  = num_patches;
        const uint32_t     dynamic_smem =
            rxmesh::ShmemAllocator::default_alignment * 2 +
            (3 * this->m_max_faces_per_patch) * sizeof(uint16_t) +
            (2 * this->m_max_edges_per_patch) * sizeof(uint16_t);

        detail::check_uniqueness<block_size>
            <<<grid_size, block_size, dynamic_smem>>>(m_rxmesh_context,
                                                      d_check);

        return is_okay();
    };

    // check that every not-owned mesh elements' connectivity (faces and
    // edges) is equivalent to their connectivity in their owner patch.
    // if the mesh element is deleted in the owner patch, no check is done
    auto check_not_owned = [&]() -> bool {
        CUDA_ERROR(cudaMemset(d_check, 0, sizeof(unsigned long long int)));
        CUDA_ERROR(cudaMemset(d_check, 0, sizeof(unsigned long long int)));

        constexpr uint32_t block_size = 256;
        const uint32_t     grid_size  = num_patches;
        const uint32_t     dynamic_smem =
            ShmemAllocator::default_alignment * 2 +
            (3 * this->m_max_faces_per_patch) * sizeof(uint16_t) +
            (2 * this->m_max_edges_per_patch) * sizeof(uint16_t);

        detail::check_not_owned<block_size>
            <<<grid_size, block_size, dynamic_smem>>>(m_rxmesh_context,
                                                      d_check);
        return is_okay();
    };

    // check if the ribbon construction is complete i.e., 1) each owned edge is
    // incident to an owned face, and 2) VF of the three vertices of an owned
    // face is inside the patch
    auto check_ribbon = [&]() {
        CUDA_ERROR(cudaMemset(d_check, 0, sizeof(unsigned long long int)));
        constexpr uint32_t block_size = 256;
        const uint32_t     grid_size  = num_patches;
        uint32_t           dynamic_smem =
            ShmemAllocator::default_alignment * 3 +
            (3 * this->m_max_faces_per_patch) * sizeof(uint16_t) +
            this->m_max_edges_per_patch * sizeof(uint16_t);

        detail::check_ribbon_edges<block_size>
            <<<grid_size, block_size, dynamic_smem>>>(m_rxmesh_context,
                                                      d_check);

        if (!is_okay()) {
            return false;
        }

        uint32_t* d_max_valence;
        CUDA_ERROR(cudaMalloc((void**)&d_max_valence, sizeof(uint32_t)));
        CUDA_ERROR(cudaMemset(d_max_valence, 0, sizeof(uint32_t)));

        LaunchBox<block_size> launch_box;
        RXMeshStatic::prepare_launch_box(
            {Op::VV},
            launch_box,
            (void*)detail::compute_max_valence<block_size>);
        detail::compute_max_valence<block_size>
            <<<launch_box.blocks, block_size, launch_box.smem_bytes_dyn>>>(
                m_rxmesh_context, d_max_valence);


        uint32_t h_max_valence = 0;
        CUDA_ERROR(cudaMemcpy(&h_max_valence,
                              d_max_valence,
                              sizeof(uint32_t),
                              cudaMemcpyDeviceToHost));

        GPU_FREE(d_max_valence);

        auto vf_global = this->add_vertex_attribute<FaceHandle>(
            "vf", h_max_valence, rxmesh::DEVICE);
        vf_global->reset(FaceHandle(), rxmesh::DEVICE);


        RXMeshStatic::prepare_launch_box(
            {Op::VF}, launch_box, (void*)detail::compute_vf<block_size>);

        detail::compute_vf<block_size>
            <<<launch_box.blocks, block_size, launch_box.smem_bytes_dyn>>>(
                m_rxmesh_context, *vf_global);

        dynamic_smem =
            ShmemAllocator::default_alignment * 3 +
            2 * (3 * this->m_max_faces_per_patch) * sizeof(uint16_t) +
            std::max(3 * this->m_max_faces_per_patch,
                     2 * this->m_max_edges_per_patch) *
                sizeof(uint16_t);

        detail::check_ribbon_faces<block_size>
            <<<grid_size, block_size, dynamic_smem>>>(
                m_rxmesh_context, *vf_global, d_check);

        return is_okay();
    };

    bool success = true;
    if (!check_num_mesh_elements()) {
        RXMESH_ERROR(
            "RXMeshDynamic::validate() check_num_mesh_elements failed");
        success = false;
    }

    if (!check_uniqueness()) {
        RXMESH_ERROR("RXMeshDynamic::validate() check_uniqueness failed");
        success = false;
    }

    if (!check_not_owned()) {
        RXMESH_ERROR("RXMeshDynamic::validate() check_not_owned failed");
        success = false;
    }

    if (!check_ribbon()) {
        RXMESH_ERROR("RXMeshDynamic::validate() check_ribbon failed");
        success = false;
    }

    CUDA_ERROR(cudaFree(d_check));

    this->m_quite = cached_quite;

    return success;
}


void RXMeshDynamic::update_host()
{
    auto resize_masks = [&](uint16_t   size,
                            uint16_t&  capacity,
                            uint32_t*& active_mask,
                            uint32_t*& owned_mask) {
        if (size > capacity) {
            capacity = size;
            free(active_mask);
            free(owned_mask);
            active_mask = (uint32_t*)malloc(detail::mask_num_bytes(size));
            owned_mask  = (uint32_t*)malloc(detail::mask_num_bytes(size));
        }
    };

    uint32_t num_patches = 0;
    CUDA_ERROR(cudaMemcpy(&num_patches,
                          m_rxmesh_context.m_num_patches,
                          sizeof(uint32_t),
                          cudaMemcpyDeviceToHost));
    if (num_patches != m_num_patches) {
        RXMESH_ERROR(
            "RXMeshDynamic::update_host() does support changing number of "
            "patches in the mesh");
    }

    for (uint32_t p = 0; p < m_num_patches; ++p) {
        PatchInfo d_patch;
        CUDA_ERROR(cudaMemcpy(&d_patch,
                              m_d_patches_info + p,
                              sizeof(PatchInfo),
                              cudaMemcpyDeviceToHost));

        assert(d_patch.patch_id == p);

        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].num_vertices,
                              d_patch.num_vertices,
                              sizeof(uint16_t),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].num_edges,
                              d_patch.num_edges,
                              sizeof(uint16_t),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].num_faces,
                              d_patch.num_faces,
                              sizeof(uint16_t),
                              cudaMemcpyDeviceToHost));

        // resize topology (don't update capacity here)
        if (m_h_patches_info[p].num_edges[0] >
            m_h_patches_info[p].edges_capacity[0]) {
            free(m_h_patches_info[p].ev);
            m_h_patches_info[p].ev = (LocalVertexT*)malloc(
                m_h_patches_info[p].num_edges[0] * 2 * sizeof(LocalVertexT));
        }

        if (m_h_patches_info[p].num_faces[0] >
            m_h_patches_info[p].faces_capacity[0]) {
            free(m_h_patches_info[p].fe);
            m_h_patches_info[p].fe = (LocalEdgeT*)malloc(
                m_h_patches_info[p].num_faces[0] * 3 * sizeof(LocalEdgeT));
        }

        // copy topology
        CUDA_ERROR(cudaMemcpy(
            m_h_patches_info[p].ev,
            d_patch.ev,
            2 * m_h_patches_info[p].num_edges[0] * sizeof(LocalVertexT),
            cudaMemcpyDeviceToHost));

        CUDA_ERROR(cudaMemcpy(
            m_h_patches_info[p].fe,
            d_patch.fe,
            3 * m_h_patches_info[p].num_faces[0] * sizeof(LocalEdgeT),
            cudaMemcpyDeviceToHost));

        // resize mask (update capacity)
        resize_masks(m_h_patches_info[p].num_vertices[0],
                     m_h_patches_info[p].vertices_capacity[0],
                     m_h_patches_info[p].active_mask_v,
                     m_h_patches_info[p].owned_mask_v);

        resize_masks(m_h_patches_info[p].num_edges[0],
                     m_h_patches_info[p].edges_capacity[0],
                     m_h_patches_info[p].active_mask_e,
                     m_h_patches_info[p].owned_mask_e);

        resize_masks(m_h_patches_info[p].num_faces[0],
                     m_h_patches_info[p].faces_capacity[0],
                     m_h_patches_info[p].active_mask_f,
                     m_h_patches_info[p].owned_mask_f);

        // copy masks
        CUDA_ERROR(cudaMemcpy(
            m_h_patches_info[p].active_mask_v,
            d_patch.active_mask_v,
            detail::mask_num_bytes(m_h_patches_info[p].num_vertices[0]),
            cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(
            m_h_patches_info[p].owned_mask_v,
            d_patch.owned_mask_v,
            detail::mask_num_bytes(m_h_patches_info[p].num_vertices[0]),
            cudaMemcpyDeviceToHost));


        CUDA_ERROR(
            cudaMemcpy(m_h_patches_info[p].active_mask_e,
                       d_patch.active_mask_e,
                       detail::mask_num_bytes(m_h_patches_info[p].num_edges[0]),
                       cudaMemcpyDeviceToHost));
        CUDA_ERROR(
            cudaMemcpy(m_h_patches_info[p].owned_mask_e,
                       d_patch.owned_mask_e,
                       detail::mask_num_bytes(m_h_patches_info[p].num_edges[0]),
                       cudaMemcpyDeviceToHost));

        CUDA_ERROR(
            cudaMemcpy(m_h_patches_info[p].active_mask_f,
                       d_patch.active_mask_f,
                       detail::mask_num_bytes(m_h_patches_info[p].num_faces[0]),
                       cudaMemcpyDeviceToHost));
        CUDA_ERROR(
            cudaMemcpy(m_h_patches_info[p].owned_mask_f,
                       d_patch.owned_mask_f,
                       detail::mask_num_bytes(m_h_patches_info[p].num_faces[0]),
                       cudaMemcpyDeviceToHost));


        // copy patch stash
        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].patch_stash.m_stash,
                              d_patch.patch_stash.m_stash,
                              PatchStash::stash_size * sizeof(uint32_t),
                              cudaMemcpyDeviceToHost));

        // copy lp hashtable
        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].lp_v.get_table(),
                              d_patch.lp_v.get_table(),
                              d_patch.lp_v.num_bytes(),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].lp_e.get_table(),
                              d_patch.lp_e.get_table(),
                              d_patch.lp_e.num_bytes(),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].lp_f.get_table(),
                              d_patch.lp_f.get_table(),
                              d_patch.lp_f.num_bytes(),
                              cudaMemcpyDeviceToHost));

        // copy lp hashtable stash
        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].lp_v.get_stash(),
                              d_patch.lp_v.get_stash(),
                              LPHashTable::stash_size * sizeof(LPPair),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].lp_e.get_stash(),
                              d_patch.lp_e.get_stash(),
                              LPHashTable::stash_size * sizeof(LPPair),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(m_h_patches_info[p].lp_f.get_stash(),
                              d_patch.lp_f.get_stash(),
                              LPHashTable::stash_size * sizeof(LPPair),
                              cudaMemcpyDeviceToHost));
    }


    CUDA_ERROR(cudaMemcpy(&this->m_num_vertices,
                          m_rxmesh_context.m_num_vertices,
                          sizeof(uint32_t),
                          cudaMemcpyDeviceToHost));
    CUDA_ERROR(cudaMemcpy(&this->m_num_edges,
                          m_rxmesh_context.m_num_edges,
                          sizeof(uint32_t),
                          cudaMemcpyDeviceToHost));
    CUDA_ERROR(cudaMemcpy(&this->m_num_faces,
                          m_rxmesh_context.m_num_faces,
                          sizeof(uint32_t),
                          cudaMemcpyDeviceToHost));

    // count and update num_owned and it prefix sum
    for (uint32_t p = 0; p < m_num_patches; ++p) {
        m_h_num_v[p]             = m_h_patches_info[p].num_vertices[0];
        m_h_num_owned_v[p]       = m_h_patches_info[p].get_num_owned_vertices();
        m_h_vertex_prefix[p + 1] = m_h_vertex_prefix[p] + m_h_num_owned_v[p];

        m_h_num_e[p]           = m_h_patches_info[p].num_edges[0];
        m_h_num_owned_e[p]     = m_h_patches_info[p].get_num_owned_edges();
        m_h_edge_prefix[p + 1] = m_h_edge_prefix[p] + m_h_num_owned_e[p];

        m_h_num_f[p]           = m_h_patches_info[p].num_faces[0];
        m_h_num_owned_f[p]     = m_h_patches_info[p].get_num_owned_faces();
        m_h_face_prefix[p + 1] = m_h_face_prefix[p] + m_h_num_owned_f[p];
    }

    if (m_h_vertex_prefix.back() != this->m_num_vertices) {
        RXMESH_ERROR(
            "RXMeshDynamic::update_host error in updating host. m_num_vertices "
            "{} does not match m_h_vertex_prefix calculation {}",
            this->m_num_vertices,
            m_h_vertex_prefix.back());
    }

    if (m_h_edge_prefix.back() != this->m_num_edges) {
        RXMESH_ERROR(
            "RXMeshDynamic::update_host error in updating host. m_num_edges "
            "{} does not match m_h_edge_prefix calculation {}",
            this->m_num_faces,
            m_h_face_prefix.back());
    }

    if (m_h_face_prefix.back() != this->m_num_faces) {
        RXMESH_ERROR(
            "RXMeshDynamic::update_host error in updating host. m_num_faces "
            "{} does not match m_h_face_prefix calculation {}",
            this->m_num_edges,
            m_h_edge_prefix.back());
    }
    this->calc_max_elements();

    CUDA_ERROR(cudaMemcpy(m_d_num_owned_v,
                          m_h_num_owned_v.data(),
                          m_num_patches * sizeof(uint32_t),
                          cudaMemcpyHostToDevice));

    CUDA_ERROR(cudaMemcpy(m_d_num_owned_e,
                          m_h_num_owned_e.data(),
                          m_num_patches * sizeof(uint32_t),
                          cudaMemcpyHostToDevice));

    CUDA_ERROR(cudaMemcpy(m_d_num_owned_f,
                          m_h_num_owned_f.data(),
                          m_num_patches * sizeof(uint32_t),
                          cudaMemcpyHostToDevice));

    CUDA_ERROR(cudaMemcpy(m_d_num_v,
                          m_h_num_v.data(),
                          m_num_patches * sizeof(uint32_t),
                          cudaMemcpyHostToDevice));

    CUDA_ERROR(cudaMemcpy(m_d_num_e,
                          m_h_num_e.data(),
                          m_num_patches * sizeof(uint32_t),
                          cudaMemcpyHostToDevice));

    CUDA_ERROR(cudaMemcpy(m_d_num_f,
                          m_h_num_f.data(),
                          m_num_patches * sizeof(uint32_t),
                          cudaMemcpyHostToDevice));

#if USE_POLYSCOPE
    // for polyscope, we just remove the mesh and re-add it since polyscope does
    // not support changing the mesh topology
    polyscope::removeSurfaceMesh(this->m_polyscope_mesh_name, true);
    this->m_polyscope_mesh_name = this->m_polyscope_mesh_name + "updated";
    this->register_polyscope();
#endif
}
}  // namespace rxmesh