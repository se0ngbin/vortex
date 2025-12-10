// Copyright 2024
// Page Table Walker (PTW) Module for Vortex GPU MMU
// Stub implementation - handles interfaces only

`include "VX_define.vh"

// Suppress warnings for stub implementation - PTE validity checks
// are defined but not yet used in this stub version
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

module VX_mmu_ptw import VX_gpu_pkg::*; #(
    parameter DATA_SIZE      = DCACHE_WORD_SIZE,        // 16 bytes (coalesced line size)
    parameter TAG_WIDTH      = DCACHE_TAG_WIDTH + `UP(`CLOG2(DCACHE_NUM_REQS)),  // TLB extended tag
    parameter ADDR_WIDTH     = DCACHE_ADDR_WIDTH,       // 28 bits for DATA_SIZE=16
    parameter FLAGS_WIDTH    = MEM_FLAGS_WIDTH
) (
    input wire clk,
    input wire reset,

    // SATP from CSR (root page table address)
    // [31] = Mode (0=BARE, 1=SV32)
    // [30:22] = ASID (ignored)
    // [21:0] = PPN of root page table (use [19:0] for 32-bit PA)
    input wire [31:0]   satp,

    // TLB miss interface (from TLB)
    input  wire          miss_valid,
    output wire          miss_ready,
    input  wire [31:0]   miss_vaddr,

    // TLB fill interface (to TLB)
    output wire          fill_valid,
    input  wire          fill_ready,
    output wire [31:0]   fill_vaddr,
    output wire [31:0]   fill_paddr,
    output wire [7:0]    fill_flags,

    // Memory request interface (for page table walks)
    VX_mem_bus_if.master ptw_mem_if,

    // Performance counter output
`ifdef PERF_ENABLE
    output wire [PERF_CTR_BITS-1:0] perf_ptw_latency
`else
    output wire perf_ptw_latency_placeholder
`endif
);

    // =========================================================================
    // Local Parameters
    // =========================================================================

    localparam DATA_WIDTH = DATA_SIZE * 8;

    // =========================================================================
    // VM Parameters (SV32 - fixed by RISC-V spec)
    // =========================================================================
    localparam VPN_WIDTH = 20;           // 20-bit VPN for SV32
    localparam PPN_WIDTH = VPN_WIDTH;    // 20-bit PPN for SV32
    localparam PAGE_OFFSET_BITS = 12;    // 12-bit byte page offset (4KB page)
    localparam VPN_LEVEL_BITS = 10;      // 10 bits per VPN level in SV32
    localparam PTE_SIZE_BYTES = 4;       // 4-byte PTE for SV32
    localparam PTE_SHIFT = `CLOG2(PTE_SIZE_BYTES);  // 2 (for PTE alignment)

    // =========================================================================
    // PTW State Machine (Stubbed)
    // =========================================================================

    // 6-state PTW for SV32 (2-level page table)
    // Each state has ONE responsibility for clarity and debugging

    typedef enum logic [2:0] {
        PTW_IDLE    = 3'd0,  // Wait for TLB miss
        PTW_L1_REQ  = 3'd1,  // Send Level 1 PTE request to memory
        PTW_L1_RESP = 3'd2,  // Wait for Level 1 response, parse PTE
        PTW_L0_REQ  = 3'd3,  // Send Level 0 PTE request to memory
        PTW_L0_RESP = 3'd4,  // Wait for Level 0 response, parse PTE
        PTW_FILL    = 3'd5   // Send translation to TLB
    } ptw_state_t;

    ptw_state_t state, state_next;

    // =========================================================================
    // PTW Registers
    // =========================================================================

    // Captured miss virtual address
    reg [31:0] pending_vaddr;

    // Level 1 PTE result (PPN for next level page table)
    reg [PPN_WIDTH-1:0] l1_ppn;

    // Final translation result from Level 0 PTE
    reg [PPN_WIDTH-1:0] final_ppn;
    reg [7:0]  final_flags;

    // Registered PTE address for word selection during response
    // Captures address when request fires, used for selecting correct word from response
    reg [31:0] req_pte_addr_r;

    // =========================================================================
    // VPN Extraction (SV32: 10-bit VPN per level)
    // =========================================================================
    // Virtual Address Layout (SV32):
    //   [31:22] = VPN[1] (Level 1 index, 10 bits)
    //   [21:12] = VPN[0] (Level 0 index, 10 bits)
    //   [11:0]  = Page offset (12 bits)

    wire [VPN_LEVEL_BITS-1:0] vpn1 = pending_vaddr[31:22];  // Level 1 index
    wire [VPN_LEVEL_BITS-1:0] vpn0 = pending_vaddr[21:12];  // Level 0 index

    // =========================================================================
    // PTE Address Calculation
    // =========================================================================
    // Formula: pte_addr = (base_ppn << PAGE_OFFSET_BITS) + (vpn << PTE_SHIFT)
    //   - base_ppn << 12 gives base address of page table
    //   - vpn << 2 gives offset (each PTE is 4 bytes)

    // Level 1 PTE address: use SATP.ppn as base
    wire [31:0] l1_pte_addr = {satp[PPN_WIDTH-1:0], {PAGE_OFFSET_BITS{1'b0}}} +
                              {{(32-VPN_LEVEL_BITS-PTE_SHIFT){1'b0}}, vpn1, {PTE_SHIFT{1'b0}}};

    // Level 0 PTE address: use L1 result ppn as base
    wire [31:0] l0_pte_addr = {l1_ppn, {PAGE_OFFSET_BITS{1'b0}}} +
                              {{(32-VPN_LEVEL_BITS-PTE_SHIFT){1'b0}}, vpn0, {PTE_SHIFT{1'b0}}};

    // =========================================================================
    // PTE Response Parsing
    // =========================================================================
    // PTE Format (SV32, 32-bit):
    //   [31:10] = PPN (22 bits, but we use only 20 bits for 32-bit PA)
    //   [9:8]   = RSW (reserved for software)
    //   [7:0]   = Flags (D,A,G,U,X,W,R,V)

    // Extract 32-bit PTE from potentially wider cache response
    // DATA_WIDTH could be 128 bits (16 bytes) while PTE is only 32 bits (4 bytes)
    // DATA_WIDTH is already defined in Local Parameters section
    localparam NUM_WORDS  = DATA_SIZE / 4;  // Number of 32-bit words in response
    localparam SEL_BITS   = `CLOG2(NUM_WORDS);  // Bits needed to select word

    wire [DATA_WIDTH-1:0] rsp_data_full = ptw_mem_if.rsp_data.data;

    // Select the correct 32-bit word based on address bits
    // Use registered address (req_pte_addr_r) to select word during response
    // This avoids timing issue where pte_addr changes before response arrives
    wire [31:0] pte_data;
    if (NUM_WORDS > 1) begin : g_pte_select
        wire [SEL_BITS-1:0] word_sel = req_pte_addr_r[SEL_BITS+1:2];
        assign pte_data = rsp_data_full[word_sel * 32 +: 32];
    end else begin : g_pte_direct
        assign pte_data = rsp_data_full[31:0];
    end

    wire [PPN_WIDTH-1:0] pte_ppn = pte_data[29:10];  // Use bits [29:10] for 20-bit PPN
    wire [7:0]  pte_flags = pte_data[7:0];

    // PTE validity checks
    wire pte_valid = pte_flags[0];                          // V bit
    wire pte_invalid_combo = ~pte_flags[1] & pte_flags[2];  // R=0, W=1 is invalid
    wire pte_is_leaf = pte_flags[1] | pte_flags[2] | pte_flags[3];  // R|W|X != 0

    // =========================================================================
    // State Machine
    // =========================================================================

    // Memory interface handshake signals
    wire mem_req_fire = ptw_mem_if.req_valid && ptw_mem_if.req_ready;
    wire mem_rsp_fire = ptw_mem_if.rsp_valid && ptw_mem_if.rsp_ready;

    // Sequential logic for state and registers
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= PTW_IDLE;
            pending_vaddr <= 32'b0;
            l1_ppn <= 20'b0;
            final_ppn <= 20'b0;
            final_flags <= 8'b0;
            req_pte_addr_r <= 32'b0;
        end else begin
            state <= state_next;

            case (state)
                PTW_IDLE: begin
                    // Capture miss virtual address on handshake
                    if (miss_valid && miss_ready) begin
                        pending_vaddr <= miss_vaddr;
                    end
                end

                PTW_L1_REQ: begin
                    // Capture L1 PTE address when request fires
                    if (mem_req_fire) begin
                        req_pte_addr_r <= l1_pte_addr;
                    end
                end

                PTW_L0_REQ: begin
                    // Capture L0 PTE address when request fires
                    if (mem_req_fire) begin
                        req_pte_addr_r <= l0_pte_addr;
                    end
                end

                PTW_L1_RESP: begin
                    // Capture Level 1 PTE result on memory response
                    if (mem_rsp_fire) begin
                        l1_ppn <= pte_ppn;
                    end
                end

                PTW_L0_RESP: begin
                    // Capture Level 0 PTE result (final translation)
                    if (mem_rsp_fire) begin
                        final_ppn <= pte_ppn;
                        final_flags <= pte_flags;
                    end
                end

                default: ;
            endcase
        end
    end

    // Combinational logic for next state
    always_comb begin
        state_next = state;

        case (state)
            PTW_IDLE: begin
                // Wait for TLB miss, then start Level 1 walk
                if (miss_valid && miss_ready) begin
                    state_next = PTW_L1_REQ;
                end
            end

            PTW_L1_REQ: begin
                // Send Level 1 PTE request, wait for handshake
                if (mem_req_fire) begin
                    state_next = PTW_L1_RESP;
                end
            end

            PTW_L1_RESP: begin
                // Wait for Level 1 response
                if (mem_rsp_fire) begin
                    // TODO: Check pte_valid and pte_is_leaf for megapages
                    // For now: assume non-leaf, proceed to Level 0
                    state_next = PTW_L0_REQ;
                end
            end

            PTW_L0_REQ: begin
                // Send Level 0 PTE request, wait for handshake
                if (mem_req_fire) begin
                    state_next = PTW_L0_RESP;
                end
            end

            PTW_L0_RESP: begin
                // Wait for Level 0 response (must be leaf)
                if (mem_rsp_fire) begin
                    // TODO: Check pte_valid for page fault
                    // For now: assume valid, proceed to fill
                    state_next = PTW_FILL;
                end
            end

            PTW_FILL: begin
                // Send translation to TLB
                if (fill_valid && fill_ready) begin
                    state_next = PTW_IDLE;
                end
            end

            default: state_next = PTW_IDLE;
        endcase
    end

    // =========================================================================
    // TLB Miss Interface
    // =========================================================================

    // Accept miss requests when idle
    assign miss_ready = (state == PTW_IDLE);

    // =========================================================================
    // TLB Fill Interface
    // =========================================================================

    // Provide fill response with translation from page table walk
    assign fill_valid = (state == PTW_FILL);
    assign fill_vaddr = pending_vaddr;
    assign fill_paddr = {final_ppn, pending_vaddr[PAGE_OFFSET_BITS-1:0]};  // {PPN, page offset}
    assign fill_flags = final_flags;

    // =========================================================================
    // Memory Interface (PTE Read Requests)
    // =========================================================================

    // Select PTE address based on state
    wire [31:0] pte_addr = (state == PTW_L1_REQ) ? l1_pte_addr : l0_pte_addr;

    // Convert 32-bit byte address to word address for memory interface
    // Word address = byte address >> log2(DATA_SIZE)
    localparam ADDR_SHIFT = `CLOG2(DATA_SIZE);
    wire [ADDR_WIDTH-1:0] pte_word_addr = pte_addr[31:ADDR_SHIFT];

    // Request valid in L1_REQ or L0_REQ states
    assign ptw_mem_if.req_valid = (state == PTW_L1_REQ) || (state == PTW_L0_REQ);

    // Build request data
    assign ptw_mem_if.req_data.rw = 1'b0;           // Read operation
    assign ptw_mem_if.req_data.addr = pte_word_addr;
    assign ptw_mem_if.req_data.data = '0;           // Not used for reads
    assign ptw_mem_if.req_data.byteen = {DATA_SIZE{1'b1}};  // All bytes valid
    assign ptw_mem_if.req_data.flags = '0;          // No special flags
    assign ptw_mem_if.req_data.tag = '0;            // No tag needed for PTW

    // Always ready to accept responses in RESP states
    assign ptw_mem_if.rsp_ready = (state == PTW_L1_RESP) || (state == PTW_L0_RESP);

    // =========================================================================
    // Section: PTW Performance Counters
    // =========================================================================
`ifdef PERF_ENABLE
    reg [PERF_CTR_BITS-1:0] perf_ptw_latency_r;

    // PTW is active when NOT in IDLE state
    wire ptw_active = (state != PTW_IDLE);

    always @(posedge clk) begin
        if (reset) begin
            perf_ptw_latency_r <= '0;
        end else begin
            // Count every cycle the PTW is active (walking page tables)
            if (ptw_active) begin
                perf_ptw_latency_r <= perf_ptw_latency_r + PERF_CTR_BITS'(1);
            end
        end
    end

    assign perf_ptw_latency = perf_ptw_latency_r;
`else
    assign perf_ptw_latency_placeholder = 1'b0;
`endif

endmodule
