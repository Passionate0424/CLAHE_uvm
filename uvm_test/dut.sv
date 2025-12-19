`include "../64tile_optimized/rtl/clahe_simple_dual_ram_model.v"
`include "../64tile_optimized/rtl/clahe_ram_banked.v"
`include "../64tile_optimized/rtl/clahe_histogram_stat.v"

module dut (
    input wire       clk,
    input wire       rst_n,
    input wire [7:0] in_y,
    input wire       in_href,
    input wire       in_vsync,
    input wire [5:0] tile_idx,
    input wire       ping_pong_flag
);

    // Internal connection wires
    wire        clear_start;
    wire        clear_done;
    wire [ 5:0] ram_rd_tile_idx;
    wire [ 5:0] ram_wr_tile_idx;
    wire [ 7:0] ram_wr_addr_a;
    wire [15:0] ram_wr_data_a;
    wire        ram_wr_en_a;
    wire [ 7:0] ram_rd_addr_b;
    wire [15:0] ram_rd_data_b;
    wire        frame_hist_done;

    // Histogram Statistics Module
    clahe_histogram_stat #(
        .TILE_NUM_BITS(6)
    ) histogram_inst (
        .pclk           (clk),
        .rst_n          (rst_n),
        .in_y           (in_y),
        .in_href        (in_href),
        .in_vsync       (in_vsync),
        .tile_idx       (tile_idx),
        .ping_pong_flag (ping_pong_flag),
        .clear_start    (clear_start),
        .clear_done     (clear_done),
        .ram_rd_tile_idx(ram_rd_tile_idx),
        .ram_wr_tile_idx(ram_wr_tile_idx),
        .ram_wr_addr_a  (ram_wr_addr_a),
        .ram_wr_data_a  (ram_wr_data_a),
        .ram_wr_en_a    (ram_wr_en_a),
        .ram_rd_addr_b  (ram_rd_addr_b),
        .ram_rd_data_b  (ram_rd_data_b),
        .frame_hist_done(frame_hist_done)
    );

    // Banked RAM Module
    clahe_ram_banked #(
        .TILE_NUM_BITS(6)
    ) ram_banked_inst (
        .pclk          (clk),
        .rst_n         (rst_n),
        .ping_pong_flag(ping_pong_flag),
        .clear_start   (clear_start),
        .clear_done    (clear_done),

        // Histogram Interface
        .hist_rd_tile_idx(ram_rd_tile_idx),
        .hist_wr_tile_idx(ram_wr_tile_idx),
        .hist_wr_addr    (ram_wr_addr_a),
        .hist_wr_data    (ram_wr_data_a),
        .hist_wr_en      (ram_wr_en_a),
        .hist_rd_addr    (ram_rd_addr_b),
        .hist_rd_data    (ram_rd_data_b),

        // Unused CDF Interface
        .cdf_tile_idx(6'd0),
        .cdf_addr    (8'd0),
        .cdf_wr_data (8'd0),
        .cdf_wr_en   (1'b0),
        .cdf_rd_en   (1'b0),
        // .cdf_rd_data(), // Leave unconnected

        // Unused Mapping Interface
        .mapping_tl_tile_idx(6'd0),
        .mapping_tr_tile_idx(6'd0),
        .mapping_bl_tile_idx(6'd0),
        .mapping_br_tile_idx(6'd0),
        .mapping_addr       (8'd0)
        // .mapping_* output ports open
    );

endmodule
