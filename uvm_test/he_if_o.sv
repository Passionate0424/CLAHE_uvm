//histogram
`ifndef MY_IF__SV
`define MY_IF__SV

        interface he_if_i(input clk, input rst_n);

            // 清零控制
            logic       clear_start;
            // RAM接口
            logic [6-1:0] ram_rd_tile_idx;
            logic [6-1:0] ram_wr_tile_idx;
            logic [7:0]    ram_wr_addr_a;
            logic [15:0]   ram_wr_data_a;
            logic          ram_wr_en_a;
            logic [7:0]    ram_rd_addr_b;

            // 帧完成标志
            logic          frame_hist_done;

        endinterface

`endif
