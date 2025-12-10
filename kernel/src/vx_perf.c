// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


#include <VX_config.h>
#include <VX_types.h>
#include <vx_intrinsics.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef XLEN_64
    #define DUMP_CSRS(i) \
        ((int64_t*)csr_mem)[i] = csr_read(VX_CSR_MPM_BASE +i)
#else
    #define DUMP_CSRS(i) \
        csr_mem[(i*2)+0] = csr_read(VX_CSR_MPM_BASE + i); \
        csr_mem[(i*2)+1] = csr_read(VX_CSR_MPM_BASE + i + (VX_CSR_MPM_BASE_H - VX_CSR_MPM_BASE))
#endif

void vx_perf_dump() {
    int core_id = vx_core_id();
    // 96 uint32_t = 48 uint64_t counters per core (extended to support TLB counters at B20-B24)
    uint32_t * const csr_mem = (uint32_t*)(IO_MPM_ADDR + 96 * sizeof(uint32_t) * core_id);
    DUMP_CSRS(0);
    //DUMP_CSRS(1); reserved for exitcode
    DUMP_CSRS(2);
    DUMP_CSRS(3);
    DUMP_CSRS(4);
    DUMP_CSRS(5);
    DUMP_CSRS(6);
    DUMP_CSRS(7);
    DUMP_CSRS(8);
    DUMP_CSRS(9);
    DUMP_CSRS(10);
    DUMP_CSRS(11);
    DUMP_CSRS(12);
    DUMP_CSRS(13);
    DUMP_CSRS(14);
    DUMP_CSRS(15);
    DUMP_CSRS(16);
    DUMP_CSRS(17);
    DUMP_CSRS(18);
    DUMP_CSRS(19);
    DUMP_CSRS(20);
    DUMP_CSRS(21);
    DUMP_CSRS(22);
    DUMP_CSRS(23);
    DUMP_CSRS(24);
    DUMP_CSRS(25);
    DUMP_CSRS(26);
    DUMP_CSRS(27);
    DUMP_CSRS(28);
    DUMP_CSRS(29);
    DUMP_CSRS(30);
    DUMP_CSRS(31);
#ifdef VM_ENABLE
    // TLB performance counters (B20-B24, offset 32-36)
    DUMP_CSRS(32);  // VX_CSR_MPM_TLB_READS
    DUMP_CSRS(33);  // VX_CSR_MPM_TLB_HITS
    DUMP_CSRS(34);  // VX_CSR_MPM_TLB_MISSES
    DUMP_CSRS(35);  // VX_CSR_MPM_TLB_EVICTS
    DUMP_CSRS(36);  // VX_CSR_MPM_PTW_WALKS
    DUMP_CSRS(37);  // VX_CSR_MPM_PTW_LATENCY
#endif
}

#ifdef __cplusplus
}
#endif
