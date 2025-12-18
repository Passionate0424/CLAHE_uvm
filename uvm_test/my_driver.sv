//histogram
`ifndef MY_DRIVER__SV
`define MY_DRIVER__SV
class my_driver extends uvm_driver #(my_transaction);

    virtual he_if_i vif;
    bit             ping_pong_flag;

    `uvm_component_utils(my_driver)
    function new(string name = "my_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual he_if_i)::get(this, "", "vif", vif))
            `uvm_fatal("my_driver", "virtual interface must be set for vif!!!")
    endfunction

    extern task main_phase(uvm_phase phase);
    extern task drive_one_frame(my_transaction tr);
    extern function int coordinate_to_tile_idx(int i, int j, integer w, integer h);
endclass

function int my_driver::coordinate_to_tile_idx(int i, int j, integer w, integer h);
    //64tile
    return (i / (h / 8)) * 8 + (j / (w / 8));
endfunction

task my_driver::main_phase(uvm_phase phase);
    ping_pong_flag = 1'b0;
    vif.in_href        <= 1'b0;
    vif.in_vsync       <= 1'b0;
    vif.in_y           <= 8'b0;
    vif.tile_idx       <= 6'b0;
    vif.ping_pong_flag <= ping_pong_flag;
    while (!vif.rst_n) @(posedge vif.clk);
    while (1) begin
        seq_item_port.get_next_item(req);
        drive_one_frame(req);
        seq_item_port.item_done();
    end
endtask

task my_driver::drive_one_frame(my_transaction tr);
    int frame_size;
    frame_size = tr.in_y.size();
    `uvm_info("my_driver", $sformatf("frame_size = %0d", frame_size), UVM_LOW);

    // 使用vsync、hsync生成帧输入时序
    // 等待rst_n拉高
    `uvm_info("my_driver", "begin to drive one frame", UVM_LOW);
    while (!vif.rst_n) @(posedge vif.clk);

    @(posedge vif.clk);
    vif.in_vsync <= 1'b1;
    for (int i = 0; i < tr.height; i++) begin
        repeat (10) @(posedge vif.clk);
        vif.in_href <= 1'b1;
        for (int j = 0; j < tr.width; j++) begin
            @(posedge vif.clk);
            vif.in_y           <= tr.in_y[i*tr.width+j];
            vif.tile_idx       <= coordinate_to_tile_idx(i, j, tr.width, tr.height);
            vif.ping_pong_flag <= ping_pong_flag;
        end
        @(posedge vif.clk);
        vif.in_href <= 1'b0;
    end
    repeat (10) @(posedge vif.clk);
    vif.in_vsync <= 1'b0;
    //帧结束
    ping_pong_flag = !ping_pong_flag;
    `uvm_info("my_driver", "end drive one frame", UVM_LOW);

endtask


`endif
