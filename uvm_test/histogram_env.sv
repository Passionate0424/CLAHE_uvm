// histogram
`ifndef HISTOGRAM_ENV__SV
`define HISTOGRAM_ENV__SV
`include "histogram_reg_model.sv"

class histogram_env extends uvm_env;

    histogram_agent                                i_agt;
    histogram_agent                                o_agt;
    histogram_model                                mdl;
    histogram_scoreboard                           scb;

    histogram_ram_model                            rm;

    uvm_tlm_analysis_fifo #(histogram_transaction) agt_scb_fifo;
    uvm_tlm_analysis_fifo #(histogram_transaction) agt_mdl_fifo;
    uvm_tlm_analysis_fifo #(model_transaction)     mdl_scb_fifo;

    function new(string name = "histogram_env", uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        i_agt           = histogram_agent::type_id::create("i_agt", this);
        // o_agt           = histogram_agent::type_id::create("o_agt", this);
        i_agt.is_active = UVM_ACTIVE;
        // o_agt.is_active = UVM_PASSIVE;
        mdl             = histogram_model::type_id::create("mdl", this);
        scb             = histogram_scoreboard::type_id::create("scb", this);
        agt_scb_fifo    = new("agt_scb_fifo", this);
        agt_mdl_fifo    = new("agt_mdl_fifo", this);
        mdl_scb_fifo    = new("mdl_scb_fifo", this);

        rm              = histogram_ram_model::type_id::create("rm", this);
        rm.build();
        rm.lock_model();
        uvm_config_db#(histogram_ram_model)::set(this, "scb", "rm", rm);


    endfunction

    extern virtual function void connect_phase(uvm_phase phase);

    `uvm_component_utils(histogram_env)
endclass

function void histogram_env::connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // 1. Input Agent -> Model (for Reference Calculation)
    i_agt.ap.connect(agt_mdl_fifo.analysis_export);
    mdl.port.connect(agt_mdl_fifo.blocking_get_export);

    // 2. Model -> Scoreboard (Expected Result)
    mdl.ap.connect(mdl_scb_fifo.analysis_export);
    scb.exp_port.connect(mdl_scb_fifo.blocking_get_export);

    // 3. Input Agent -> Scoreboard (Trigger Signal)
    // Re-use input monitor transaction as "Act" trigger
    i_agt.ap.connect(agt_scb_fifo.analysis_export);
    scb.act_port.connect(agt_scb_fifo.blocking_get_export);

    // o_agt is not used for histogram verification
endfunction

`endif
