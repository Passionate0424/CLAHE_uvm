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
// CLAHE 直方图统计模块 - 简化重构版 (+ S2/S3 Forwarding Fix)
//
// 设计思路：
//   1. 使用 Forwarding 技术解决 Read-Modify-Write 流水线冲突
//   2. 冲突检测范围扩大：不仅检测 S1 vs S3，还检测 S2 vs S3
//   3. 移除不必要的 "Same As Prev" 优化，完全依靠 Forwarding 保证正确性
//
// 流水线结构：
//   Stage 1: 输入打拍
//   Stage 2: RAM读取 (Data from RAM or Forwarded from S3)
//   Stage 3: RAM写入 (Base + 1)
//
// 冲突处理：
//   - A1 writes at T3.
//   - A2 matches A1. A2 is at Stage 2 when A1 is at Stage 3.
//   - A2 detects Conflict (S2==S3). Forwards A1's Write Data to S2's Base.
//   - A2 writes (Base+1).
//
// try 4
// 作者: Passionate.Z
// 日期: 2025-12-07
// ============================================================================

`timescale 1ns / 1ps

module clahe_histogram_stat #(
        parameter TILE_NUM_BITS = 6
    )(
        input  wire        pclk,
        input  wire        rst_n,

        // 输入接口
        input  wire [7:0]  in_y,           // 输入Y分量
        input  wire        in_href,        // 行有效信号
        input  wire        in_vsync,       // 场同步信号
        input  wire [TILE_NUM_BITS-1:0] tile_idx,       // tile索引

        // 乒乓控制
        input  wire        ping_pong_flag,

        // 清零控制
        output wire        clear_start,
        input  wire        clear_done,

        // RAM接口
        output wire [TILE_NUM_BITS-1:0] ram_rd_tile_idx,
        output wire [TILE_NUM_BITS-1:0] ram_wr_tile_idx,
        output wire [7:0]  ram_wr_addr_a,
        output wire [15:0] ram_wr_data_a,
        output wire        ram_wr_en_a,
        output wire [7:0]  ram_rd_addr_b,
        input  wire [15:0] ram_rd_data_b,

        // 帧完成标志
        output wire        frame_hist_done
    );

    // ========================================================================
    // 信号边沿检测
    // ========================================================================
    reg vsync_d;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n)
            vsync_d <= 1'b0;
        else
            vsync_d <= in_vsync;
    end

    wire vsync_pos = in_vsync && !vsync_d;  // Frame Start
    wire vsync_neg = !in_vsync && vsync_d;  // Frame End

    // ========================================================================
    // 输出信号生成
    // ========================================================================
    assign clear_start = vsync_pos;
    assign frame_hist_done = vsync_neg;

    // ========================================================================
    // Stage 1: 输入打拍
    // ========================================================================
    reg [7:0]  pixel_s1;
    reg [TILE_NUM_BITS-1:0] tile_s1;
    reg        valid_s1;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_s1 <= 8'd0;
            tile_s1 <= {TILE_NUM_BITS{1'b0}};
            valid_s1 <= 1'b0;
        end
        else begin
            pixel_s1 <= in_y;
            tile_s1 <= tile_idx;
            valid_s1 <= in_href && in_vsync && clear_done;
        end
    end

    // ========================================================================
    // Stage 2: RAM读取数据 (Address latched by RAM)
    // ========================================================================
    reg [7:0]  pixel_s2;
    reg [TILE_NUM_BITS-1:0] tile_s2;
    reg        valid_s2;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_s2 <= 8'd0;
            tile_s2 <= {TILE_NUM_BITS{1'b0}};
            valid_s2 <= 1'b0;
        end
        else begin
            pixel_s2 <= pixel_s1;
            tile_s2 <= tile_s1;
            valid_s2 <= valid_s1;
        end
    end

    // ========================================================================
    // Stage 3: RAM写入逻辑 + Forwarding
    // ========================================================================
    reg [7:0]  pixel_s3;
    reg [TILE_NUM_BITS-1:0] tile_s3;
    reg        valid_s3;
    reg [15:0] ram_wr_data_s3;

    // ========================================================================
    // Forwarding Logic (S1-S3 & S2-S3)
    // ========================================================================
    // 1. S1-S3 Conflict: Read and Write at SAME address in SAME cycle.
    //    Memory might return X (or Old Data). We MUST use the Write Data (New).
    //    Since Read Output appears at S2 (Next Cycle), we register the Write Data here.
    reg        conflict_s1_s3_reg;
    reg [15:0] forward_s1_s3_data;

    wire conflict_s1_s3 = (pixel_s1 == pixel_s3) &&
         (tile_s1 == tile_s3) &&
         valid_s1 && valid_s3;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            conflict_s1_s3_reg <= 1'b0;
            forward_s1_s3_data <= 16'd0;
        end
        else begin
            conflict_s1_s3_reg <= conflict_s1_s3;
            if (conflict_s1_s3) begin
                forward_s1_s3_data <= ram_wr_data_s3;
            end
        end
    end

    // 2. S2-S3 Conflict: Pipeline Hazard.
    //    S2 processing addr X. S3 writing addr X (from prev cycle).
    wire conflict_s2_s3 = (pixel_s2 == pixel_s3) &&
         (tile_s2 == tile_s3) &&
         valid_s3 && valid_s2;

    // 3. Base Data Selection
    // Priority: S2-S3 Forward (Freshest) > S1-S3 Forward (Latched) > RAM Read
    // Case A-A-A: S2 needs data from S3 (the middle A), not from S1 latch (the first A).
    wire [15:0] base_data_s2 = conflict_s2_s3 ? ram_wr_data_s3 :
         (conflict_s1_s3_reg ? forward_s1_s3_data : ram_rd_data_b);

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_s3 <= 8'd0;
            tile_s3 <= {TILE_NUM_BITS{1'b0}};
            valid_s3 <= 1'b0;
            ram_wr_data_s3 <= 16'd0;
        end
        else begin
            pixel_s3 <= pixel_s2;
            tile_s3 <= tile_s2;
            valid_s3 <= valid_s2;

            // Increment Logic
            // Always +1. If conflict, we build upon the just-written value.
            if (valid_s2) begin
                ram_wr_data_s3 <= base_data_s2 + 16'd1;
            end
        end
    end

    // ========================================================================
    // RAM接口连接
    // ========================================================================
    // Port B: 读接口（Stage 1）
    assign ram_rd_tile_idx = tile_s1;
    assign ram_rd_addr_b = pixel_s1;

    // Port A: 写接口（Stage 3）
    assign ram_wr_tile_idx = tile_s3;
    assign ram_wr_addr_a = pixel_s3;
    assign ram_wr_data_a = ram_wr_data_s3;
    assign ram_wr_en_a = valid_s3 && clear_done;

endmodule
