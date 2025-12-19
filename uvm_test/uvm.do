vlib work

# 请注意修改为您本地的 UVM 安装路径
set UVM_HOME E:/modeltech64_2020.4/verilog_src/uvm-1.1d
# set UVM_HOME C:/questasim64_10.6c/verilog_src/uvm-1.1d

set WORK_HOME .

# 编译 UVM 库和项目文件
# 注意：dut.sv 内部 include 了 RTL 文件，使用相对路径
vlog +incdir+$UVM_HOME/src -L mtiAvm -L mtiOvm -L mtiUvm -L mtiUPF $UVM_HOME/src/uvm_pkg.sv $WORK_HOME/dut.sv $WORK_HOME/top_tb.sv

# 仿真 (注意 sv_lib 路径也需要匹配您的安装)
vsim -voptargs=+acc -c -sv_lib E:/modeltech64_2020.4/uvm-1.1d/win64/uvm_dpi work.top_tb +UVM_TESTNAME=my_case0

run -all
