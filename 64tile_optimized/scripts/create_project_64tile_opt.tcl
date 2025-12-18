# Vivado Project Creation Script for CLAHE 64-Tile Optimized Version
# usage: vivado -mode batch -source create_project_64tile_opt.tcl

# Set project name and directory
set _xil_proj_name_ "clahe_vivado_64t_opt"
set _xil_proj_dir_ "e:/FPGA_codes/CLAHE/vivado_project/clahe_vivado_64t_opt"

# Create project
create_project ${_xil_proj_name_} ${_xil_proj_dir_} -part xc7z020clg400-3 -force

# Set project properties
set obj [get_projects ${_xil_proj_name_}]
set_property -name "default_lib" -value "xil_defaultlib" -objects $obj
set_property -name "sim.ip.auto_export_scripts" -value "1" -objects $obj
set_property -name "simulator_language" -value "Mixed" -objects $obj
set_property -name "target_language" -value "Verilog" -objects $obj

# Add RTL sources
# 64tile_optimized RTL files
add_files -norecurse -scan_for_includes "e:/FPGA_codes/CLAHE/projects/64tile_optimized/rtl"

# Add XDC constraints
# Re-using the sim constraints
add_files -fileset constrs_1 -norecurse "e:/FPGA_codes/CLAHE/vivado_project/clahe_vivado/clahe_vivado.srcs/constrs_1/imports/clahe_top_sim.xdc"

# Set top module
set_property top clahe_top [current_fileset]

# Set simulation settings (optional)
# Using 16tile TB files as placeholders for simulation set
add_files -fileset sim_1 -norecurse "e:/FPGA_codes/CLAHE/projects/16tile/tb/bmp_for_videoStream_24bit.sv"
add_files -fileset sim_1 -norecurse "e:/FPGA_codes/CLAHE/projects/16tile/tb/bmp_to_videoStream.sv"
add_files -fileset sim_1 -norecurse "e:/FPGA_codes/CLAHE/projects/16tile/tb/tb_clahe_top_bmp_multi.sv"
set_property top tb_clahe_top_bmp_multi [get_filesets sim_1]

puts "Project ${_xil_proj_name_} created successfully in ${_xil_proj_dir_}"
