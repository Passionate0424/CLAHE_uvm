`ifndef HISTOGRAM_MODEL__SV
`define HISTOGRAM_MODEL__SV

class histogram_model extends uvm_component;

    uvm_blocking_get_port #(my_transaction) port;
    uvm_analysis_port #(model_transaction)  ap;

    extern function new(string name, uvm_component parent);
    extern function void build_phase(uvm_phase phase);
    extern virtual task main_phase(uvm_phase phase);
    extern function void calculate_histogram(my_transaction tr, model_transaction mdl_tr);

    `uvm_component_utils(histogram_model)
endclass

function histogram_model::new(string name, uvm_component parent);
    super.new(name, parent);
endfunction

function void histogram_model::build_phase(uvm_phase phase);
    super.build_phase(phase);
    port = new("port", this);
    ap   = new("ap", this);
endfunction

task histogram_model::main_phase(uvm_phase phase);
    my_transaction    tr;
    model_transaction mdl_tr;
    super.main_phase(phase);
    while (1) begin
        port.get(tr);

        mdl_tr = new("mdl_tr");

        `uvm_info("REF_MODEL", $sformatf("Received frame: %0dx%0d", tr.width, tr.height), UVM_LOW)

        calculate_histogram(tr, mdl_tr);
        ap.write(mdl_tr);
    end
endtask

function void histogram_model::calculate_histogram(my_transaction tr, model_transaction mdl_tr);
    int tile_w, tile_h;

    // 假设 8x8 分块 (8行8列, 共64个Tile)
    // 默认 1280x720 / 8 => 160x90
    tile_w = tr.width / 8;
    tile_h = tr.height / 8;

    // 1. 清空直方图
    foreach (mdl_tr.exp_histogram[i, j]) begin
        mdl_tr.exp_histogram[i][j] = 0;
    end

    // 2. 遍历所有像素
    for (int i = 0; i < tr.in_y.size(); i++) begin
        int x = i % tr.width;
        int y = i / tr.width;

        // 计算所属的 Tile 索引 (0~63)
        int tx = x / tile_w;
        int ty = y / tile_h;
        int t_idx = ty * 8 + tx;

        // 统计灰度值
        // bit [7:0] val = tr.in_y[i]; // in_y defined as byte or bit[7:0]? my_transaction has rand bit [7:0] in_y[];
        int val = tr.in_y[i];

        if (t_idx >= 0 && t_idx < 64) begin
            mdl_tr.exp_histogram[t_idx][val]++;
        end
    end
    `uvm_info("REF_MODEL", "Histogram calculation finished", UVM_LOW)
endfunction

`endif
