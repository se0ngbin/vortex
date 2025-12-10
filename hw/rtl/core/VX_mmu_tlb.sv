// Copyright 2024
// TLB Module for Vortex GPU MMU
// Implements serialized TLB lookup with 4-to-1 arbitration and 1-to-4 routing

`include "VX_define.vh"

// TODO: These warnings indicate integration issues with VX_stream_arb/VX_stream_switch
// that need architectural fixes for proper Vortex integration:
// - sel_out/sel_in width mismatches with stream modules
// - Unused signal bits from source encoding
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */

module VX_mmu_tlb import VX_gpu_pkg::*; #(
    parameter NUM_REQS       = DCACHE_NUM_REQS,         // Coalesced requests from VX_mem_unit
    parameter DATA_SIZE      = DCACHE_WORD_SIZE,        // 16 bytes (coalesced line size)
    parameter TAG_WIDTH_IN   = DCACHE_TAG_WIDTH,        // Input tag width
    parameter TAG_WIDTH_OUT  = TAG_WIDTH_IN + `UP(`CLOG2(NUM_REQS)),  // Parameterized source encoding
    parameter ADDR_WIDTH     = DCACHE_ADDR_WIDTH,       // 28 bits for DATA_SIZE=16
    parameter FLAGS_WIDTH    = MEM_FLAGS_WIDTH
) (
    input wire clk,
    input wire reset,

    // Input from elastic buffers (4 ports)
    VX_mem_bus_if.slave  tlb_in_if [NUM_REQS],

    // Output to merge arbiter (4 ports)
    VX_mem_bus_if.master tlb_out_if [NUM_REQS],

    // TLB miss interface to PTW
    output wire          miss_valid,
    input  wire          miss_ready,
    output wire [31:0]   miss_vaddr,

    // TLB fill interface from PTW
    input  wire          fill_valid,
    output wire          fill_ready,
    input  wire [31:0]   fill_vaddr,
    input  wire [31:0]   fill_paddr,
    input  wire [7:0]    fill_flags,

    // Performance counters output
`ifdef PERF_ENABLE
    output mmu_perf_t    mmu_perf
`else
    output wire          mmu_perf_placeholder  // Unused placeholder when PERF disabled
`endif
);

    // =========================================================================
    // Local Parameters
    // =========================================================================

    localparam DATA_WIDTH    = DATA_SIZE * 8;
    localparam REQ_DATAW_IN  = 1 + ADDR_WIDTH + DATA_WIDTH + DATA_SIZE + FLAGS_WIDTH + TAG_WIDTH_IN;
    localparam REQ_DATAW_OUT = 1 + ADDR_WIDTH + DATA_WIDTH + DATA_SIZE + FLAGS_WIDTH + TAG_WIDTH_OUT;
    localparam RSP_DATAW_IN  = DATA_WIDTH + TAG_WIDTH_IN;
    localparam RSP_DATAW_OUT = DATA_WIDTH + TAG_WIDTH_OUT;

    localparam SOURCE_BITS   = `UP(`CLOG2(NUM_REQS));  // Parameterized source encoding

    // =========================================================================
    // Section 1: Request Path - Serialize (4-to-1)
    // =========================================================================

    // Extract request data from input interfaces
    // NOTE: We must extract individual fields from the interface because
    // the packed req_data_t includes tag_t with UUID_WIDTH, which makes
    // the total width larger than our REQ_DATAW_IN calculation assumes.
    wire [NUM_REQS-1:0]                 req_valid_in;
    wire [NUM_REQS-1:0][REQ_DATAW_IN-1:0] req_data_in;
    wire [NUM_REQS-1:0]                 req_ready_in;

    for (genvar i = 0; i < NUM_REQS; i++) begin : g_req_in
        assign req_valid_in[i] = tlb_in_if[i].req_valid;
        // Pack fields manually to avoid UUID_WIDTH mismatch
        assign req_data_in[i]  = {
            tlb_in_if[i].req_data.rw,
            tlb_in_if[i].req_data.addr,
            tlb_in_if[i].req_data.data,
            tlb_in_if[i].req_data.byteen,
            tlb_in_if[i].req_data.flags[FLAGS_WIDTH-1:0],
            tlb_in_if[i].req_data.tag[TAG_WIDTH_IN-1:0]
        };
        assign tlb_in_if[i].req_ready = req_ready_in[i];
    end

    // Arbitrate 4 inputs to 1 output
    wire                      ser_req_valid;
    wire [REQ_DATAW_IN-1:0]   ser_req_data;
    wire [SOURCE_BITS-1:0]    ser_req_sel;
    wire                      ser_req_ready;

    VX_stream_arb #(
        .NUM_INPUTS  (NUM_REQS),
        .NUM_OUTPUTS (1),
        .DATAW       (REQ_DATAW_IN),
        .ARBITER     ("R"),
        .OUT_BUF     (0)
    ) req_serialize_arb (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (req_valid_in),
        .data_in   (req_data_in),
        .ready_in  (req_ready_in),
        .valid_out (ser_req_valid),
        .data_out  (ser_req_data),
        .sel_out   (ser_req_sel),
        .ready_out (ser_req_ready)
    );

    // =========================================================================
    // Section 2: (Tag encoding moved to Section 3 - uses buffered data)
    // =========================================================================

    // =========================================================================
    // Section 3: TLB Logic
    // =========================================================================

    // -------------------------------------------------------------------------
    // TLB Parameters
    // -------------------------------------------------------------------------
    localparam TLB_SIZE       = 32;
    localparam TLB_INDEX_BITS = 5;   // $clog2(TLB_SIZE)

    // -------------------------------------------------------------------------
    // Derived Address Parameters for Virtual Memory
    // -------------------------------------------------------------------------
    // Page offset bits in word address = 12 (byte page offset) - log2(DATA_SIZE)
    localparam PAGE_OFFSET_BITS = 12 - `CLOG2(DATA_SIZE);
    // VPN width is always 20 for SV32 (= ADDR_WIDTH - PAGE_OFFSET_BITS)
    localparam VPN_WIDTH = 20;
    // PPN width matches VPN width
    localparam PPN_WIDTH = VPN_WIDTH;
    // Superpage offset bits: 4MB page has 22-bit byte offset
    localparam SUPERPAGE_OFFSET_BITS = 22 - `CLOG2(DATA_SIZE);

    // -------------------------------------------------------------------------
    // TLB Entry Structure
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic                 valid;       // Entry valid
        logic                 mru;         // Most Recently Used bit (for replacement)
        logic [1:0]           page_level;  // 0=4KB, 1=4MB, 2=full(test)
        logic [VPN_WIDTH-1:0] vpn;         // Virtual Page Number
        logic [PPN_WIDTH-1:0] ppn;         // Physical Page Number
        logic [7:0]           flags;       // RISC-V PTE flags
    } tlb_entry_t;

    tlb_entry_t tlb_entries [TLB_SIZE-1:0];

    // -------------------------------------------------------------------------
    // State Machine (Miss-Buffer Only Design)
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        TLB_IDLE,
        TLB_READY,      // Accept input, combinational lookup, output on hit
        TLB_PTW_WAIT,   // Wait for PTW fill
        TLB_REPLAY      // Output missed request using fill_paddr
    } tlb_state_t;

    tlb_state_t state;

    // Miss-buffer registers (only captures missed requests, not all requests)
    reg [REQ_DATAW_IN-1:0]   miss_buffer;
    reg [SOURCE_BITS-1:0]    miss_sel;
    reg [31:0]               miss_fill_paddr;  // Captured from PTW fill

    // Miss handling registers
    reg miss_sent;                           // PTW acknowledged miss request
    reg [TLB_INDEX_BITS-1:0] victim_index;   // Selected victim for replacement

    // -------------------------------------------------------------------------
    // Address Extraction (Mux between live data and miss_buffer)
    // -------------------------------------------------------------------------
    // Bit layout of data (REQ_DATAW_IN = 100 bits):
    //   [99]      = rw
    //   [98:69]   = addr (30 bits)
    //   [68:37]   = data (32 bits)
    //   [36:33]   = byteen (4 bits)
    //   [32]      = flags (1 bit)
    //   [31:0]    = tag (32 bits)

    localparam ADDR_LSB_IN = TAG_WIDTH_IN + FLAGS_WIDTH + DATA_SIZE + DATA_WIDTH;  // = 69
    localparam ADDR_LSB = TAG_WIDTH_OUT + FLAGS_WIDTH + DATA_SIZE + DATA_WIDTH;     // = 71 (for output)

    // Select data source: live arbiter data (READY) or miss_buffer (REPLAY)
    wire use_miss_buffer = (state == TLB_REPLAY);
    wire [REQ_DATAW_IN-1:0] lookup_data = use_miss_buffer ? miss_buffer : ser_req_data;
    wire [SOURCE_BITS-1:0]  lookup_sel  = use_miss_buffer ? miss_sel : ser_req_sel;

    // Extract address from selected source
    wire [ADDR_WIDTH-1:0] lookup_addr = lookup_data[ADDR_LSB_IN +: ADDR_WIDTH];

    // VPN = addr[ADDR_WIDTH-1:PAGE_OFFSET_BITS] for 4KB page
    wire [VPN_WIDTH-1:0] lookup_vpn = lookup_addr[ADDR_WIDTH-1:PAGE_OFFSET_BITS];

    // Extract original tag from selected data for encoding
    wire [TAG_WIDTH_IN-1:0] lookup_tag = lookup_data[TAG_WIDTH_IN-1:0];

    // Encode source port into tag
    wire [TAG_WIDTH_OUT-1:0] lookup_tag_encoded;

    VX_bits_insert #(
        .N   (TAG_WIDTH_IN),
        .S   (SOURCE_BITS),
        .POS (0)  // Insert at LSB
    ) tag_encode (
        .data_in  (lookup_tag),
        .ins_in   (lookup_sel),
        .data_out (lookup_tag_encoded)
    );

    // Build encoded request data (replace tag portion)
    wire [REQ_DATAW_OUT-1:0] lookup_data_encoded = {
        lookup_data[REQ_DATAW_IN-1:TAG_WIDTH_IN],  // Non-tag fields
        lookup_tag_encoded                          // Encoded tag
    };

    // -------------------------------------------------------------------------
    // CAM Lookup with Superpage Masking
    // -------------------------------------------------------------------------
    function automatic [VPN_WIDTH-1:0] vpn_mask(input [1:0] level);
        case (level)
            2'd0:    vpn_mask = 20'hFFFFF;  // 4KB: all 20 bits
            2'd1:    vpn_mask = 20'hFFC00;  // 4MB: top 10 bits
            2'd2:    vpn_mask = 20'h00000;  // Full space: match any (test mode)
            default: vpn_mask = 20'hFFFFF;
        endcase
    endfunction

    // Parallel CAM comparison for all 32 entries
    wire [TLB_SIZE-1:0] cam_hit;
    for (genvar i = 0; i < TLB_SIZE; i++) begin : g_cam
        wire [VPN_WIDTH-1:0] mask_i = vpn_mask(tlb_entries[i].page_level);
        assign cam_hit[i] = tlb_entries[i].valid &&
                            ((tlb_entries[i].vpn & mask_i) == (lookup_vpn & mask_i));
    end

    // Overall hit detection
    wire tlb_hit = |cam_hit;

    // Find first matching entry index (priority encoder)
    reg [TLB_INDEX_BITS-1:0] hit_index;
    always_comb begin
        hit_index = '0;
        for (int j = TLB_SIZE-1; j >= 0; j--) begin
            if (cam_hit[j]) begin
                hit_index = j[TLB_INDEX_BITS-1:0];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Victim Selection for Replacement (MRU-based)
    // -------------------------------------------------------------------------
    // Priority: First invalid entry, then first non-MRU entry
    reg [TLB_INDEX_BITS-1:0] victim_candidate;
    reg found_invalid;  // Flag to track if invalid entry was found
    wire all_mru;  // All entries have MRU set

    always_comb begin
        victim_candidate = '0;
        found_invalid = 1'b0;

        // First try to find an invalid entry
        for (int j = TLB_SIZE-1; j >= 0; j--) begin
            if (!tlb_entries[j].valid) begin
                victim_candidate = j[TLB_INDEX_BITS-1:0];
                found_invalid = 1'b1;
            end
        end

        // Only if all entries are valid, find first non-MRU entry
        if (!found_invalid) begin
            for (int j = TLB_SIZE-1; j >= 0; j--) begin
                if (tlb_entries[j].valid && !tlb_entries[j].mru) begin
                    victim_candidate = j[TLB_INDEX_BITS-1:0];
                end
            end
        end
    end

    // Check if all valid entries have MRU=1
    wire [TLB_SIZE-1:0] entry_mru;
    for (genvar i = 0; i < TLB_SIZE; i++) begin : g_mru_check
        assign entry_mru[i] = tlb_entries[i].valid ? tlb_entries[i].mru : 1'b0;
    end
    assign all_mru = &entry_mru;

    // -------------------------------------------------------------------------
    // Address Translation with Superpage Support
    // -------------------------------------------------------------------------
    wire [PPN_WIDTH-1:0] hit_ppn   = tlb_entries[hit_index].ppn;
    wire [1:0]           hit_level = tlb_entries[hit_index].page_level;

    reg [ADDR_WIDTH-1:0] cam_translated_addr;
    always_comb begin
        case (hit_level)
            2'd0:    // 4KB page: paddr = {PPN, page_offset[PAGE_OFFSET_BITS-1:0]}
                cam_translated_addr = {hit_ppn, lookup_addr[PAGE_OFFSET_BITS-1:0]};
            2'd1:    // 4MB page: paddr = {PPN[19:10], vaddr[SUPERPAGE_OFFSET_BITS-1:0]}
                cam_translated_addr = {hit_ppn[VPN_WIDTH-1:10], lookup_addr[SUPERPAGE_OFFSET_BITS-1:0]};
            2'd2:    // Full space (test): passthrough identity mapping
                cam_translated_addr = lookup_addr;
            default:
                cam_translated_addr = {hit_ppn, lookup_addr[PAGE_OFFSET_BITS-1:0]};
        endcase
    end

    // -------------------------------------------------------------------------
    // REPLAY Translation (Bypass CAM - use captured fill_paddr directly)
    // -------------------------------------------------------------------------
    // In REPLAY state, we use the captured fill_paddr from PTW
    // This bypasses CAM lookup for faster replay
    // PPN from fill_paddr (byte address) combined with page offset from word address
    wire [ADDR_WIDTH-1:0] replay_paddr = {miss_fill_paddr[31:12], lookup_addr[PAGE_OFFSET_BITS-1:0]};

    // Select final translated address based on state
    wire [ADDR_WIDTH-1:0] translated_addr = use_miss_buffer ? replay_paddr : cam_translated_addr;

    // -------------------------------------------------------------------------
    // State Machine Logic (Miss-Buffer Only Design)
    // -------------------------------------------------------------------------
    // Flow: READY (combinational hit or capture miss) -> PTW_WAIT -> REPLAY -> READY
    //
    // Key: ready depends on STATE only, hits output combinationally in READY

    // Input handshake detection
    wire input_handshake = ser_req_valid && ser_req_ready;

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= TLB_IDLE;
            miss_buffer <= '0;
            miss_sel <= '0;
            miss_fill_paddr <= '0;
            miss_sent <= 1'b0;
            victim_index <= '0;

            // Initialize ALL TLB entries as invalid on reset
            // PTW fills TLB entries on TLB miss - no hardcoded mappings
            for (int i = 0; i < TLB_SIZE; i++) begin
                tlb_entries[i].valid      <= 1'b0;
                tlb_entries[i].mru        <= 1'b0;
                tlb_entries[i].page_level <= 2'd0;
                tlb_entries[i].vpn        <= '0;
                tlb_entries[i].ppn        <= '0;
                tlb_entries[i].flags      <= '0;
            end
        end else begin
            case (state)
                TLB_IDLE: begin
                    state <= TLB_READY;
                end

                TLB_READY: begin
                    // Combinational lookup on live arbiter data
                    if (input_handshake) begin
                        if (tlb_hit) begin
                            // Hit: output combinationally (same cycle), stay in READY
                            // MRU update
                            tlb_entries[hit_index].mru <= 1'b1;
                            if (all_mru) begin
                                for (int i = 0; i < TLB_SIZE; i++) begin
                                    if (i[TLB_INDEX_BITS-1:0] != hit_index) begin
                                        tlb_entries[i].mru <= 1'b0;
                                    end
                                end
                            end
                            // Stay in TLB_READY
                        end else begin
                            // Miss: capture to miss_buffer, go to PTW_WAIT
                            miss_buffer <= ser_req_data;
                            miss_sel <= ser_req_sel;
                            victim_index <= victim_candidate;
                            state <= TLB_PTW_WAIT;
                        end
                    end
                end

                TLB_PTW_WAIT: begin
                    // Track miss handshake with PTW
                    if (miss_valid && miss_ready) begin
                        miss_sent <= 1'b1;
                    end

                    // Handle fill from PTW
                    if (fill_valid && fill_ready) begin
                        // Capture fill_paddr for replay (bypass CAM)
                        miss_fill_paddr <= fill_paddr;

                        // Update TLB entry with fill data
                        tlb_entries[victim_index].valid      <= 1'b1;
                        tlb_entries[victim_index].mru        <= 1'b1;
                        tlb_entries[victim_index].page_level <= 2'd0;  // 4KB page
                        tlb_entries[victim_index].vpn        <= fill_vaddr[31:12];
                        tlb_entries[victim_index].ppn        <= fill_paddr[31:12];
                        tlb_entries[victim_index].flags      <= fill_flags;

                        // Clear all MRU bits if all were set before this fill
                        if (all_mru) begin
                            for (int i = 0; i < TLB_SIZE; i++) begin
                                if (i[TLB_INDEX_BITS-1:0] != victim_index) begin
                                    tlb_entries[i].mru <= 1'b0;
                                end
                            end
                        end

                        // Go to REPLAY to output the missed request
                        state <= TLB_REPLAY;
                        miss_sent <= 1'b0;
                    end
                end

                TLB_REPLAY: begin
                    // Output miss_buffer translation using captured fill_paddr
                    if (output_handshake) begin
                        state <= TLB_READY;
                    end
                end

                default: state <= TLB_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Control Signals and Output (Miss-Buffer Only Design)
    // -------------------------------------------------------------------------

    // Ready signal: depends on STATE and downstream ready
    // With OUT_BUF=1 on VX_stream_switch, deser_req_ready comes from registered
    // buffer state, breaking the combinational loop while providing proper
    // backpressure propagation from dcache to TLB input.
    assign ser_req_ready = (state == TLB_READY) && deser_req_ready;

    // Output valid:
    // - In READY state: hit in same cycle (combinational) - 0-cycle latency!
    // - In REPLAY state: output missed request with fill_paddr
    wire tlb_out_valid = (state == TLB_READY && input_handshake && tlb_hit) ||
                         (state == TLB_REPLAY);

    // Output handshake: TLB output accepted by downstream
    wire output_handshake = tlb_out_valid && deser_req_ready;

    // Output data: replace address field with translated address
    // Uses lookup_data_encoded (which muxes between live data and miss_buffer)
    wire [REQ_DATAW_OUT-1:0] tlb_out_data = {
        lookup_data_encoded[REQ_DATAW_OUT-1],  // rw (1 bit)
        translated_addr,                         // paddr (30 bits)
        lookup_data_encoded[ADDR_LSB-1:0]       // data,byteen,flags,tag (71 bits)
    };

    // =========================================================================
    // Section 4: Request Path - Deserialize (1-to-4)
    // =========================================================================

    // Extract source port from encoded tag (read-only, don't remove)
    wire [SOURCE_BITS-1:0] deser_req_sel = tlb_out_data[SOURCE_BITS-1:0];

    wire                      deser_req_ready;
    wire [NUM_REQS-1:0]       deser_req_valid_out;
    wire [NUM_REQS-1:0][REQ_DATAW_OUT-1:0] deser_req_data_out;
    wire [NUM_REQS-1:0]       deser_req_ready_out;

    VX_stream_switch #(
        .NUM_INPUTS  (1),
        .NUM_OUTPUTS (NUM_REQS),
        .DATAW       (REQ_DATAW_OUT),
        .OUT_BUF     (1)  // Use elastic buffer to break combinational loop and enable backpressure
    ) req_deserialize_switch (
        .clk       (clk),
        .reset     (reset),
        .sel_in    (deser_req_sel),
        .valid_in  (tlb_out_valid),
        .data_in   (tlb_out_data),
        .ready_in  (deser_req_ready),
        .valid_out (deser_req_valid_out),
        .data_out  (deser_req_data_out),
        .ready_out (deser_req_ready_out)
    );

    // Connect to output interfaces (request path)
    // Unpack fields to interface struct fields to avoid UUID_WIDTH mismatch
    for (genvar i = 0; i < NUM_REQS; i++) begin : g_req_out
        assign tlb_out_if[i].req_valid = deser_req_valid_out[i];
        // Unpack the packed data to individual struct fields
        assign tlb_out_if[i].req_data.rw     = deser_req_data_out[i][REQ_DATAW_OUT-1];
        assign tlb_out_if[i].req_data.addr   = deser_req_data_out[i][REQ_DATAW_OUT-2 -: ADDR_WIDTH];
        assign tlb_out_if[i].req_data.data   = deser_req_data_out[i][REQ_DATAW_OUT-2-ADDR_WIDTH -: DATA_WIDTH];
        assign tlb_out_if[i].req_data.byteen = deser_req_data_out[i][REQ_DATAW_OUT-2-ADDR_WIDTH-DATA_WIDTH -: DATA_SIZE];
        assign tlb_out_if[i].req_data.flags  = deser_req_data_out[i][REQ_DATAW_OUT-2-ADDR_WIDTH-DATA_WIDTH-DATA_SIZE -: FLAGS_WIDTH];
        assign tlb_out_if[i].req_data.tag    = deser_req_data_out[i][TAG_WIDTH_OUT-1:0];
        assign deser_req_ready_out[i]  = tlb_out_if[i].req_ready;
    end

    // =========================================================================
    // Section 5: Response Path - Serialize (4-to-1)
    // =========================================================================

    // Extract response data from output interfaces
    // Pack fields manually to avoid UUID_WIDTH mismatch
    wire [NUM_REQS-1:0]                  rsp_valid_in;
    wire [NUM_REQS-1:0][RSP_DATAW_OUT-1:0] rsp_data_in;
    wire [NUM_REQS-1:0]                  rsp_ready_in;

    for (genvar i = 0; i < NUM_REQS; i++) begin : g_rsp_in
        assign rsp_valid_in[i] = tlb_out_if[i].rsp_valid;
        // Pack fields manually
        assign rsp_data_in[i]  = {
            tlb_out_if[i].rsp_data.data,
            tlb_out_if[i].rsp_data.tag[TAG_WIDTH_OUT-1:0]
        };
        assign tlb_out_if[i].rsp_ready = rsp_ready_in[i];
    end

    // Arbitrate 4 responses to 1 (tag preserved, contains source)
    wire                      ser_rsp_valid;
    wire [RSP_DATAW_OUT-1:0]  ser_rsp_data;
    wire                      ser_rsp_ready;

    VX_stream_arb #(
        .NUM_INPUTS  (NUM_REQS),
        .NUM_OUTPUTS (1),
        .DATAW       (RSP_DATAW_OUT),
        .ARBITER     ("R"),
        .OUT_BUF     (0)
    ) rsp_serialize_arb (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (rsp_valid_in),
        .data_in   (rsp_data_in),
        .ready_in  (rsp_ready_in),
        .valid_out (ser_rsp_valid),
        .data_out  (ser_rsp_data),
        `UNUSED_PIN (sel_out),
        .ready_out (ser_rsp_ready)
    );

    // =========================================================================
    // Section 6: Response Path - Tag Decoding & Deserialize (1-to-4)
    // =========================================================================

    // Extract source port and restore original tag
    wire [TAG_WIDTH_OUT-1:0] ser_rsp_tag = ser_rsp_data[TAG_WIDTH_OUT-1:0];
    wire [SOURCE_BITS-1:0]   rsp_source;
    wire [TAG_WIDTH_IN-1:0]  rsp_tag_restored;

    VX_bits_remove #(
        .N   (TAG_WIDTH_OUT),
        .S   (SOURCE_BITS),
        .POS (0)  // Remove from LSB
    ) rsp_tag_decode (
        .data_in  (ser_rsp_tag),
        .sel_out  (rsp_source),
        .data_out (rsp_tag_restored)
    );

    // Build restored response data
    wire [RSP_DATAW_IN-1:0] ser_rsp_data_restored = {
        ser_rsp_data[RSP_DATAW_OUT-1:TAG_WIDTH_OUT],  // Non-tag fields (data)
        rsp_tag_restored                               // Restored original tag
    };

    // Route response to correct input port
    wire                     deser_rsp_ready;
    wire [NUM_REQS-1:0]      deser_rsp_valid_out;
    wire [NUM_REQS-1:0][RSP_DATAW_IN-1:0] deser_rsp_data_out;
    wire [NUM_REQS-1:0]      deser_rsp_ready_out;

    VX_stream_switch #(
        .NUM_INPUTS  (1),
        .NUM_OUTPUTS (NUM_REQS),
        .DATAW       (RSP_DATAW_IN),
        .OUT_BUF     (0)
    ) rsp_deserialize_switch (
        .clk       (clk),
        .reset     (reset),
        .sel_in    (rsp_source),
        .valid_in  (ser_rsp_valid),
        .data_in   (ser_rsp_data_restored),
        .ready_in  (deser_rsp_ready),
        .valid_out (deser_rsp_valid_out),
        .data_out  (deser_rsp_data_out),
        .ready_out (deser_rsp_ready_out)
    );

    assign ser_rsp_ready = deser_rsp_ready;

    // Connect to input interfaces (response path)
    // Unpack fields to interface struct fields to avoid UUID_WIDTH mismatch
    for (genvar i = 0; i < NUM_REQS; i++) begin : g_rsp_out
        assign tlb_in_if[i].rsp_valid = deser_rsp_valid_out[i];
        // Unpack the packed data to individual struct fields
        assign tlb_in_if[i].rsp_data.data = deser_rsp_data_out[i][RSP_DATAW_IN-1 -: DATA_WIDTH];
        assign tlb_in_if[i].rsp_data.tag  = deser_rsp_data_out[i][TAG_WIDTH_IN-1:0];
        assign deser_rsp_ready_out[i] = tlb_in_if[i].rsp_ready;
    end

    // =========================================================================
    // Section 7: Miss/Fill Interface
    // =========================================================================

    // Extract VPN from miss_buffer (miss_buffer is only valid in PTW_WAIT and REPLAY states)
    wire [ADDR_WIDTH-1:0] miss_buffer_addr = miss_buffer[ADDR_LSB_IN +: ADDR_WIDTH];
    wire [VPN_WIDTH-1:0] miss_buffer_vpn = miss_buffer_addr[ADDR_WIDTH-1:PAGE_OFFSET_BITS];

    // Miss interface to PTW - uses miss_buffer data (captured on TLB miss)
    // Only assert miss_valid when in PTW_WAIT and haven't sent yet
    assign miss_valid = (state == TLB_PTW_WAIT) && !miss_sent;
    assign miss_vaddr = {miss_buffer_vpn, 12'b0};  // Convert miss_buffer VPN to byte address

    // Fill interface from PTW - ready to receive after PTW acknowledged miss
    assign fill_ready = (state == TLB_PTW_WAIT) && miss_sent;

    // =========================================================================
    // Section 8: TLB Performance Counters
    // =========================================================================
`ifdef PERF_ENABLE
    reg [PERF_CTR_BITS-1:0] perf_tlb_reads;
    reg [PERF_CTR_BITS-1:0] perf_tlb_hits;
    reg [PERF_CTR_BITS-1:0] perf_tlb_misses;
    reg [PERF_CTR_BITS-1:0] perf_tlb_evictions;

    // Track if victim entry was valid before fill (for eviction counting)
    wire victim_was_valid = tlb_entries[victim_index].valid;

    always @(posedge clk) begin
        if (reset) begin
            perf_tlb_reads     <= '0;
            perf_tlb_hits      <= '0;
            perf_tlb_misses    <= '0;
            perf_tlb_evictions <= '0;
        end else begin
            // Count TLB reads: when a valid lookup request is accepted in READY state
            if (state == TLB_READY && input_handshake) begin
                perf_tlb_reads <= perf_tlb_reads + PERF_CTR_BITS'(1);
            end

            // Count TLB hits: when lookup completes with a hit in READY state
            if (state == TLB_READY && input_handshake && tlb_hit) begin
                perf_tlb_hits <= perf_tlb_hits + PERF_CTR_BITS'(1);
            end

            // Count TLB misses: when miss triggers PTW (miss handshake)
            if (miss_valid && miss_ready) begin
                perf_tlb_misses <= perf_tlb_misses + PERF_CTR_BITS'(1);
            end

            // Count evictions: when filling an already-valid entry
            if (fill_valid && fill_ready && victim_was_valid) begin
                perf_tlb_evictions <= perf_tlb_evictions + PERF_CTR_BITS'(1);
            end
        end
    end

    // Output assignment
    assign mmu_perf.tlb_reads     = perf_tlb_reads;
    assign mmu_perf.tlb_hits      = perf_tlb_hits;
    assign mmu_perf.tlb_misses    = perf_tlb_misses;
    assign mmu_perf.tlb_evictions = perf_tlb_evictions;
    assign mmu_perf.ptw_walks     = perf_tlb_misses;  // PTW walks = misses
    assign mmu_perf.ptw_latency   = '0;  // PTW latency is measured in VX_mmu_ptw, not TLB
`else
    assign mmu_perf_placeholder = 1'b0;
`endif

endmodule
