//histogram
`ifndef IN_MONITOR__SV
`define IN_MONITOR__SV
class in_monitor extends uvm_monitor;

    virtual he_if_i                            vif;

    uvm_analysis_port #(histogram_transaction) ap;

    `uvm_component_utils(in_monitor)
    function new(string name = "in_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual he_if_i)::get(this, "", "vif", vif))
            `uvm_fatal("in_monitor", "virtual interface must be set for vif!!!")
        ap = new("ap", this);
    endfunction

    extern task main_phase(uvm_phase phase);
    extern task collect_one_frame(histogram_transaction tr);
endclass

task in_monitor::main_phase(uvm_phase phase);
    histogram_transaction tr;
    while (1) begin
        tr = new("tr");
        collect_one_frame(tr);
        ap.write(tr);
    end
endtask

task in_monitor::collect_one_frame(histogram_transaction tr);
    bit [7:0] data                  [$];
    int       current_width = 0;
    int       calculated_width = 0;
    int       calculated_height = 0;
    bit       href_d = 0;

    // Wait for VSync Rising Edge (Start of Frame)
    // First, wait for VSync to be LOW (if it's currently high or undefined)
    while (vif.in_vsync === 1'b1 || vif.in_vsync === 1'bx) begin
        @(posedge vif.clk);
    end
    // Then wait for VSync to go HIGH
    while (vif.in_vsync !== 1'b1) begin
        @(posedge vif.clk);
    end

    `uvm_info("in_monitor", "begin to collect one frame", UVM_LOW);

    // Collect Data while VSync is HIGH
    while (vif.in_vsync) begin
        if (vif.in_href) begin
            data.push_back(vif.in_y);
            current_width++;
        end

        // Detect HREF Falling Edge to count rows
        if (href_d && !vif.in_href) begin
            if (calculated_width == 0) calculated_width = current_width;
            else if (calculated_width != current_width)
                `uvm_error(
                    "in_monitor", $sformatf(
                    "Row width mismatch! Exp %0d, Got %0d", calculated_width, current_width));

            calculated_height++;
            current_width = 0;
        end
        href_d = vif.in_href;
        @(posedge vif.clk);
    end

    // Handle last row if VSync drops immediately after HREF (unlikely but possible)
    if (current_width > 0) begin
        if (calculated_width == 0) calculated_width = current_width;
        calculated_height++;
    end

    tr.in_y = new[data.size()];
    foreach (data[i]) begin
        tr.in_y[i] = data[i];
    end
    tr.width  = calculated_width;
    tr.height = calculated_height;

    `uvm_info("in_monitor", $sformatf("end collect one frame: %0dx%0d", tr.width, tr.height),
              UVM_LOW);

endtask


`endif
