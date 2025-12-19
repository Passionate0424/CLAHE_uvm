// histogram
`ifndef HISROGRAM_AGENT__SV
`define HISROGRAM_AGENT__SV

class histogram_agent extends uvm_agent;
    histogram_sequencer                        sqr;
    histogram_driver                           drv;
    in_monitor                                 mon;

    uvm_analysis_port #(histogram_transaction) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    extern virtual function void build_phase(uvm_phase phase);
    extern virtual function void connect_phase(uvm_phase phase);

    `uvm_component_utils(histogram_agent)
endclass


function void histogram_agent::build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (is_active == UVM_ACTIVE) begin
        sqr = histogram_sequencer::type_id::create("sqr", this);
        drv = histogram_driver::type_id::create("drv", this);
    end
    mon = in_monitor::type_id::create("mon", this);
endfunction

function void histogram_agent::connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active == UVM_ACTIVE) begin
        drv.seq_item_port.connect(sqr.seq_item_export);
    end
    ap = mon.ap;
endfunction

`endif

