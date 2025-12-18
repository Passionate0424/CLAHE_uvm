`ifndef MODEL_TRANSACTION__SV
`define MODEL_TRANSACTION__SV

class model_transaction extends uvm_sequence_item;

    int exp_histogram[64][256];

    `uvm_object_utils(model_transaction)

    function new(string name = "model_transaction");
        super.new(name);
    endfunction

endclass
`endif
