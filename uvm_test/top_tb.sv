`timescale 1ns / 1ps
`include "uvm_macros.svh"

import uvm_pkg::*;
`include "he_if_i.sv"
`include "histogram_transaction.sv"
`include "model_transaction.sv"
`include "histogram_reg_model.sv"
`include "histogram_sequencer.sv"
`include "histogram_driver.sv"
`include "in_monitor.sv"
`include "histogram_agent.sv"
`include "histogram_model.sv"
`include "histogram_scoreboard.sv"
`include "histogram_env.sv"
`include "base_test.sv"
`include "histogram_case0.sv"

module top_tb;

    reg clk;
    reg rst_n;

    // Interface Instantiation
    he_if_i input_if (
        .clk  (clk),
        .rst_n(rst_n)
    );

    // DUT Instantiation
    dut my_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .in_y          (input_if.in_y),
        .in_href       (input_if.in_href),
        .in_vsync      (input_if.in_vsync),
        .tile_idx      (input_if.tile_idx),
        .ping_pong_flag(input_if.ping_pong_flag)
    );

    initial begin
        clk = 0;
        forever begin
            #100 clk = ~clk;
        end
    end

    initial begin
        rst_n = 1'b0;
        #1000;
        rst_n = 1'b1;
    end

    initial begin
        run_test();
    end

    initial begin
        // Set Virtual Interface for Driver and Monitor
        uvm_config_db#(virtual he_if_i)::set(null, "uvm_test_top.env.i_agt.drv", "vif", input_if);
        uvm_config_db#(virtual he_if_i)::set(null, "uvm_test_top.env.i_agt.mon", "vif", input_if);
    end

endmodule
