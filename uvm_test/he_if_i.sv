//histogram
`ifndef MY_IF__SV
`define MY_IF__SV

        interface he_if_i(input clk, input rst_n);

            // 输入接口
            logic [7:0]  in_y;            // 输入Y分量
            logic        in_href;        // 行有效信号
            logic        in_vsync;       // 场同步信号
            logic [6-1:0] tile_idx;       // tile索引

            // 乒乓控制
            logic        ping_pong_flag;
            logic [15:0] ram_rd_data_b;

        endinterface

`endif
