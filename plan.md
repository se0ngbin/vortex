
- simX already contains a full MMU implementation (TLB + PTW + PTE checks) in sim/common — use that as the behavioral reference.
- The runtime (runtime/simx) includes page-table helpers and is already built/tested with VM flags; it must be extended to set SATP and coordinate TLB flushes / driver-level setup.
- The RTL contains VM-related configuration and partial CSR hooks (SATP/PMP) and memory adapters. You’ll need to add a hardware MMU block (TLB + PTW or TLB + PTW interface), hook SATP into it, and integrate translation requests into the LSU/cache pipeline.

## Where VM is implemented in simX (authoritative reference)
- mem.h
- mem.cpp
  - Key routines: MemoryUnit::vAddr_to_pAddr(), page_table_walk(), tlbLookup(), tlbAdd(), tlbRm(), need_trans(), get/set_satp(), TLB/PTW counters.
  - Behavior to mirror: SV39 page-table format used, permission checks, page-fault semantics, TLB replacement policy, page size handling, handling of device/physical ranges (need_trans()).

Also related simx glue (affects how simulator exposes/uses SATP):
- emulator.cpp (handles CSR read/write, sets mmu SATP)
- processor.cpp / processor_impl.h (SATP parsing / set_satp_by_addr)
- sim/simx/socket.cpp, sim/simx/cluster.cpp, core.cpp (they call into the emulator/MMU and bind the LSU adapters)
- VX_types.h (generated CSR indexes) — useful to cross-check CSR numbers for SATP

(These files are the canonical behavior source you should mirror in RTL.)

## Runtime files you must inspect / change
- vortex.cpp
  - Contains runtime-side page_table_walk() helper and uses for host/device translations. Ensure runtime writes SATP and sets up page tables prior to enabling VM in hardware.
- runtime/simx/* (search for VM_ENABLE uses)
  - Ensure the driver/boot code:  
    - writes SATP to the hardware CSR (or to a simulator socket),  
    - sets page-table base/asid correctly,  
    - performs any required TLB flush operations on context switch / mapping changes.
- ci/regression.sh.in, blackbox.sh (how VM_ENABLE and VM_ADDR_MODE are passed to runtime tests) — update CI/test flags when hardware VM support is present.
- Tests: any tests under tests/regression, tests/kernel, tests/opencl that expect translation behavior — they may need to exercise page faults, mmio with physical vs virtual addresses, and mmap + DMA paths.

Runtime changes are typically:
- ensure SATP write calls into low-level interface (e.g., an ioctl or CSR write) that the RTL CSR block implements,
- add an API/driver path to request TLB shootdown/flush if necessary,
- ensure buffers handed to device are pinned and translated appropriately (or device-driver updates to expose physical addresses).

## RTL files you must inspect and change (concrete file list)
The following files are the main integration points I found; all will need review and most will require edits or additions to implement a hardware MMU.

Configuration & CSR
- VX_config.vh
  - Contains compile-time VM macros: `PAGE_TABLE_BASE_ADDR`, `PTE_SIZE`, `NUM_PTE_ENTRY`, `VM_ADDR_MODE` (SV39), `TLB_SIZE`. Confirm/adjust constants and sizes.
- VX_types.vh
  - Defines CSR indexes (e.g., `VX_CSR_SATP`) — use for SATP CSR wiring.
- VX_csr_data.sv
  - Contains the CSR read/write mux and already references `VX_CSR_SATP`. You must:
    - Implement SATP write path to update MMU (wire SATP into MMU block).
    - Optionally implement TLB flush CSR(s) / handlers if required.

Memory path / LSU / cache adapters (where translation must be inserted)
- VX_mem_unit.sv
  - This module instantiates the LSU adapters and connects to local memory. Insert calls to the MMU or translate physical addresses here (or in the LSU adapter).
- VX_lsu_adapter.sv
  - LSU adapter is a logical place to request a translation before a memory access is issued to the dcache / interconnect; it can stall on TLB miss and reissue after PTW.
- VX_mem_data_adapter.sv
- VX_mem_bank_adapter.sv
- VX_axi_adapter.sv
- Vortex_axi.sv
  - These adapters mediate memory ports to the outside world and AFU. They must be able to accept post-translation physical addresses (or to forward virtual addresses and request translation upstream).
- hw/rtl/mem and cache files:
  - VX_cache_repl.sv (cache replacement/associativity), plus other dcache modules (search hw/rtl/cache/ for files).
  - Cache tags and indexing must be changed to use physical addresses (or implement virtually-indexed physically-tagged scheme with careful aliasing rules). Decide on PIPT vs VIPT.

AFU / accelerator adapters
- vortex_afu.sv (and other AFU adapters)
  - Device/AFU memory ports may need translation or a way to accept physical addresses from the host driver (decide policy: device gets physical addresses, or hardware does VA->PA translation for AFU requests).

Other helpful generated files (for cross-check)
- VX_config.h (generated copy of config macros — helps confirm compile-time values)
- VX_types.h (CSR numbers for software)

## Suggested concrete RTL changes (high level, per area)
1. Add an MMU block
   - New files (canonical examples):
     - hw/rtl/mem/VX_mmu.sv (top-level MMU wrapper)
     - hw/rtl/mem/VX_tlb.sv (TLB storage + lookup/replace logic)
     - hw/rtl/mem/VX_ptw.sv (page-table walker that can issue memory reads to fetch PTEs)
   - Expose control port(s) to:
     - accept virtual address + access type, respond with physical address + flags or page-fault.
     - accept SATP updates and flush requests.
     - optionally expose performance counters.

2. Wire SATP CSR to MMU
   - In hw/rtl/core/VX_csr_data.sv: on SATP write, send satp value to MMU module (and invalidate TLB if ASID changes or per spec).
   - Add SATP readback.

3. Integrate MMU into LSU/cache pipeline
   - Modify VX_lsu_adapter.sv (or VX_mem_unit.sv) so loads/stores go through MMU:
     - On LSU request: check need_trans() equivalent for special physical ranges (IO, device memory), otherwise do TLB lookup (fast path).
     - On TLB miss: stall request, trigger PTW; once PTW returns, update TLB and reissue access.
   - Adjust cache tag/index logic to use physical address (or adopt acceptable VIPT scheme).

4. Add TLB maintenance operations & exceptions
   - Add instructions/CSR or trap mechanism so that page-faults can be signaled to the core (set exception cause).
   - Implement TLBR/TLBW or TLBI-like operations (or at least a global flush on SATP writes/context switch).

5. AFU/device mapping policy
   - Decide how AFU requests are handled: devices likely need physical addresses via driver; if hardware will translate AFU-side virtual addresses, add MMU interface to AFU adapters.

6. Tests & simulation
   - Add RTL tests that exercise:
     - basic VA->PA translation, permission faults, uncached device ranges, TLB refill, SATP writes and TLB flush.
     - cross-verify with sim/common behavior for identical inputs (same page tables and satp).

## Small "contract" for the RTL MMU (what to implement)
- Inputs:
  - virtual address (XLEN width), access type (Load/Store/Fetch), SATP (mode, ASID, PPN), TLB invalidate/flush events.
- Outputs:
  - physical address + allowed bitmask OR page-fault exception (cause code) + faulting level.
- Behavior:
  - Use SV39 PTW semantics to walk page tables and check PTE flags exactly like sim/common/mem.cpp.
  - Update TLB on hits/misses with replacement policy compatible with sim (or documented).
  - Return translation latency: fast path for TLB hit (0 cycles ideally), stall + issue memory reads for PTW on TLB miss.

## Edge cases to cover (tests)
- Page-faults for load, store, instruction fetch (permission bits).
- Misaligned/stale TLB entries after SATP/ASID change or after PTE updates — require flush or coherence.
- Device/address ranges not subject to translation (IO/MMIO) — ensure need_trans() decisions are ported.
- Superpages (large pages) and how TLB stores size bits.
- Concurrent LSU accesses with outstanding PTW for same page (coalescing).

## Implementation order / recommended plan
1. Read sim/common/mem.cpp: fully understand PTW semantics, PTE bit layout, and need_trans() logic.
2. Wire SATP CSR in RTL (VX_csr_data.sv) to a new MMU interface; implement SATP write and test that register is visible.
3. Add a simple MMU model in RTL that uses sim-like behavior but in a simplified method (e.g., microcode or multi-cycle PTW). Initially implement TLB hits only (preload some entries using compile-time PAGE_TABLE_BASE_ADDR) to verify pipelines.
4. Integrate MMU lookup into LSU (VX_lsu_adapter.sv) so physical addresses are produced for downstream cache adapters.
5. Implement PTW and TLB refill logic; add page-fault exception path to core.
6. Update runtime to set SATP and run VM tests; iterate bugfixes until behavior matches sim.

## Files I recommend opening next (I can open them and extract the exact code lines)
- mem.cpp and mem.h (to extract PTW code you should mirror)
- vortex.cpp (to see runtime helpers)
- VX_csr_data.sv (SATP handling)
- VX_mem_unit.sv and VX_lsu_adapter.sv (to identify the best insertion point for MMU)
- VX_config.vh (to confirm page sizes / TLB size configuration)

If you want, I can:
- open and show the relevant snippets from any of the files above (no edits yet), or
- create a small new RTL skeleton MMU (TLB + simple PTW) and wire SATP into CSR as a first patch, or
- produce a concrete per-file patch plan (patches) for the first two implementation steps.

Which next step do you want me to take now? (I suggest: let me open mem.cpp and VX_csr_data.sv and VX_lsu_adapter.sv to extract the exact lines we must mimic/wire.)