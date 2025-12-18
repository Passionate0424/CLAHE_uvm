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

`timescale 1ns / 1ps

module tb_clahe_divider_pipelined;

    parameter DATA_WIDTH = 32;

    reg                   clk;
    reg                   rst_n;
    reg                   start;
    reg  [DATA_WIDTH-1:0] dividend;
    reg  [DATA_WIDTH-1:0] divisor;

    wire                  done;
    wire [DATA_WIDTH-1:0] quotient;
    wire [DATA_WIDTH-1:0] remainder;

    // DUT Instance
    clahe_divider_pipelined #(
                                .DATA_WIDTH(DATA_WIDTH)
                            ) u_divider (
                                .clk(clk),
                                .rst_n(rst_n),
                                .start(start),
                                .dividend(dividend),
                                .divisor(divisor),
                                .done(done),
                                .quotient(quotient),
                                .remainder(remainder)
                            );

    // Clock Generation
    initial begin
        clk = 0;
        forever
            #5 clk = ~clk; // 100MHz
    end

    // Test Procedure
    initial begin
        rst_n = 0;
        start = 0;
        dividend = 0;
        divisor = 0;
        #100;
        rst_n = 1;

        // Test Case 1: 100 / 10
        #20;
        dividend = 100;
        divisor = 10;
        start = 1;
        #10;
        start = 0;

        // Test Case 2: 255 / 3
        #10;
        dividend = 255;
        divisor = 3;
        start = 1;
        #10;
        start = 0;

        // Test Case 3: 0 / 10
        #10;
        dividend = 0;
        divisor = 10;
        start = 1;
        #10;
        start = 0;

        // Wait for results (Latency ~32 cycles)
        #500;
        $finish;
    end

    // Monitor
    always @(posedge clk) begin
        if (done) begin
            $display("Time=%t | Dividend=? | Divisor=? | Quot=%d | Rem=%d",
                     $time, quotient, remainder);
        end
    end

endmodule
