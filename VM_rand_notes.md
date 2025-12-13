# Virtual Address Randomization Implementation

## Overview
Implemented randomized virtual address allocation for Vortex GPU's virtual memory system to enable stress-testing of the VM implementation with non-identity address mappings.

## Features
- **Environment Variable Control**: `VORTEX_RANDOMIZE_VA=1` enables randomization
- **Reproducible Testing**: `VORTEX_VA_SEED=<seed>` allows seeded random generation
- **32-bit Address Space Support**: Ensures all VAs fit within 32-bit range for XLEN=32
- **Contiguous Multi-Page Allocations**: Properly handles buffers spanning multiple pages

## Implementation Details

### Files Modified
1. **runtime/common/vm.h**
   - Added `std::mt19937_64 rng_` member for random number generation
   - Added `bool randomize_va_` flag to track randomization state
   - Added `#include <random>` for RNG support

2. **runtime/common/vm.cpp**
   - **Constructor**: Initialize RNG with seed from `VORTEX_VA_SEED` env var
   - **Virtual memory allocator init**: Added 32-bit address space constraint
   - **phy_to_virt_map()**: Complete rewrite to support contiguous VA allocation
   - **map_p2v()**: Added randomization path for single-page allocations

### Key Algorithm: Contiguous VA Allocation

The runtime allocates entire contiguous VA range upfront, then map each page sequentially:
```cpp
// 1. Find random contiguous VA range
uint64_t candidate_va = random_address_in_range();
if (virtual_mem_->reserve(candidate_va, size) == 0) {
    base_vpn = candidate_va >> MEM_PAGE_LOG2_SIZE;
}

// 2. Map each PPN to sequential VPN
for (uint64_t i = 0; i < num_pages; i++) {
    ppn = base_ppn + i;
    vpn = base_vpn + i;  // Sequential!
    update_page_table(ppn, vpn, flags);
}
```
Result: PPN [0x10, 0x11, 0x12, 0x13] → VPN [0xeb98f, 0xeb990, 0xeb991, 0xeb992] (contiguous!)

### Randomization Strategy

1. **Random VA Selection**:
   - Generate random page offset within allocatable range [ALLOC_BASE_ADDR, PAGE_TABLE_BASE_ADDR)
   - Ensure enough space for entire allocation (size-aware bounds)
   - Check for conflicts with existing mappings

2. **Collision Detection**:
   - Verify entire VPN range is unused before reserving
   - Check against `addr_mapping` hash table

3. **Fallback Mechanism**:
   - After 1000 failed attempts, fall back to sequential allocation
   - Ensures forward progress even in fragmented address spaces

4. **Address Space Constraints**:
   - For XLEN=32: Limit VAs to < 0x100000000 to prevent truncation
   - Reserve space for page tables starting at PAGE_TABLE_BASE_ADDR (0xF0000000)

## Testing
`./run_vm_regression_random.sh`
