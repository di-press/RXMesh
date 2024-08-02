#include "rxmesh/query.cuh"
#include "rxmesh/rxmesh_static.h"

#include "rxmesh/matrix/sparse_matrix.cuh"

using namespace rxmesh;


template <typename T, uint32_t blockThreads>
__global__ static void compute_area_matrix(const rxmesh::Context      context,
                                            rxmesh::VertexAttribute<T> boundaryVertices,
                                            rxmesh::SparseMatrix<T> AreaMatrix)
{

    auto vn_lambda = [&](EdgeHandle edge_id, VertexIterator& vv)
    {   
            
        if (boundaryVertices(vv[0], 0) == 1 && boundaryVertices(vv[1], 0) == 1){
            AreaMatrix(vv[0], vv[1]) = make_cuComplex(0,-0.25); // modify later
            AreaMatrix(vv[1], vv[0]) = make_cuComplex(0,0.25);
        }
        
    };

    auto block = cooperative_groups::this_thread_block();
    Query<blockThreads> query(context);
    ShmemAllocator      shrd_alloc;
    query.dispatch<Op::EV>(block, shrd_alloc, vn_lambda);
}

template <typename T>
__device__ __forceinline__ T
edge_cotan_weight(const rxmesh::VertexHandle&       p_id,
                  const rxmesh::VertexHandle&       r_id,
                  const rxmesh::VertexHandle&       q_id,
                  const rxmesh::VertexHandle&       s_id,
                  const rxmesh::VertexAttribute<T>& X)
{
    // Get the edge weight between the two vertices p-r where
    // q and s composes the diamond around p-r

    const vec3<T> p(X(p_id, 0), X(p_id, 1), X(p_id, 2));
    const vec3<T> r(X(r_id, 0), X(r_id, 1), X(r_id, 2));
    const vec3<T> q(X(q_id, 0), X(q_id, 1), X(q_id, 2));
    const vec3<T> s(X(s_id, 0), X(s_id, 1), X(s_id, 2));

    //cotans[(v1, v2)] =np.dot(e1, e2) / np.linalg.norm(np.cross(e1, e2))

    float weight = 0;
    if (q_id.is_valid())
        weight   += dot((p - q), (r - q)) / length(cross(p - q, r - q));
    if (s_id.is_valid())
        weight   += dot((p - s), (r - s)) / length(cross(p - s, r - s));
    weight /= 2;
    return std::max(0.f, weight);
}


template <typename T, uint32_t blockThreads>
__global__ static void compute_edge_weights_evd(const rxmesh::Context      context,
                                            rxmesh::VertexAttribute<T> coords,
                                            rxmesh::SparseMatrix<T>    A_mat)
{

    auto vn_lambda = [&](EdgeHandle edge_id, VertexIterator& vv) {
            T e_weight = 0;
            e_weight = edge_cotan_weight(vv[0], vv[2], vv[1], vv[3], coords);
        A_mat(vv[0], vv[2]) = e_weight;
        A_mat(vv[2], vv[0]) = e_weight;

        //A_mat(vv[0], vv[2]) = 1;
        //A_mat(vv[2], vv[0]) = 1;
        
    };

    auto                block = cooperative_groups::this_thread_block();
    Query<blockThreads> query(context);
    ShmemAllocator      shrd_alloc;
    query.dispatch<Op::EVDiamond>(block, shrd_alloc, vn_lambda);
}


__global__ static void calculate_Ld_matrix(
    const rxmesh::Context   context,
    rxmesh::SparseMatrix<T> weight_mat,  // [num_coord, num_coord]
    rxmesh::SparseMatrix<T> Ld // [num_coord, num_coord]
)

{
    auto init_lambda = [&](VertexHandle v_id, VertexIterator& vv) {

        L(v_id, v_id) =  make_cuComplex(0,0);

        for (int nei_index = 0; nei_index < vv.size(); nei_index++)
            L(v_id, vv[nei_index]) =  make_cuComplex(0,0);

            for (int nei_index = 0; nei_index < vv.size(); nei_index++) 
            {
                L(v_id, v_id) +=  make_cuComplex(weight_mat(v_id, vv[nei_index]), weight_mat(v_id, vv[nei_index]));
                L(v_id, vv[nei_index]) -= make_cuComplex(weight_mat(v_id, vv[nei_index]), 0);
            }


    };

    auto                block = cooperative_groups::this_thread_block();
    Query<blockThreads> query(context);
    ShmemAllocator      shrd_alloc;
    query.dispatch<Op::VV>(block, shrd_alloc, init_lambda);
}

int main(int argc, char** argv)
{
    Log::init();

    const uint32_t device_id = 0;
    cuda_query(device_id);

    RXMeshStatic rx(STRINGIFY(INPUT_DIR) "bunnyhead.obj");

    SparseMatrix<cuComplex> Ld(rx); //complex V x V

    SparseMatrix<cuComplex> A(rx); // 2V x 2V

    auto boundaryVertices = *rx.add_vertex_attribute<int>("boundaryVertices", 1);

    rx.get_boundary_vertices(boundaryVertices); // 0 or 1 value for boundary vertex

    // identify boundary edge (vv query)
    // v1 is central; v2 is on boundary 






#if USE_POLYSCOPE
    polyscope::show();
#endif
}