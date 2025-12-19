//histogram
`ifndef HISTOGRAM_TRANSACTION__SV
`define HISTOGRAM_TRANSACTION__SV

class histogram_transaction extends uvm_sequence_item;

    rand bit [7:0] in_y         [];
    rand int       width;
    rand int       height;
    int            exp_histogram[64][256];

    constraint frame_size_cons {in_y.size() == width * height;}
    constraint res_cons {
        width == 80;
        height == 64;
    }


    `uvm_object_utils_begin(histogram_transaction)
        `uvm_field_array_int(in_y, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "histogram_transaction");
        super.new();
    endfunction

endclass
`endif
