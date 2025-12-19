// histogram
`ifndef HISTOGRAM_SCOREBOARD__SV
`define HISTOGRAM_SCOREBOARD__SV

class histogram_scoreboard extends uvm_scoreboard;
    model_transaction                              expect_queue                             [$];
    uvm_blocking_get_port #(model_transaction)     exp_port;
    uvm_blocking_get_port #(histogram_transaction) act_port;  // Changed to match in_monitor
    histogram_ram_model                            rm;

    `uvm_component_utils(histogram_scoreboard)

    extern function new(string name, uvm_component parent = null);
    extern virtual function void build_phase(uvm_phase phase);
    extern virtual task main_phase(uvm_phase phase);
endclass

function histogram_scoreboard::new(string name, uvm_component parent = null);
    super.new(name, parent);
endfunction

function void histogram_scoreboard::build_phase(uvm_phase phase);
    super.build_phase(phase);
    exp_port = new("exp_port", this);
    act_port = new("act_port", this);
    if (!uvm_config_db#(histogram_ram_model)::get(this, "", "rm", rm)) begin
        `uvm_fatal("GET_RM", "cannot get histogram_ram_model from config db")
    end
endfunction

task histogram_scoreboard::main_phase(uvm_phase phase);
    model_transaction     get_expect;
    histogram_transaction get_actual;  // Trigger only
    uvm_status_e          status;
    uvm_reg_data_t        value;
    int                   offset;

    super.main_phase(phase);
    fork
        while (1) begin
            exp_port.get(get_expect);
            expect_queue.push_back(get_expect);
        end
        while (1) begin
            act_port.get(get_actual);  // Trigger signal (end of input frame)

            // Wait for DUT to finish processing (Input done -> RAM update delay)
            // DUT typically needs some cycles after vsync_in low to finish writing
            repeat (1000) @(posedge top_tb.clk);

            if (expect_queue.size() > 0) begin
                get_expect = expect_queue.pop_front();

                `uvm_info("SCB", "Start comparing histogram...", UVM_LOW)

                // Iterate all tiles and bins to compare
                foreach (get_expect.exp_histogram[i, j]) begin
                    // i = tile (0-63), j = bin (0-255)
                    offset = i * 256 + j;

                    // Backdoor Read from DUT Memory
                    rm.histogram_ram.read(status, offset, value, UVM_BACKDOOR);

                    // DEBUG: Probe internal signals if mismatch
                    if (value != get_expect.exp_histogram[i][j]) begin
                        int probe_clearing;
                        int probe_pp;
                        int probe_data_set1;
                        void'(uvm_hdl_read(
                            "top_tb.my_dut.ram_banked_inst.clearing", probe_clearing
                        ));
                        void'(uvm_hdl_read("top_tb.my_dut.ping_pong_flag", probe_pp));
                        // Probe Set 1
                        // Bank 0, Set 1, Bin 0
                        if (i == 0 && j == 0) begin
                            string path_s1 = "top_tb.my_dut.ram_banked_inst.gen_set[1].gen_bank[0].u_ram.ram[0]";
                            void'(uvm_hdl_read(path_s1, probe_data_set1));
                            `uvm_info(
                                "SCB_DEBUG",
                                $sformatf(
                                    "Mismatch Debug at Tile0 Bin0: Clearing=%0d PP_DUT=%0d Set1_Data=%0d",
                                    probe_clearing, probe_pp, probe_data_set1), UVM_LOW)
                        end
                    end

                    if (status != UVM_IS_OK) begin
                        `uvm_error("MEM_READ", $sformatf("Backdoor read failed at addr %0d",
                                                         offset))
                    end else begin
                        if (value != get_expect.exp_histogram[i][j]) begin
                            `uvm_error("COMPARE_FAIL",
                                       $sformatf("Tile[%0d] Bin[%0d] Mismatch! Exp=%0d, Act=%0d",
                                                 i, j, get_expect.exp_histogram[i][j], value))
                        end
                    end
                end
                `uvm_info("SCB", "Comparison finished for one frame", UVM_LOW)

            end else begin
                `uvm_error("SCB", "Received DUT trigger but Expect Queue is empty");
            end
        end
    join
endtask
`endif
