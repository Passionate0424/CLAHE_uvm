vlib work
set UVM_HOME E:/modeltech64_2020.4/verilog_src/uvm-1.1d
set WORK_HOME E:/project/example_and_uvm_source_code/puvm/src/ch2/section2.5/2.5.2
vlog +incdir+$UVM_HOME/src  -L mtiAvm -L mtiOvm -L mtiUvm -L mtiUPF $UVM_HOME/src/uvm_pkg.sv  $WORK_HOME/dut.sv top_tb.sv

vsim -voptargs=+acc  -c -sv_lib E:/modeltech64_2020.4/uvm-1.1d/win64/uvm_dpi work.top_tb +UVM_TESTNAME=my_case0

vsim -voptargs=+acc  -c -sv_lib E:/modeltech64_2020.4/uvm-1.1d/win64/uvm_dpi work.top_tb +UVM_TESTNAME=my_case1
