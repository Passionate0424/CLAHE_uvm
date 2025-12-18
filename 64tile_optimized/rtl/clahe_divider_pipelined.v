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
// Pipelined Divider (32-bit Unsigned)
//
// Description:
//   A fully pipelined 32-bit unsigned divider implementation.
//   - Input: 32-bit dividend, 32-bit divisor
//   - Output: 32-bit quotient, 32-bit remainder
//   - Latency: 32 cycles
//   - Throughput: 1 result per cycle
//   - Algorithm: Non-Restoring Division (Pipelined)
//
//   Why Pipelined?
//   - Breaks down the 32-bit division into 32 stages.
//   - Each stage performs 1-bit shift-and-subtract.
//   - High frequency closure (short critical path per stage).
//
//   Note: This module does NOT support AXI Stream flow control (backpressure).
//   It assumes the downstream logic can always accept data (valid-only flow).
//
// ============================================================================

`timescale 1ns / 1ps

module clahe_divider_pipelined #(
        parameter DATA_WIDTH = 32
    )(
        input  wire                  clk,
        input  wire                  rst_n,

        // Input Interface
        input  wire                  start,          // Input Valid
        input  wire [DATA_WIDTH-1:0] dividend,       // Numerator
        input  wire [DATA_WIDTH-1:0] divisor,        // Denominator

        // Output Interface
        output wire                  done,           // Output Valid
        output wire [DATA_WIDTH-1:0] quotient,
        output wire [DATA_WIDTH-1:0] remainder
    );

    // ========================================================================
    // Pipeline Registers (Distributed)
    // ========================================================================
    // Refactored to use individual registers per stage to prevent any
    // synthesis ambiguity or multi-driver issues on bit-vectors.

    // Stage 0 (Input Latching)
    reg                  pipe_valid_0;
    reg [DATA_WIDTH-1:0] pipe_rem_0;
    reg [DATA_WIDTH-1:0] pipe_quot_0;
    reg [DATA_WIDTH-1:0] pipe_div_0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_valid_0 <= 1'b0;
            pipe_rem_0   <= {DATA_WIDTH{1'b0}};
            pipe_quot_0  <= {DATA_WIDTH{1'b0}};
            pipe_div_0   <= {DATA_WIDTH{1'b0}};
        end
        else begin
            pipe_valid_0 <= start;
            if (start) begin
                pipe_rem_0   <= {DATA_WIDTH{1'b0}};
                pipe_quot_0  <= dividend;
                pipe_div_0   <= divisor;
            end
            else begin
                pipe_rem_0   <= {DATA_WIDTH{1'b0}};
                pipe_quot_0  <= {DATA_WIDTH{1'b0}};
                pipe_div_0   <= {DATA_WIDTH{1'b0}};
            end
        end
    end

    // Pipeline Interconnect Wires
    // stage_valid_out[k] connects to Input of Stage k+1
    // We use an array of wires for clean connectivity expression
    wire                  stage_valid_out [0:DATA_WIDTH];
    wire [DATA_WIDTH-1:0] stage_rem_out   [0:DATA_WIDTH];
    wire [DATA_WIDTH-1:0] stage_quot_out  [0:DATA_WIDTH];
    wire [DATA_WIDTH-1:0] stage_div_out   [0:DATA_WIDTH];

    // Connect Stage 0 outputs to Wires [0]
    assign stage_valid_out[0] = pipe_valid_0;
    assign stage_rem_out[0]   = pipe_rem_0;
    assign stage_quot_out[0]  = pipe_quot_0;
    assign stage_div_out[0]   = pipe_div_0;

    // Generate Stages 1 to 32
    genvar k;
    generate
        for (k = 0; k < DATA_WIDTH; k = k + 1) begin : pipe_stage

            // Registers for Stage K+1
            reg                  r_valid;
            reg [DATA_WIDTH-1:0] r_rem;
            reg [DATA_WIDTH-1:0] r_quot;
            reg [DATA_WIDTH-1:0] r_div;

            // Inputs from Stage K (via Wires)
            wire                  in_valid = stage_valid_out[k];
            wire [DATA_WIDTH-1:0] in_rem   = stage_rem_out[k];
            wire [DATA_WIDTH-1:0] in_quot  = stage_quot_out[k];
            wire [DATA_WIDTH-1:0] in_div   = stage_div_out[k];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    r_valid <= 1'b0;
                    r_rem   <= {DATA_WIDTH{1'b0}};
                    r_quot  <= {DATA_WIDTH{1'b0}};
                    r_div   <= {DATA_WIDTH{1'b0}};
                end
                else begin
                    r_valid <= in_valid;
                    r_div   <= in_div; // Propagate divisor

                    if (in_valid) begin
                        // Core Division Logic (Shift & Subtract)
                        // Check if (Rem << 1 | Quot_MSB) >= Div
                        if ({in_rem[DATA_WIDTH-2:0], in_quot[DATA_WIDTH-1]} >= in_div) begin
                            // Subtract
                            r_rem <= {in_rem[DATA_WIDTH-2:0], in_quot[DATA_WIDTH-1]} - in_div;
                            // Shift Q and set LSB to 1
                            r_quot <= {in_quot[DATA_WIDTH-2:0], 1'b1};
                        end
                        else begin
                            // Restore (Keep shifted Rem)
                            r_rem <= {in_rem[DATA_WIDTH-2:0], in_quot[DATA_WIDTH-1]};
                            // Shift Q and set LSB to 0
                            r_quot <= {in_quot[DATA_WIDTH-2:0], 1'b0};
                        end
                    end
                    else begin
                        // Idle / Clean Data (Optional for logic valid, but good for X-elimination)
                        r_rem  <= {DATA_WIDTH{1'b0}};
                        r_quot <= {DATA_WIDTH{1'b0}};
                    end
                end
            end

            // Connect Registers to Wires [k+1]
            assign stage_valid_out[k+1] = r_valid;
            assign stage_rem_out[k+1]   = r_rem;
            assign stage_quot_out[k+1]  = r_quot;
            assign stage_div_out[k+1]   = r_div;

        end
    endgenerate

    // Final Output (from Wire 32)
    assign done      = stage_valid_out[DATA_WIDTH];
    assign quotient  = stage_quot_out[DATA_WIDTH];
    assign remainder = stage_rem_out[DATA_WIDTH];

endmodule
