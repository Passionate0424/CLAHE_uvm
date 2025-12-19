`ifndef HISTOGRAM_SEQUENCER__SV
`define HISTOGRAM_SEQUENCER__SV 

class histogram_sequencer extends uvm_sequencer #(histogram_transaction);

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    `uvm_component_utils(histogram_sequencer)
endclass

`endif
