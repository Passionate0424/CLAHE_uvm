// histogram_coverage.sv
`ifndef HISTOGRAM_COVERAGE__SV
`define HISTOGRAM_COVERAGE__SV 

class histogram_coverage extends uvm_subscriber #(histogram_transaction);
    `uvm_component_utils(histogram_coverage)

    // Helper variables for sampling
    bit [7:0] current_val;
    bit [7:0] next_val;
    bit [7:0] val_dist2;  // Value at distance 2

    // Covergroup: Focus on Pixel Value Conflicts (RMW Hazards)
    covergroup cg_pixel_conflict;
        option.per_instance = 1;

        // 1. Pixel Value Distribution
        cp_val: coverpoint current_val {
            bins low = {[0 : 63]};
            bins mid_l = {[64 : 127]};
            bins mid_h = {[128 : 191]};
            bins high = {[192 : 255]};
            bins all[] = default;  // Check all 256 values if needed, or stick to ranges
        }

        // 2. Consecutive Transition (Distance 1)
        // Focus: Same value (Direct RMW Conflict)
        // Implemented via 'cp_diff' below for better syntax support

        // Alternative approach for transition: Sample "diff"
        cp_diff: coverpoint (int'(next_val) - int'(current_val)) {
            bins same = {0};  // RMW Conflict!
            bins near_p1 = {1};  // +1
            bins near_m1 = {-1};  // -1
            bins near_p2 = {2};
            bins near_m2 = {-2};
            bins others = default;
        }

        // 3. Distance 2 Transition (Pipeline Hazard)
        cp_diff_dist2: coverpoint (int'(val_dist2) - int'(current_val)) {
            bins same_d2 = {0};  // Pipeline Hazard!
            bins others = default;
        }

    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_pixel_conflict = new();
    endfunction

    // Write function: Called by Monitor's Analysis Port
    virtual function void write(histogram_transaction t);
        // Analyze the Frame Data
        // Iterate through the array to find transitions

        // We need to iterate carefully to avoid out-of-bounds
        for (int i = 0; i < t.in_y.size() - 2; i++) begin
            current_val = t.in_y[i];
            next_val    = t.in_y[i+1];
            val_dist2   = t.in_y[i+2];

            // Sample
            cg_pixel_conflict.sample();
        end

        // Handle the last few pixels if needed or just ignore boundary effects
        // The core requirement is to cover the *conflicts* which happen inside the stream.
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("COVERAGE", $sformatf(
                  "Instance Coverage: %.2f%%", cg_pixel_conflict.get_inst_coverage()), UVM_LOW)
    endfunction

endclass

`endif
