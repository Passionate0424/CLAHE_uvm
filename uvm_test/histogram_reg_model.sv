//histogram
`ifndef HISTOGRAM_REG_MODEL__SV
`define HISTOGRAM_REG_MODEL__SV 

class histogram_ram_mem extends uvm_mem;
    //定义uvm_mem
    `uvm_object_utils(histogram_ram_mem)

    function new(string name = "histogram_ram_mem");
        super.new(name, 16384, 16, "RW", UVM_NO_COVERAGE);
    endfunction
endclass

// 定义后门类
class histogram_ram_backdoor extends uvm_reg_backdoor;
    `uvm_object_utils(histogram_ram_backdoor)

    function new(string name = "histogram_ram_backdoor");
        super.new(name);
    endfunction

    extern virtual task read(uvm_reg_item rw);
endclass

class histogram_ram_model extends uvm_reg_block;
    //    rand reg_invert invert;
    //用mem表示ram
    rand histogram_ram_mem histogram_ram;
    histogram_ram_backdoor backdoor;
    virtual function void build();
        // 由于交织存储设计，不能使用default_map,需要自定义后门
        histogram_ram = histogram_ram_mem::type_id::create("histogram_ram_mem");

        // 挂载后门
        backdoor      = histogram_ram_backdoor::type_id::create("histogram_ram_backdoor");
        histogram_ram.set_backdoor(backdoor);

        histogram_ram.configure(this);
    endfunction

    `uvm_object_utils(histogram_ram_model)

    function new(input string name = "histogram_ram_model");
        super.new(name, UVM_NO_COVERAGE);
    endfunction
endclass

task histogram_ram_backdoor::read(uvm_reg_item rw);
    string        path;
    bit    [15:0] r_data;
    int           status;
    int           dut_pp_flag;
    int           completed_set;

    // 1. 解析逻辑地址 (rw.offset 是 0 ~ 16383)
    // 参考 RTL 的 get_bank_id 逻辑
    int           logical_addr = rw.offset;
    int           bin_addr = logical_addr % 256;  // Bin index
    int           tile_idx = logical_addr / 256;  // Tile index (0-63)

    // 2. 计算物理位置 (参考 RTL clahe_ram_banked.v)
    // Bank ID = {OddY, OddX}
    // idx[3]是y的最低位, idx[0]是x的最低位
    int           flat_bank_id = (((tile_idx >> 3) & 1) << 1) | (tile_idx & 1);

    // Set ID (PingPong) - 这里假设我们只读当前完成的那一帧
    // 假设外部可以通过某种方式配置 viewing_set (比如 0 或 1)
    int           set_id = 0;  // 需要根据 PingPong 状态动态决定，或者读所有的 Set

    // Bank 内的地址 (参考 get_bank_addr)
    // inner_tx = tx >> 1; inner_ty = ty >> 1
    // Bank Addr = {inner_ty, inner_tx, bin_addr}
    int           tx = tile_idx & 7;
    int           ty = (tile_idx >> 3) & 7;

    int           bank_offset = ((ty >> 1) << (3 - 1 + 8)) | ((tx >> 1) << 8) | bin_addr;

    // 3. 读取 DUT 的实际 Ping-Pong 状态，选择正确的 Set
    void'(uvm_hdl_read("top_tb.my_dut.ping_pong_flag", dut_pp_flag));

    // Scoreboard 读取时，Driver 已翻转 PP
    // 所以刚完成写入的 Set = 1 - dut_pp_flag
    completed_set = 1 - dut_pp_flag;

    path = $sformatf(
        "top_tb.my_dut.ram_banked_inst.gen_set[%0d].gen_bank[%0d].u_ram.ram[%0d]",
        completed_set,
        flat_bank_id,
        bank_offset
    );

    if (uvm_hdl_read(path, r_data)) begin
        rw.value[0] = r_data;
        rw.status   = UVM_IS_OK;
    end else begin
        `uvm_error("BACKDOOR", $sformatf("Cannot read HDL path: %s", path))
        rw.status = UVM_NOT_OK;
    end

endtask


`endif
