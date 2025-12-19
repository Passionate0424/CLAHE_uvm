//histogram
`ifndef HISTOGRAM_TRANSACTION__SV
`define HISTOGRAM_TRANSACTION__SV

class histogram_transaction extends uvm_sequence_item;

    bit      [7:0] in_y         [];
    rand int       width;
    rand int       height;
    int            exp_histogram[64][256];

    // constraint frame_size_cons {in_y.size() == width * height;} // Removed: Manual allocation
    constraint res_cons {
        width == 1280;
        height == 720;
    }

    function void post_randomize();
        in_y = new[width * height];
        foreach (in_y[i]) in_y[i] = $urandom();
    endfunction


    `uvm_object_utils_begin(histogram_transaction)
        `uvm_field_array_int(in_y, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "histogram_transaction");
        super.new();
    endfunction

endclass
`endif
