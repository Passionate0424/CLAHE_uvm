vlib work
vmap work work

vlog -work work ../rtl/clahe_divider_pipelined.v
vlog -work work ../tb/tb_clahe_divider_pipelined.sv

vsim -voptargs=+acc work.tb_clahe_divider_pipelined

add wave -position insertpoint sim:/tb_clahe_divider_pipelined/*
add wave -position insertpoint sim:/tb_clahe_divider_pipelined/u_divider/stage_valid
add wave -position insertpoint sim:/tb_clahe_divider_pipelined/u_divider/stage_quot

run 1000ns
