// ============================================================================
// Copyright (c) 2025 Passionate0424
// 
// GitHub: https://github.com/Passionate0424/CLAHE_verilog
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// ============================================================================

// ============================================================================
// CLAHE Banked RAM Module (4-Bank Interleaved)
//
// Function:
//   - Implements 4 physical memory banks to store 64 logical tiles.
//   - Uses Checkerboard Interleaving to allow conflict-free parallel access
//     to 2x2 neighbor windows.
//   - Provides Crossbar logic to route data to TL/TR/BL/BR ports.
//
// Optimization (Port Folding):
//   - Explicitly schedules ports to avoid 3-port conflicts (LUT inference).
//   - Active Set: Port A = Write, Port B = Read (Hist/CDF).
//   - Inactive Set: Port A = Idle, Port B = Read (Mapping).
//
// Optimization (Timing Fix - 2025-12-07):
//   - Added pipeline registers (mapping_xx_tile_idx_d1) to align Crossbar
//     mux control with RAM read latency (1 cycle).
//
// Optimization (Safety Refactor - 2025-12-07):
//   - Replaced get_bank_id function calls in Mux with explicit bit checks
//     to prevent tool misinterpretation or edge case failures.
//
// Author: Antigravity
// Date: 2025-12-07 (Optimized + Fixed + Refactored)
// ============================================================================

`timescale 1ns / 1ps

module clahe_ram_banked #(
        parameter TILE_H_BITS = 3,       // Horizontal tile count bits (3 for 8)
        parameter TILE_V_BITS = 3,       // Vertical tile count bits (3 for 8)
        parameter TILE_NUM_BITS = 6,     // Total tile index bits (6 for 64)
        parameter BINS = 256,
        parameter DEPTH_PER_BANK = 4096  // Default for 8x8: 16 tiles/bank * 256 bins
    )(
        input  wire        pclk,
        input  wire        rst_n,

        // Ping-Pong Control
        input  wire        ping_pong_flag,
        input  wire        clear_start,
        output reg         clear_done,

        // Histogram Statistic Interface
        input  wire [TILE_NUM_BITS-1:0]  hist_rd_tile_idx,
        input  wire [TILE_NUM_BITS-1:0]  hist_wr_tile_idx,
        input  wire [7:0]   hist_wr_addr,
        input  wire [15:0]  hist_wr_data,
        input  wire         hist_wr_en,
        input  wire [7:0]   hist_rd_addr,
        output reg  [15:0]  hist_rd_data,

        // CDF Calculation Interface
        input  wire [TILE_NUM_BITS-1:0]  cdf_tile_idx,
        input  wire [7:0]   cdf_addr,
        input  wire [7:0]   cdf_wr_data,
        input  wire         cdf_wr_en,
        input  wire         cdf_rd_en,
        output reg  [15:0]  cdf_rd_data,

        // Mapping Interface
        input  wire [TILE_NUM_BITS-1:0]  mapping_tl_tile_idx,
        input  wire [TILE_NUM_BITS-1:0]  mapping_tr_tile_idx,
        input  wire [TILE_NUM_BITS-1:0]  mapping_bl_tile_idx,
        input  wire [TILE_NUM_BITS-1:0]  mapping_br_tile_idx,
        input  wire [7:0]   mapping_addr,
        output reg  [7:0]   mapping_tl_rd_data,
        output reg  [7:0]   mapping_tr_rd_data,
        output reg  [7:0]   mapping_bl_rd_data,
        output reg  [7:0]   mapping_br_rd_data
    );

    // ========================================================================
    // Internal Signals & Types
    // ========================================================================

    // RAM Clear Logic
    reg [12:0] clear_cnt;
    reg        clearing;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            clearing <= 1'b1;   // Auto-clear on reset to prevent X
            clear_done <= 1'b0; // Busy
            clear_cnt <= 13'd0;
        end
        else begin
            if (clear_start) begin
                clearing <= 1'b1;
                clear_done <= 1'b0;
                clear_cnt <= 13'd0;
            end
            else if (clearing) begin
                if (clear_cnt == 13'd4095) begin
                    clearing <= 1'b0;
                    clear_done <= 1'b1;
                end
                else begin
                    clear_cnt <= clear_cnt + 1;
                end
            end
        end
    end

    // Address decoding function
    function [1:0] get_bank_id;
        input [TILE_NUM_BITS-1:0] idx;
        reg [TILE_H_BITS-1:0] tx;
        reg [TILE_V_BITS-1:0] ty;
        begin
            tx = idx[TILE_H_BITS-1:0];
            ty = idx[TILE_NUM_BITS-1:TILE_H_BITS];
            get_bank_id = {ty[0], tx[0]}; // Bank ID = {OddY, OddX}
        end
    endfunction

    function [11:0] get_bank_addr;
        input [TILE_NUM_BITS-1:0] idx;
        input [7:0] bin_addr;
        reg [TILE_H_BITS-1:0] tx;
        reg [TILE_V_BITS-1:0] ty;
        reg [TILE_H_BITS-2:0] inner_tx; // tx >> 1
        reg [TILE_V_BITS-2:0] inner_ty; // ty >> 1
        begin
            tx = idx[TILE_H_BITS-1:0];
            ty = idx[TILE_NUM_BITS-1:TILE_H_BITS];
            inner_tx = tx[TILE_H_BITS-1:1];
            inner_ty = ty[TILE_V_BITS-1:1];
            get_bank_addr = {inner_ty, inner_tx, bin_addr};
        end
    endfunction

    // ========================================================================
    // RAM Instantiation & Port Folding
    // ========================================================================

    // Mapping Addresses (Pre-calculated for Port Folding)

    // Helper: Identify Bank ID from Tile Index bits directly
    // Bank ID = {OddY, OddX} -> {Bit 3, Bit 0} for 8x8 tiling
    wire [1:0] bank_id_tl = {mapping_tl_tile_idx[3], mapping_tl_tile_idx[0]};
    wire [1:0] bank_id_tr = {mapping_tr_tile_idx[3], mapping_tr_tile_idx[0]};
    wire [1:0] bank_id_bl = {mapping_bl_tile_idx[3], mapping_bl_tile_idx[0]};
    wire [1:0] bank_id_br = {mapping_br_tile_idx[3], mapping_br_tile_idx[0]};

    // Address Selection Logic:
    // For each Bank (0-3), check if any of the 4 mapping ports (TL/TR/BL/BR)
    // belongs to this bank. If so, select that port's tile index to generate the address.

    wire [11:0] mapping_addr_b0 = get_bank_addr(
             (bank_id_tl == 2'd0) ? mapping_tl_tile_idx :
             (bank_id_tr == 2'd0) ? mapping_tr_tile_idx :
             (bank_id_bl == 2'd0) ? mapping_bl_tile_idx : mapping_br_tile_idx,
             mapping_addr
         );

    wire [11:0] mapping_addr_b1 = get_bank_addr(
             (bank_id_tl == 2'd1) ? mapping_tl_tile_idx :
             (bank_id_tr == 2'd1) ? mapping_tr_tile_idx :
             (bank_id_bl == 2'd1) ? mapping_bl_tile_idx : mapping_br_tile_idx,
             mapping_addr
         );

    wire [11:0] mapping_addr_b2 = get_bank_addr(
             (bank_id_tl == 2'd2) ? mapping_tl_tile_idx :
             (bank_id_tr == 2'd2) ? mapping_tr_tile_idx :
             (bank_id_bl == 2'd2) ? mapping_bl_tile_idx : mapping_br_tile_idx,
             mapping_addr
         );

    wire [11:0] mapping_addr_b3 = get_bank_addr(
             (bank_id_tl == 2'd3) ? mapping_tl_tile_idx :
             (bank_id_tr == 2'd3) ? mapping_tr_tile_idx :
             (bank_id_bl == 2'd3) ? mapping_bl_tile_idx : mapping_br_tile_idx,
             mapping_addr
         );

    // Control Signals for Histogram/CDF (Active Set)

    // DECISION: Decouple Read and Write Address Calculations to prevent conflict.
    // Port A (Write) must use WR signals.
    // Port B (Read) must use RD signals.

    // --- Histogram WRITE Logic ---
    wire [1:0]  curr_hist_wr_bank = {hist_wr_tile_idx[3], hist_wr_tile_idx[0]};
    wire [11:0] curr_hist_wr_addr = get_bank_addr(hist_wr_tile_idx, hist_wr_addr);

    // --- Histogram READ Logic ---
    wire [1:0]  curr_hist_rd_bank = {hist_rd_tile_idx[3], hist_rd_tile_idx[0]};
    wire [11:0] curr_hist_rd_addr = get_bank_addr(hist_rd_tile_idx, hist_rd_addr);

    // --- CDF Logic (Shared for RD/WR but rarely simultaneous in same way) ---
    // Actually CDF Write and Read happen in different phases or controlled carefully.
    // But for safety let's define them clearly too if needed.
    // Current design uses cdf_tile_idx for both which implies single thread access or shared index.
    // Let's keep shared cdf bank/addr for now as cdf_tile_idx is single input.

    wire [1:0]  curr_cdf_bank  = {cdf_tile_idx[3], cdf_tile_idx[0]};
    wire [11:0] curr_cdf_addr  = get_bank_addr(cdf_tile_idx, cdf_addr);

    // RAM Arrays (Set[0..1], Bank[0..3])
    wire [15:0] ram_dout [0:1][0:3];
    wire [15:0] ram_din_a [0:1][0:3];
    wire [11:0] ram_addr_a [0:1][0:3];
    wire [11:0] ram_addr_b [0:1][0:3];
    wire        ram_we_a [0:1][0:3];

    genvar s, b;
    generate
        for (s = 0; s < 2; s = s + 1) begin : gen_set
            for (b = 0; b < 4; b = b + 1) begin : gen_bank

                // Logic: Is this Set Active? (PingPong == Set ID)
                // Active Set: Port A (Write Hist/CDF/Clear), Port B (Read Hist/CDF)
                // Inactive Set: Port A (Idle), Port B (Read Mapping)

                wire is_active_set = (ping_pong_flag == s); // 1-bit boolean

                // Target Check (Write Port)
                wire is_hist_wr_target = (curr_hist_wr_bank == b[1:0]); // Use WR Bank
                wire is_cdf_target     = (curr_cdf_bank == b[1:0]);

                // --- Port A (Write Port) ---
                assign ram_we_a[s][b] = is_active_set ? (
                           (clearing) ? 1'b1 :
                           (cdf_wr_en && is_cdf_target) ? 1'b1 :
                           (hist_wr_en && is_hist_wr_target) ? 1'b1 : 1'b0
                       ) : 1'b0;

                assign ram_addr_a[s][b] = is_active_set ? (
                           (clearing) ? clear_cnt[11:0] :
                           (cdf_wr_en && is_cdf_target) ? curr_cdf_addr :
                           (hist_wr_en && is_hist_wr_target) ? curr_hist_wr_addr : 12'd0
                       ) : 12'd0;

                assign ram_din_a[s][b] = is_active_set ? (
                           (clearing) ? 16'd0 :
                           (cdf_wr_en && is_cdf_target) ? {8'd0, cdf_wr_data} :
                           (hist_wr_en && is_hist_wr_target) ? hist_wr_data : 16'd0
                       ) : 16'd0;

                // --- Port B (Read Port) ---
                // In Active Mode: Read CDF (Priority) or Hist
                // In Inactive Mode: Read Mapping (From pre-calculated wire)
                wire [11:0] my_mapping_addr = (b==0)? mapping_addr_b0 :
                     (b==1)? mapping_addr_b1 :
                     (b==2)? mapping_addr_b2 : mapping_addr_b3;

                assign ram_addr_b[s][b] = is_active_set ? (
                           (cdf_rd_en) ? curr_cdf_addr : curr_hist_rd_addr  // Use RD Addr
                       ) : my_mapping_addr;

                // Instance
                clahe_simple_dual_ram_model #(
                                                .DATA_WIDTH(16),
                                                .ADDR_WIDTH(12),
                                                .DEPTH(4096)
                                            ) u_ram (
                                                .clk_a(pclk),
                                                .we_a(ram_we_a[s][b]),
                                                .addr_a(ram_addr_a[s][b]),
                                                .din_a(ram_din_a[s][b]),
                                                .clk_b(pclk),
                                                .addr_b(ram_addr_b[s][b]),
                                                .dout_b(ram_dout[s][b])
                                            );
            end
        end
    endgenerate

    // ========================================================================
    // Read Data Crossbar / Output Muxing
    // ========================================================================

    // 1. Hist Read Data (From Active Set, Active Bank)
    // Active Set is determined by ~ping_pong_flag (Wait, ping_pong=0 -> Set 0 Active)
    // Correct.

    wire [15:0] hist_rd_data_raw = (ping_pong_flag == 0) ?
         ram_dout[0][curr_hist_rd_bank] : ram_dout[1][curr_hist_rd_bank];

    // 2. CDF Read Data (From Active Set, Active Bank)
    wire [15:0] cdf_rd_data_raw = (ping_pong_flag == 0) ?
         ram_dout[0][curr_cdf_bank] : ram_dout[1][curr_cdf_bank];

    // FIX: Remove output register to effectively have 1-cycle latency (Standard BRAM)
    // The previous `always @(posedge pclk)` block added a second cycle of latency.

    always @(*) begin
        hist_rd_data = hist_rd_data_raw;
        cdf_rd_data  = cdf_rd_data_raw;
    end

    // 3. Mapping Read Data (From Inactive Set)
    // Inactive Set is determined by ping_pong_flag (ping_pong=0 -> Set 1 Inactive)
    // So if ping_pong=0, we read from Set 1. If ping_pong=1, we read from Set 0.

    wire inactive_set = (ping_pong_flag == 0) ? 1'b1 : 1'b0;

    // Fix: Pipeline alignment for Crossbar
    // RAM Read Latency = 1 cycle.
    // The Crossbar must use the Bank ID from 1 cycle ago to route the data correctly.
    // Otherwise, when crossing Tile boundaries, we select the NEW bank using OLD bank's data.

    reg [TILE_NUM_BITS-1:0] mapping_tl_tile_idx_d1;
    reg [TILE_NUM_BITS-1:0] mapping_tr_tile_idx_d1;
    reg [TILE_NUM_BITS-1:0] mapping_bl_tile_idx_d1;
    reg [TILE_NUM_BITS-1:0] mapping_br_tile_idx_d1;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            mapping_tl_tile_idx_d1 <= {TILE_NUM_BITS{1'b0}};
            mapping_tr_tile_idx_d1 <= {TILE_NUM_BITS{1'b0}};
            mapping_bl_tile_idx_d1 <= {TILE_NUM_BITS{1'b0}};
            mapping_br_tile_idx_d1 <= {TILE_NUM_BITS{1'b0}};
        end
        else begin
            mapping_tl_tile_idx_d1 <= mapping_tl_tile_idx;
            mapping_tr_tile_idx_d1 <= mapping_tr_tile_idx;
            mapping_bl_tile_idx_d1 <= mapping_bl_tile_idx;
            mapping_br_tile_idx_d1 <= mapping_br_tile_idx;
        end
    end

    // Crossbar for Mapping Ports
    // Each Port needs data from a specific Bank (0-3) of the Inactive Set

    always @(*) begin
        // TL
        case (get_bank_id(mapping_tl_tile_idx_d1)) // Use delayed idx
            2'd0:
                mapping_tl_rd_data = ram_dout[inactive_set][0][7:0];
            2'd1:
                mapping_tl_rd_data = ram_dout[inactive_set][1][7:0];
            2'd2:
                mapping_tl_rd_data = ram_dout[inactive_set][2][7:0];
            2'd3:
                mapping_tl_rd_data = ram_dout[inactive_set][3][7:0];
        endcase

        // TR
        case (get_bank_id(mapping_tr_tile_idx_d1)) // Use delayed idx
            2'd0:
                mapping_tr_rd_data = ram_dout[inactive_set][0][7:0];
            2'd1:
                mapping_tr_rd_data = ram_dout[inactive_set][1][7:0];
            2'd2:
                mapping_tr_rd_data = ram_dout[inactive_set][2][7:0];
            2'd3:
                mapping_tr_rd_data = ram_dout[inactive_set][3][7:0];
        endcase

        // BL
        case (get_bank_id(mapping_bl_tile_idx_d1)) // Use delayed idx
            2'd0:
                mapping_bl_rd_data = ram_dout[inactive_set][0][7:0];
            2'd1:
                mapping_bl_rd_data = ram_dout[inactive_set][1][7:0];
            2'd2:
                mapping_bl_rd_data = ram_dout[inactive_set][2][7:0];
            2'd3:
                mapping_bl_rd_data = ram_dout[inactive_set][3][7:0];
        endcase

        // BR
        case (get_bank_id(mapping_br_tile_idx_d1)) // Use delayed idx
            2'd0:
                mapping_br_rd_data = ram_dout[inactive_set][0][7:0];
            2'd1:
                mapping_br_rd_data = ram_dout[inactive_set][1][7:0];
            2'd2:
                mapping_br_rd_data = ram_dout[inactive_set][2][7:0];
            2'd3:
                mapping_br_rd_data = ram_dout[inactive_set][3][7:0];
        endcase
    end

endmodule
