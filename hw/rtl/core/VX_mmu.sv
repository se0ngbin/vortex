// Copyright 2024
// MMU Top-Level Module for Vortex GPU
// Implements address translation with TLB and PTW

`include "VX_define.vh"

// TODO: Tag width mismatches between MMU internal interfaces and dcache
// need architectural alignment - currently suppressed for bypass testing
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */

module VX_mmu import VX_gpu_pkg::*; #(
    parameter NUM_REQS       = 4,
    parameter DATA_SIZE      = 4,
    parameter TAG_WIDTH      = 32,
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH,
    parameter ADDR_WIDTH     = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE),
    parameter FLAGS_WIDTH    = MEM_FLAGS_WIDTH,  // Use actual width from VX_gpu_pkg
    parameter EBUF_SIZE      = 2      // Elastic buffer depth
) (
    input wire clk,
    input wire reset,

    // SATP from CSR (root page table address for PTW)
    input wire [31:0] satp,

    // Input from LSU (via VX_mem_unit)
    VX_mem_bus_if.slave  lsu_mem_if [NUM_REQS],

    // Output to dcache
    VX_mem_bus_if.master dcache_mem_if [NUM_REQS]
);

    // =========================================================================
    // Section 0: Bypass Control
    // =========================================================================

    // VM mode from SATP: 0 = BARE (bypass), 1 = SV32 (translate)
    wire vm_enabled = satp[31];

    // =========================================================================
    // Local Parameters
    // =========================================================================

    localparam DATA_WIDTH    = DATA_SIZE * 8;
    localparam REQ_DATAW     = 1 + ADDR_WIDTH + DATA_WIDTH + DATA_SIZE + FLAGS_WIDTH + TAG_WIDTH;
    localparam RSP_DATAW     = DATA_WIDTH + TAG_WIDTH;

    // Tag width after TLB serialize (adds 2 bits for source port encoding)
    localparam TAG_WIDTH_TLB = TAG_WIDTH + 2;

    // Tag width after merge arbiter (adds 1 bit for 5-to-4 source encoding)
    localparam TAG_WIDTH_OUT = TAG_WIDTH_TLB + 1;

    // Extra tag bits needed for bypass padding (TLB + arbiter encoding)
    localparam TAG_PAD_BITS = TAG_WIDTH_OUT - TAG_WIDTH;  // 3 bits

    // =========================================================================
    // Internal Interfaces
    // =========================================================================

    // After elastic buffers, before TLB
    VX_mem_bus_if #(
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH),
        .FLAGS_WIDTH (FLAGS_WIDTH)
    ) buffered_if[NUM_REQS]();

    // After TLB (with extended tag), before merge arbiter
    VX_mem_bus_if #(
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH_TLB),
        .FLAGS_WIDTH (FLAGS_WIDTH)
    ) tlb_out_if[NUM_REQS]();

    // PTW memory interface (same tag width as TLB output)
    VX_mem_bus_if #(
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH_TLB),
        .FLAGS_WIDTH (FLAGS_WIDTH)
    ) ptw_mem_if();

    // Combined interfaces for merge arbiter input (5 total: 4 TLB + 1 PTW)
    VX_mem_bus_if #(
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH_TLB),
        .FLAGS_WIDTH (FLAGS_WIDTH)
    ) merge_in_if[NUM_REQS + 1]();

    // Arbiter output (intermediate, before bypass mux)
    VX_mem_bus_if #(
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH_OUT),
        .FLAGS_WIDTH (FLAGS_WIDTH)
    ) arb_out_if[NUM_REQS]();

    // =========================================================================
    // Section 1: Bidirectional Elastic Buffers
    // =========================================================================

    // NOTE: We must pack/unpack individual fields because the interface's packed
    // req_data_t/rsp_data_t include tag_t with UUID_WIDTH, making them larger
    // than our REQ_DATAW/RSP_DATAW calculations assume.
    //
    // In bypass mode (vm_enabled=0), elastic buffers are bypassed.
    // In translate mode (vm_enabled=1), elastic buffers are used.

    // Intermediate signals for elastic buffer outputs (to avoid multiple drivers)
    wire [NUM_REQS-1:0] ebuf_req_ready;  // Ready from elastic buffer to LSU
    wire [NUM_REQS-1:0] ebuf_rsp_valid;  // Valid from elastic buffer to LSU
    wire [DATA_WIDTH-1:0] ebuf_rsp_data [NUM_REQS];
    wire [TAG_WIDTH-1:0]  ebuf_rsp_tag  [NUM_REQS];

    for (genvar i = 0; i < NUM_REQS; i++) begin : g_elastic_buffers

        // Packed request data for elastic buffer
        wire [REQ_DATAW-1:0] req_data_in_packed;
        wire [REQ_DATAW-1:0] req_data_out_packed;

        // Pack input from interface
        assign req_data_in_packed = {
            lsu_mem_if[i].req_data.rw,
            lsu_mem_if[i].req_data.addr,
            lsu_mem_if[i].req_data.data,
            lsu_mem_if[i].req_data.byteen,
            lsu_mem_if[i].req_data.flags[FLAGS_WIDTH-1:0],
            lsu_mem_if[i].req_data.tag[TAG_WIDTH-1:0]
        };

        // Request path buffer (LSU → TLB) - only used in translate mode
        VX_elastic_buffer #(
            .DATAW  (REQ_DATAW),
            .SIZE   (EBUF_SIZE),
            .OUT_REG(0)
        ) req_buffer (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (vm_enabled ? lsu_mem_if[i].req_valid : 1'b0),  // Disable in bypass
            .data_in   (req_data_in_packed),
            .ready_in  (ebuf_req_ready[i]),                             // Intermediate signal
            .valid_out (buffered_if[i].req_valid),
            .data_out  (req_data_out_packed),
            .ready_out (buffered_if[i].req_ready)
        );

        // Unpack output to interface
        assign buffered_if[i].req_data.rw     = req_data_out_packed[REQ_DATAW-1];
        assign buffered_if[i].req_data.addr   = req_data_out_packed[REQ_DATAW-2 -: ADDR_WIDTH];
        assign buffered_if[i].req_data.data   = req_data_out_packed[REQ_DATAW-2-ADDR_WIDTH -: DATA_WIDTH];
        assign buffered_if[i].req_data.byteen = req_data_out_packed[REQ_DATAW-2-ADDR_WIDTH-DATA_WIDTH -: DATA_SIZE];
        assign buffered_if[i].req_data.flags  = req_data_out_packed[REQ_DATAW-2-ADDR_WIDTH-DATA_WIDTH-DATA_SIZE -: FLAGS_WIDTH];
        assign buffered_if[i].req_data.tag    = req_data_out_packed[TAG_WIDTH-1:0];

        // Packed response data for elastic buffer
        wire [RSP_DATAW-1:0] rsp_data_in_packed;
        wire [RSP_DATAW-1:0] rsp_data_out_packed;

        // Pack input from interface
        assign rsp_data_in_packed = {
            buffered_if[i].rsp_data.data,
            buffered_if[i].rsp_data.tag[TAG_WIDTH-1:0]
        };

        // Response path buffer (TLB → LSU) - only used in translate mode
        VX_elastic_buffer #(
            .DATAW  (RSP_DATAW),
            .SIZE   (EBUF_SIZE),
            .OUT_REG(0)
        ) rsp_buffer (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (buffered_if[i].rsp_valid),
            .data_in   (rsp_data_in_packed),
            .ready_in  (buffered_if[i].rsp_ready),
            .valid_out (ebuf_rsp_valid[i]),                             // Intermediate signal
            .data_out  (rsp_data_out_packed),
            .ready_out (vm_enabled ? lsu_mem_if[i].rsp_ready : 1'b1)    // Always ready in bypass
        );

        // Unpack elastic buffer output to intermediate signals
        assign ebuf_rsp_data[i] = rsp_data_out_packed[RSP_DATAW-1 -: DATA_WIDTH];
        assign ebuf_rsp_tag[i]  = rsp_data_out_packed[TAG_WIDTH-1:0];

    end

    // =========================================================================
    // Section 2: TLB Miss/Fill Interface Signals
    // =========================================================================

    wire        tlb_miss_valid;
    wire        tlb_miss_ready;
    wire [31:0] tlb_miss_vaddr;

    wire        tlb_fill_valid;
    wire        tlb_fill_ready;
    wire [31:0] tlb_fill_vaddr;
    wire [31:0] tlb_fill_paddr;
    wire [7:0]  tlb_fill_flags;

    // =========================================================================
    // Section 3: TLB Module
    // =========================================================================

    VX_mmu_tlb #(
        .NUM_REQS      (NUM_REQS),
        .DATA_SIZE     (DATA_SIZE),
        .TAG_WIDTH_IN  (TAG_WIDTH),
        .TAG_WIDTH_OUT (TAG_WIDTH_TLB),
        .ADDR_WIDTH    (ADDR_WIDTH),
        .FLAGS_WIDTH   (FLAGS_WIDTH)
    ) tlb_unit (
        .clk           (clk),
        .reset         (reset),

        // Input from elastic buffers
        .tlb_in_if     (buffered_if),

        // Output to merge arbiter
        .tlb_out_if    (tlb_out_if),

        // Miss interface to PTW
        .miss_valid    (tlb_miss_valid),
        .miss_ready    (tlb_miss_ready),
        .miss_vaddr    (tlb_miss_vaddr),

        // Fill interface from PTW
        .fill_valid    (tlb_fill_valid),
        .fill_ready    (tlb_fill_ready),
        .fill_vaddr    (tlb_fill_vaddr),
        .fill_paddr    (tlb_fill_paddr),
        .fill_flags    (tlb_fill_flags)
    );

    // =========================================================================
    // Section 4: PTW Module
    // =========================================================================

    VX_mmu_ptw #(
        .DATA_SIZE     (DATA_SIZE),
        .TAG_WIDTH     (TAG_WIDTH_TLB),
        .ADDR_WIDTH    (ADDR_WIDTH),
        .FLAGS_WIDTH   (FLAGS_WIDTH)
    ) ptw_unit (
        .clk           (clk),
        .reset         (reset),

        // SATP from CSR
        .satp          (satp),

        // Miss interface from TLB
        .miss_valid    (tlb_miss_valid),
        .miss_ready    (tlb_miss_ready),
        .miss_vaddr    (tlb_miss_vaddr),

        // Fill interface to TLB
        .fill_valid    (tlb_fill_valid),
        .fill_ready    (tlb_fill_ready),
        .fill_vaddr    (tlb_fill_vaddr),
        .fill_paddr    (tlb_fill_paddr),
        .fill_flags    (tlb_fill_flags),

        // Memory interface for page table walks
        .ptw_mem_if    (ptw_mem_if)
    );

    // =========================================================================
    // Section 5: Connect TLB and PTW outputs to merge arbiter inputs
    // =========================================================================

    // Connect TLB outputs [0:3] to merge_in_if [0:3]
    for (genvar i = 0; i < NUM_REQS; i++) begin : g_tlb_to_merge
        assign merge_in_if[i].req_valid = tlb_out_if[i].req_valid;
        assign merge_in_if[i].req_data  = tlb_out_if[i].req_data;
        assign tlb_out_if[i].req_ready  = merge_in_if[i].req_ready;

        assign tlb_out_if[i].rsp_valid  = merge_in_if[i].rsp_valid;
        assign tlb_out_if[i].rsp_data   = merge_in_if[i].rsp_data;
        assign merge_in_if[i].rsp_ready = tlb_out_if[i].rsp_ready;
    end

    // Connect PTW output to merge_in_if [4]
    assign merge_in_if[NUM_REQS].req_valid = ptw_mem_if.req_valid;
    assign merge_in_if[NUM_REQS].req_data  = ptw_mem_if.req_data;
    assign ptw_mem_if.req_ready            = merge_in_if[NUM_REQS].req_ready;

    assign ptw_mem_if.rsp_valid            = merge_in_if[NUM_REQS].rsp_valid;
    assign ptw_mem_if.rsp_data             = merge_in_if[NUM_REQS].rsp_data;
    assign merge_in_if[NUM_REQS].rsp_ready = ptw_mem_if.rsp_ready;

    // =========================================================================
    // Section 6: Merge Arbiter (5-to-4)
    // =========================================================================

    VX_mem_arb #(
        .NUM_INPUTS  (NUM_REQS + 1),  // 5 inputs (4 TLB + 1 PTW)
        .NUM_OUTPUTS (NUM_REQS),       // 4 outputs (to dcache)
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH_TLB),
        .TAG_SEL_IDX (TAG_WIDTH_TLB),  // Insert merge bits at MSB
        .ARBITER     ("R"),            // Round-robin
        .REQ_OUT_BUF (2),
        .RSP_OUT_BUF (2)
    ) merge_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (merge_in_if),
        .bus_out_if (arb_out_if)       // Output to intermediate interface
    );

    // =========================================================================
    // Section 7: Output Mux (Bypass vs Translation)
    // =========================================================================
    //
    // vm_enabled = 0 (BARE):  lsu_mem_if → dcache_mem_if (direct bypass)
    // vm_enabled = 1 (SV32):  arb_out_if → dcache_mem_if (translated path)
    //
    // Tag width handling:
    //   - Bypass: pad lsu_mem_if tag (32-bit) with zeros → 35-bit
    //   - Translate: arb_out_if already has 35-bit tag

    for (genvar i = 0; i < NUM_REQS; i++) begin : g_output_mux

        // =====================================================================
        // Request Path to Dcache
        // =====================================================================

        assign dcache_mem_if[i].req_valid = vm_enabled ?
            arb_out_if[i].req_valid : lsu_mem_if[i].req_valid;

        assign dcache_mem_if[i].req_data.rw = vm_enabled ?
            arb_out_if[i].req_data.rw : lsu_mem_if[i].req_data.rw;

        assign dcache_mem_if[i].req_data.addr = vm_enabled ?
            arb_out_if[i].req_data.addr : lsu_mem_if[i].req_data.addr;

        assign dcache_mem_if[i].req_data.data = vm_enabled ?
            arb_out_if[i].req_data.data : lsu_mem_if[i].req_data.data;

        assign dcache_mem_if[i].req_data.byteen = vm_enabled ?
            arb_out_if[i].req_data.byteen : lsu_mem_if[i].req_data.byteen;

        assign dcache_mem_if[i].req_data.flags = vm_enabled ?
            arb_out_if[i].req_data.flags : lsu_mem_if[i].req_data.flags;

        // Tag: pad with zeros in bypass mode (32-bit → 35-bit)
        assign dcache_mem_if[i].req_data.tag = vm_enabled ?
            arb_out_if[i].req_data.tag :
            {{TAG_PAD_BITS{1'b0}}, lsu_mem_if[i].req_data.tag[TAG_WIDTH-1:0]};

        // =====================================================================
        // Request Ready - back to sources
        // =====================================================================

        // Arbiter ready: from dcache when translating, 0 when bypassing
        assign arb_out_if[i].req_ready = vm_enabled ?
            dcache_mem_if[i].req_ready : 1'b0;

        // LSU ready: from elastic buffer when translating, from dcache when bypassing
        assign lsu_mem_if[i].req_ready = vm_enabled ?
            ebuf_req_ready[i] : dcache_mem_if[i].req_ready;

        // =====================================================================
        // Response Path from Dcache
        // =====================================================================

        // LSU response valid: from elastic buffer when translating, from dcache when bypassing
        assign lsu_mem_if[i].rsp_valid = vm_enabled ?
            ebuf_rsp_valid[i] : dcache_mem_if[i].rsp_valid;

        // Arbiter response valid: from dcache when translating, 0 when bypassing
        assign arb_out_if[i].rsp_valid = vm_enabled ?
            dcache_mem_if[i].rsp_valid : 1'b0;

        // LSU response data: from elastic buffer when translating, from dcache when bypassing
        assign lsu_mem_if[i].rsp_data.data = vm_enabled ?
            ebuf_rsp_data[i] : dcache_mem_if[i].rsp_data.data;

        // Arbiter response data: from dcache when translating
        assign arb_out_if[i].rsp_data.data = dcache_mem_if[i].rsp_data.data;

        // LSU response tag: from elastic buffer when translating, strip upper bits when bypassing
        assign lsu_mem_if[i].rsp_data.tag = vm_enabled ?
            ebuf_rsp_tag[i] : dcache_mem_if[i].rsp_data.tag[TAG_WIDTH-1:0];

        // Arbiter response tag: from dcache when translating
        assign arb_out_if[i].rsp_data.tag = dcache_mem_if[i].rsp_data.tag;

        // =====================================================================
        // Response Ready - back to dcache
        // =====================================================================

        // Dcache response ready: from arbiter when translating, from LSU when bypassing
        assign dcache_mem_if[i].rsp_ready = vm_enabled ?
            arb_out_if[i].rsp_ready : lsu_mem_if[i].rsp_ready;

    end

endmodule
