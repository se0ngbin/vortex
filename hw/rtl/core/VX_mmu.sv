// Copyright 2024
// MMU Top-Level Module for Vortex GPU
// Implements address translation with TLB and PTW

`include "VX_define.vh"

// VX_mmu sits after VX_mem_unit in the datapath:
//   VX_mem_unit coalesces LSU lanes (4×4=16 bytes) into DCACHE requests (1×16 bytes)
//   VX_mmu receives DCACHE-formatted requests, translates VA→PA, outputs to dcache
// Tag width architecture:
// - TAG_WIDTH (input from VX_mem_unit) = DCACHE_TAG_WIDTH = UUID_WIDTH + DCACHE_TAG_ID_BITS
// - TAG_WIDTH_OUT (output to dcache) = TAG_WIDTH + 3 (TLB serialize + merge arb)
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */

module VX_mmu import VX_gpu_pkg::*; #(
    parameter NUM_REQS       = DCACHE_NUM_REQS,         // Coalesced requests from VX_mem_unit
    parameter DATA_SIZE      = DCACHE_WORD_SIZE,        // 16 bytes (coalesced line size)
    parameter TAG_WIDTH      = DCACHE_TAG_WIDTH_BASE,   // Input DCACHE tag width (before expansion)
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH,
    parameter ADDR_WIDTH     = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE),  // 28 bits for DATA_SIZE=16
    parameter FLAGS_WIDTH    = MEM_FLAGS_WIDTH,
    parameter EBUF_SIZE      = 2                        // Elastic buffer depth
    // Output width = TAG_WIDTH + TLB_SOURCE_BITS + ARB_BITS (expanded by VX_mem_arb)
) (
    input wire clk,
    input wire reset,

    // SATP from CSR (root page table address for PTW)
    input wire [31:0] satp,

    // Input from VX_mem_unit (DCACHE-formatted, TAG_WIDTH bits)
    VX_mem_bus_if.slave  lsu_mem_if [NUM_REQS],

    // Output to dcache (TAG_WIDTH_OUT bits)
    VX_mem_bus_if.master dcache_mem_if [NUM_REQS]
);

    // =========================================================================
    // Section 0: Address-Based Bypass Control
    // =========================================================================

    // Address regions that bypass translation (SV32)
    localparam [31:0] IO_REGION_END   = 32'h00010000;  // IO: 0x40 - 0x10000
    localparam [31:0] STARTUP_ADDR    = 32'h80000000;  // Startup code base
    localparam [31:0] STARTUP_END     = 32'h80040000;  // Startup code end
    localparam [31:0] PT_BASE_ADDR    = 32'hF0000000;  // Page table region

    // Address-based bypass decision function
    // Returns 1 if address needs translation, 0 if bypass
    function automatic logic needs_translation(input logic [31:0] full_addr);
        // BARE mode (satp[31]=0) - always bypass
        if (!satp[31]) return 1'b0;
        // IO region - bypass
        if (full_addr < IO_REGION_END) return 1'b0;
        // Startup region - bypass
        if (full_addr >= STARTUP_ADDR && full_addr < STARTUP_END) return 1'b0;
        // Page table region - bypass
        if (full_addr >= PT_BASE_ADDR) return 1'b0;
        // User space - translate
        return 1'b1;
    endfunction

    // =========================================================================
    // Local Parameters
    // =========================================================================

    localparam DATA_WIDTH    = DATA_SIZE * 8;

    // TLB source encoding bits: UP(CLOG2(NUM_REQS)) for routing back to correct port
    localparam TLB_SOURCE_BITS = `UP(`CLOG2(NUM_REQS));

    // Tag width after TLB serialize (input + TLB source bits)
    // VX_mem_arb will add additional bits for arbiter routing
    localparam TAG_WIDTH_TLB = TAG_WIDTH + TLB_SOURCE_BITS;

    // Request/response data widths use input TAG_WIDTH
    localparam REQ_DATAW     = 1 + ADDR_WIDTH + DATA_WIDTH + DATA_SIZE + FLAGS_WIDTH + TAG_WIDTH;
    localparam RSP_DATAW     = DATA_WIDTH + TAG_WIDTH;

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

    // Bypass path interfaces - one per lane (tag padded to match TLB width)
    VX_mem_bus_if #(
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH_TLB),
        .FLAGS_WIDTH (FLAGS_WIDTH)
    ) bypass_dcache_if[NUM_REQS]();

    // PTW memory interface (same tag width as TLB output)
    VX_mem_bus_if #(
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH_TLB),
        .FLAGS_WIDTH (FLAGS_WIDTH)
    ) ptw_mem_if();

    // Combined interfaces for merge arbiter input (9 total: 4 bypass + 4 TLB + 1 PTW)
    // Input mapping: [0..3]=bypass, [4..7]=TLB, [8]=PTW
    VX_mem_bus_if #(
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH_TLB),
        .FLAGS_WIDTH (FLAGS_WIDTH)
    ) merge_in_if[2 * NUM_REQS + 1]();

    // Note: arb_out_if was removed - arbiter connects directly to dcache_mem_if

    // =========================================================================
    // Section 1: Bidirectional Elastic Buffers for TLB Path
    // =========================================================================

    // NOTE: We must pack/unpack individual fields because the interface's packed
    // req_data_t/rsp_data_t include tag_t with UUID_WIDTH, making them larger
    // than our REQ_DATAW/RSP_DATAW calculations assume.
    //
    // These buffers are ONLY used for the TLB path (address needs translation).
    // Bypass path goes directly to bypass_dcache_if without buffering.
    // The decision is made per-lane based on address in Section 5.

    // Intermediate signals for elastic buffer outputs
    wire [NUM_REQS-1:0] ebuf_req_ready;  // Ready from elastic buffer
    wire [NUM_REQS-1:0] ebuf_rsp_valid;  // Valid from elastic buffer
    wire [DATA_WIDTH-1:0] ebuf_rsp_data [NUM_REQS];
    wire [TAG_WIDTH-1:0]  ebuf_rsp_tag  [NUM_REQS];
    wire [NUM_REQS-1:0]   ebuf_rsp_ready; // Backpressure from response arbiter

    // Per-lane translation decision (forward declared, assigned in Section 5)
    wire [NUM_REQS-1:0] lane_needs_trans_ebuf;

    for (genvar i = 0; i < NUM_REQS; i++) begin : g_elastic_buffers

        // Reconstruct full address for translation decision
        wire [31:0] full_addr_ebuf = {lsu_mem_if[i].req_data.addr, {`CLOG2(DATA_SIZE){1'b0}}};
        assign lane_needs_trans_ebuf[i] = needs_translation(full_addr_ebuf);

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

        // Request path buffer (LSU → TLB) - only for translation path
        VX_elastic_buffer #(
            .DATAW  (REQ_DATAW),
            .SIZE   (EBUF_SIZE),
            .OUT_REG(0)
        ) req_buffer (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (lsu_mem_if[i].req_valid && lane_needs_trans_ebuf[i]),  // Only when translating
            .data_in   (req_data_in_packed),
            .ready_in  (ebuf_req_ready[i]),
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

        // Response path buffer (TLB → LSU)
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
            .valid_out (ebuf_rsp_valid[i]),
            .data_out  (rsp_data_out_packed),
            .ready_out (ebuf_rsp_ready[i])  // Backpressure from response arbiter
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
    // Section 5: Per-Lane Bypass Path Logic
    // =========================================================================
    // For each lane, check address and route to bypass or TLB path
    // Bypass path: no translation needed, pad tag with zeros at LSB
    // TLB path: translation needed, goes through elastic buffer → TLB

    // Per-lane bypass decision signals
    wire [NUM_REQS-1:0] lane_needs_trans;
    wire [NUM_REQS-1:0] lane_bypass;

    for (genvar i = 0; i < NUM_REQS; i++) begin : g_bypass_path
        // Reconstruct full 32-bit address from ADDR_WIDTH address
        // ADDR_WIDTH = MEM_ADDR_WIDTH - CLOG2(DATA_SIZE) = 32 - 4 = 28 bits
        // Full address = {addr[27:0], 4'b0000} for DATA_SIZE=16
        wire [31:0] full_addr = {lsu_mem_if[i].req_data.addr, {`CLOG2(DATA_SIZE){1'b0}}};

        assign lane_needs_trans[i] = needs_translation(full_addr);
        assign lane_bypass[i] = ~lane_needs_trans[i];

        // Drive bypass_dcache_if - only valid when bypass (no translation needed)
        assign bypass_dcache_if[i].req_valid = lsu_mem_if[i].req_valid && lane_bypass[i];
        assign bypass_dcache_if[i].req_data.rw     = lsu_mem_if[i].req_data.rw;
        assign bypass_dcache_if[i].req_data.addr   = lsu_mem_if[i].req_data.addr;
        assign bypass_dcache_if[i].req_data.data   = lsu_mem_if[i].req_data.data;
        assign bypass_dcache_if[i].req_data.byteen = lsu_mem_if[i].req_data.byteen;
        assign bypass_dcache_if[i].req_data.flags  = lsu_mem_if[i].req_data.flags;

        // Pad tag with zeros at LSB to match TLB tag width
        // TLB uses VX_bits_insert with POS=0, so TLB source bits are at LSB
        // Bypass pads zeros at same position: {original_tag, {TLB_SOURCE_BITS{1'b0}}}
        assign bypass_dcache_if[i].req_data.tag = {lsu_mem_if[i].req_data.tag[TAG_WIDTH-1:0],
                                                   {TLB_SOURCE_BITS{1'b0}}};

        // bypass_dcache_if[i].rsp_ready is now set by response arbiter in Section 8
    end

    // =========================================================================
    // Section 6: Connect All Paths to Merge Arbiter Inputs
    // =========================================================================
    // Input mapping: [0..NUM_REQS-1]=bypass, [NUM_REQS..2*NUM_REQS-1]=TLB, [2*NUM_REQS]=PTW

    // Connect bypass outputs [0:3] to merge_in_if [0:3]
    for (genvar i = 0; i < NUM_REQS; i++) begin : g_bypass_to_merge
        assign merge_in_if[i].req_valid = bypass_dcache_if[i].req_valid;
        assign merge_in_if[i].req_data  = bypass_dcache_if[i].req_data;
        assign bypass_dcache_if[i].req_ready  = merge_in_if[i].req_ready;

        assign bypass_dcache_if[i].rsp_valid  = merge_in_if[i].rsp_valid;
        assign bypass_dcache_if[i].rsp_data   = merge_in_if[i].rsp_data;
        assign merge_in_if[i].rsp_ready = bypass_dcache_if[i].rsp_ready;
    end

    // Connect TLB outputs [0:3] to merge_in_if [4:7]
    for (genvar i = 0; i < NUM_REQS; i++) begin : g_tlb_to_merge
        assign merge_in_if[NUM_REQS + i].req_valid = tlb_out_if[i].req_valid;
        assign merge_in_if[NUM_REQS + i].req_data  = tlb_out_if[i].req_data;
        assign tlb_out_if[i].req_ready  = merge_in_if[NUM_REQS + i].req_ready;

        assign tlb_out_if[i].rsp_valid  = merge_in_if[NUM_REQS + i].rsp_valid;
        assign tlb_out_if[i].rsp_data   = merge_in_if[NUM_REQS + i].rsp_data;
        assign merge_in_if[NUM_REQS + i].rsp_ready = tlb_out_if[i].rsp_ready;
    end

    // Connect PTW output to merge_in_if [8]
    assign merge_in_if[2 * NUM_REQS].req_valid = ptw_mem_if.req_valid;
    assign merge_in_if[2 * NUM_REQS].req_data  = ptw_mem_if.req_data;
    assign ptw_mem_if.req_ready            = merge_in_if[2 * NUM_REQS].req_ready;

    assign ptw_mem_if.rsp_valid            = merge_in_if[2 * NUM_REQS].rsp_valid;
    assign ptw_mem_if.rsp_data             = merge_in_if[2 * NUM_REQS].rsp_data;
    assign merge_in_if[2 * NUM_REQS].rsp_ready = ptw_mem_if.rsp_ready;

    // =========================================================================
    // Section 7: Merge Arbiter (9-to-4)
    // =========================================================================

    VX_mem_arb #(
        .NUM_INPUTS     (2 * NUM_REQS + 1),   // 9 inputs (4 bypass + 4 TLB + 1 PTW)
        .NUM_OUTPUTS    (NUM_REQS),            // 4 outputs (to dcache)
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH_TLB),
        .TAG_SEL_IDX    (TAG_WIDTH_TLB),       // Insert merge bits at MSB
        .ARBITER        ("R"),                 // Round-robin
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH),      // Must match interface
        .ADDR_WIDTH     (ADDR_WIDTH),          // Must match interface
        .FLAGS_WIDTH    (FLAGS_WIDTH),         // Must match interface
        .REQ_OUT_BUF    (2),
        .RSP_OUT_BUF    (2)
    ) merge_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (merge_in_if),
        .bus_out_if (dcache_mem_if)    // Connect directly to dcache output
    );

    // =========================================================================
    // Section 8: LSU Interface Connections
    // =========================================================================
    //
    // With address-based bypass, both bypass and TLB paths go through the arbiter.
    // The arbiter (merge_arb) connects directly to dcache_mem_if.
    // Responses are automatically routed back through arbiter to:
    //   - bypass_dcache_if (for bypass path responses)
    //   - tlb_out_if → TLB → elastic buffer (for TLB path responses)
    //
    // This section handles:
    //   1. LSU request ready (from bypass or TLB elastic buffer)
    //   2. LSU response merging (bypass + TLB responses)

    for (genvar i = 0; i < NUM_REQS; i++) begin : g_lsu_if

        // =====================================================================
        // LSU Request Ready
        // =====================================================================
        // If bypass: ready from bypass_dcache_if.req_ready (through arbiter)
        // If translate: ready from elastic buffer (ebuf_req_ready)

        assign lsu_mem_if[i].req_ready = lane_needs_trans_ebuf[i] ?
            ebuf_req_ready[i] : bypass_dcache_if[i].req_ready;

        // =====================================================================
        // LSU Response Arbitration (Bypass + TLB responses)
        // =====================================================================
        //
        // Bypass and TLB responses can arrive simultaneously (different transactions).
        // Use VX_stream_arb for proper arbitration with backpressure.
        //
        // Tag restoration:
        // - Bypass: tag has {original_tag, zeros_at_LSB}, extract [TAG_WIDTH_TLB-1:TLB_SOURCE_BITS]
        // - TLB: ebuf_rsp_tag is already TAG_WIDTH bits (TLB internally restored tag)

        // Response data width: data + tag
        localparam LSU_RSP_DATAW = DATA_WIDTH + TAG_WIDTH;

        // Pack bypass response: extract original tag from TLB-width tag
        wire [TAG_WIDTH-1:0] bypass_rsp_tag_restored =
            bypass_dcache_if[i].rsp_data.tag[TAG_WIDTH_TLB-1:TLB_SOURCE_BITS];
        wire [LSU_RSP_DATAW-1:0] bypass_rsp_packed = {
            bypass_dcache_if[i].rsp_data.data,
            bypass_rsp_tag_restored
        };

        // Pack ebuf response
        wire [LSU_RSP_DATAW-1:0] ebuf_rsp_packed = {
            ebuf_rsp_data[i],
            ebuf_rsp_tag[i]
        };

        // Arbiter input/output signals
        wire [1:0] rsp_arb_valid_in = {ebuf_rsp_valid[i], bypass_dcache_if[i].rsp_valid};
        wire [1:0][LSU_RSP_DATAW-1:0] rsp_arb_data_in = {ebuf_rsp_packed, bypass_rsp_packed};
        wire [1:0] rsp_arb_ready_in;
        wire rsp_arb_valid_out;
        wire [LSU_RSP_DATAW-1:0] rsp_arb_data_out;

        VX_stream_arb #(
            .NUM_INPUTS  (2),
            .NUM_OUTPUTS (1),
            .DATAW       (LSU_RSP_DATAW),
            .ARBITER     ("R"),   // Round-robin for fairness
            .OUT_BUF     (0)
        ) rsp_arb (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (rsp_arb_valid_in),
            .data_in   (rsp_arb_data_in),
            .ready_in  (rsp_arb_ready_in),
            .valid_out (rsp_arb_valid_out),
            .data_out  (rsp_arb_data_out),
            .ready_out (lsu_mem_if[i].rsp_ready),
            `UNUSED_PIN (sel_out)
        );

        // Connect arbiter ready outputs to sources
        assign bypass_dcache_if[i].rsp_ready = rsp_arb_ready_in[0];
        assign ebuf_rsp_ready[i] = rsp_arb_ready_in[1];

        // Unpack arbiter output to LSU interface
        assign lsu_mem_if[i].rsp_valid = rsp_arb_valid_out;
        assign lsu_mem_if[i].rsp_data.data = rsp_arb_data_out[LSU_RSP_DATAW-1 -: DATA_WIDTH];
        assign lsu_mem_if[i].rsp_data.tag = rsp_arb_data_out[TAG_WIDTH-1:0];

    end

endmodule
