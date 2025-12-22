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

#ifdef VM_ENABLE
#define BARE 0
#define SV32 1
#define SV39 8
#endif

.section .init, "ax"
.global _start
.type _start, @function
_start:
  # --- Virtual Memory Setup ---
#ifdef VM_ENABLE
  # Set satp to enable address translation
  # Use PAGE_TABLE_BASE_ADDR (0xF0000000) - matches runtime's page table location
#if VM_ADDR_MODE == SV39
  li    t0, 0x0F0000000             # PAGE_TABLE_BASE_ADDR for SV39 (64-bit)
  srli  t0, t0, 12                  # Convert to PPN
  li    t1, 1
  slli  t1, t1, 63                  # Set SV39 mode bit (bit 63)
  or    t0, t0, t1
  csrw  satp, t0
#elif VM_ADDR_MODE == SV32
  li    t0, 0xF0000000              # PAGE_TABLE_BASE_ADDR for SV32 (32-bit)
  srli  t0, t0, 12                  # Convert to PPN (0xF0000)
  li    t1, 1
  slli  t1, t1, 31                  # Set SV32 mode bit (bit 31)
  or    t0, t0, t1
  csrw  satp, t0
#endif
#endif
  # --- End VM Setup ---

  # call main routine
  call main

  # dump perf counter
  call vx_perf_dump

  # end execution
  .insn r 0x0b, 0, 0, x0, x0, x0
.size _start, .-_start