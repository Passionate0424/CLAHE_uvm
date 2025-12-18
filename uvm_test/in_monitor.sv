//histogram
`ifndef MY_MONITOR__SV
`define MY_MONITOR__SV
class in_monitor extends uvm_monitor;

    virtual he_if_i                     vif;

    uvm_analysis_port #(my_transaction) ap;

    `uvm_component_utils(in_monitor)
    function new(string name = "in_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual he_if_i)::get(this, "", "vif", vif))
            `uvm_fatal("my_monitor", "virtual interface must be set for vif!!!")
        ap = new("ap", this);
    endfunction

    extern task main_phase(uvm_phase phase);
    extern task collect_one_frame(my_transaction tr);
endclass

task in_monitor::main_phase(uvm_phase phase);
    my_transaction tr;
    while (1) begin
        tr = new("tr");
        collect_one_frame(tr);
        ap.write(tr);
    end
endtask

task in_monitor::collect_one_frame(my_transaction tr);
    bit [7:0] data[$];
    while (1) begin
        @(posedge vif.clk);
        if (vif.in_href) break;
    end
    `uvm_info("in_monitor", "begin to collect one frame", UVM_LOW);

    while (vif.in_vsync) begin
        if (vif.in_href) begin
            data.push_back(vif.in_y);
        end
        @(posedge vif.clk);
    end
    tr.in_y = new[data.size()];
    foreach (data[i]) begin
        tr.in_y[i] = data[i];
    end
    `uvm_info("in_monitor", "end collect one frame", UVM_LOW);

endtask


`endif
