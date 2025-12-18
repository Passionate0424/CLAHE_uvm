//histogram
`ifndef MY_TRANSACTION__SV
`define MY_TRANSACTION__SV

class my_transaction extends uvm_sequence_item;

    // rand bit[47:0] dmac;
    // rand bit[47:0] smac;
    // rand bit[15:0] ether_type;
    // rand byte      pload[];
    // rand bit[31:0] crc;
    rand bit [7:0] in_y         [];
    int            width;
    int            height;
    int            exp_histogram[64][256];

    // constraint in_y_cons{
    //    pload.size >= 46;
    //    pload.size <= 1500;
    // }
    constraint frame_size_cons {in_y.size() == width * height;}

    // function bit[31:0] calc_crc();
    //    return 32'h0;
    // endfunction

    // function void post_randomize();
    //    crc = calc_crc;
    // endfunction

    `uvm_object_utils_begin(my_transaction)
    // `uvm_field_int(dmac, UVM_ALL_ON)
    // `uvm_field_int(smac, UVM_ALL_ON)
    // `uvm_field_int(ether_type, UVM_ALL_ON)
    // `uvm_field_array_int(pload, UVM_ALL_ON)
    // `uvm_field_int(crc, UVM_ALL_ON)
        `uvm_field_array_int(in_y, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "my_transaction");
        super.new();
    endfunction

endclass
`endif
