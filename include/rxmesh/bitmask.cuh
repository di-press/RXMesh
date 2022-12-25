#pragma once

#include <cooperative_groups.h>
#include <stdint.h>

#include "rxmesh/kernels/shmem_allocator.cuh"
#include "rxmesh/util/bitmask_util.h"

namespace rxmesh {
struct Bitmask
{
    __device__ __host__ __inline__ Bitmask() : m_size(0), m_bitmask(nullptr)
    {
    }

    __device__ __host__ Bitmask(const Bitmask& other) = default;
    __device__ __host__ Bitmask(Bitmask&&)            = default;
    __device__ __host__ Bitmask& operator=(const Bitmask&) = default;
    __device__ __host__ Bitmask& operator=(Bitmask&&) = default;
    __device__                   __host__ ~Bitmask()  = default;

    /**
     * @brief constructor that works when the bitmask pointer is allocated
     * externally and the size does not grow
     * @param sz is the number of bits represented by this mask
     * @param mask pointer to the bitmask
     * @return
     */
    __device__ __host__ __inline__ Bitmask(uint16_t sz, uint32_t* mask)
        : m_size(sz), m_bitmask(mask)
    {
    }

    /**
     * @brief constructor that works for bitmask stored in shared memory on the
     * device. It takes a shared memory allocator and perform the allocation
     * internally. This is the right constructor is the size of the bitmask does
     * NOT grow.
     * @param sz is the number of bits represented by this mask
     * @param shrd_alloc shared memory allocator used to allocate the bitmask
     * bytes
     * @return
     */
    __device__ __inline__ Bitmask(uint16_t sz, ShmemAllocator& shrd_alloc)
        : m_size(sz)
    {
        m_bitmask =
            reinterpret_cast<uint32_t*>(shrd_alloc.alloc(num_bytes(size())));
    }


    /**
     * @brief the number of bits represented by this bitmask
     */
    constexpr __device__ __host__ __inline__ uint16_t size() const
    {
        return m_size;
    }


    /**
     * @brief return the number of bytes needed to represent a mask of a given
     * size/number of bits
     * @param size as the number of bits
     */
    static constexpr __device__ __host__ __inline__ uint16_t num_bytes(
        uint16_t size)
    {
        return detail::mask_num_bytes(size);
    }


    /**
     * @brief return the number of bytes needed to represent this mask
     */
    constexpr __device__ __host__ __inline__ uint16_t num_bytes() const
    {
        return num_bytes(size());
    }

    /**
     * @brief reset all the bits in the mask to zero. This should only be
     * invoked from the host side
     * @return
     */
    __host__ inline void reset()
    {
        assert(m_bitmask != nullptr);
        uint16_t mask_num_elements = DIVIDE_UP(size(), 32);
        for (uint16_t i = 0; i < mask_num_elements; ++i) {
            m_bitmask[i] = 0;
        }
    }

    /**
     * @brief reset all the bits in the mask to zero. This can be only invoked
     * from the device using cooperative groups
     * @return
     */
    __device__ __inline__ void reset(cooperative_groups::thread_group& g)
    {
        assert(m_bitmask != nullptr);
        uint16_t mask_num_elements = DIVIDE_UP(size(), 32);
        for (uint16_t i = g.thread_rank(); i < mask_num_elements;
             i += g.size()) {
            m_bitmask[i] = 0;
        }
    }


    /**
     * @brief set all the bits in the mask one. This should only be invoked from
     * the host side
     * @return
     */
    __host__ inline void set()
    {
        assert(m_bitmask != nullptr);
        uint16_t mask_num_elements = DIVIDE_UP(size(), 32);
        for (uint16_t i = 0; i < mask_num_elements; ++i) {
            m_bitmask[i] = INVALID32;
        }
    }

    /**
     * @brief set all the bits in the mask one. This can be only invoked from
     * the device using cooperative groups
     * @return
     */
    __device__ __inline__ void set(cooperative_groups::thread_group& g)
    {
        assert(m_bitmask != nullptr);
        const uint16_t mask_num_elements = DIVIDE_UP(size(), 32);
        for (uint16_t i = g.thread_rank(); i < mask_num_elements;
             i += g.size()) {
            m_bitmask[i] = INVALID32;
        }
    }


    /**
     * @brief set a bit in the bitmask
     * @param bit the bit position
     * @param is_atomic perform the operation atomically in case it is done on
     * the device to avoid race condition. On the host, this option is ignored
     */
    __device__ __host__ __inline__ void set(const uint16_t bit,
                                            bool           is_atomic = false)
    {
        assert(bit < size());
        detail::bitmask_set_bit(bit, m_bitmask, is_atomic);
    }


    /**
     * @brief clear a bit in the bitmask
     * @param bit the bit position
     * @param is_atomic perform the operation atomically in case it is done on
     * the device to avoid race condition. On the host, this option is ignored
     */
    __device__ __host__ __inline__ void reset(const uint16_t bit,
                                              bool           is_atomic = false)
    {
        assert(bit < size());
        detail::bitmask_clear_bit(bit, m_bitmask, is_atomic);
    }


    /**
     * @brief flip a bit in the bitmask
     * @param bit the bit position
     * @param is_atomic perform the operation atomically in case it is done on
     * the device to avoid race condition. On the host, this option is ignored
     */
    __device__ __host__ __inline__ void flip(const uint16_t bit,
                                             bool           is_atomic = false)
    {
        assert(bit < size());
        detail::bitmask_flip_bit(bit, m_bitmask, is_atomic);
    }


    /**
     * @brief check if bit is set
     * @param bit the bit position
     * @return true is the bit is set, false otherwise
     */
    __device__ __host__ __inline__ bool operator()(const uint16_t bit) const
    {
        assert(bit < size());
        return detail::is_set_bit(bit, m_bitmask);
    }

   private:
    uint16_t m_size;    

   public:
    uint32_t* m_bitmask;
};
}  // namespace rxmesh