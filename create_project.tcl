# Recreates the Vivado project for the Nexys A7-100T.
#
# Usage (from the repository root):
#   vivado -mode batch -source create_project.tcl
# or in the Vivado Tcl Console:
#   cd <path-to>/FIR-Filter ; source create_project.tcl
#
# Result: vivado/fir_audio_nexys7/fir_audio_nexys7.xpr
# Sources are referenced in place (not copied), so edits to rtl/, coeffs/,
# sim/ and constraints/ are picked up directly.

set root [file normalize [file dirname [info script]]]
set proj_name fir_audio_nexys7
set proj_dir  [file join $root vivado $proj_name]

create_project $proj_name $proj_dir -part xc7a100tcsg324-1 -force
set_property target_language Verilog [current_project]

# Design sources: RTL + coefficient ROM files
add_files -fileset sources_1 [glob [file join $root rtl *.sv]]
add_files -fileset sources_1 [glob [file join $root coeffs *.mem]]
set_property top audio_fir_system [get_filesets sources_1]

# Constraints
add_files -fileset constrs_1 [file join $root constraints fir_audio_nexys7.xdc]

# Simulation sources
add_files -fileset sim_1 [glob [file join $root sim *.sv]]
set_property top tb_fir_filter [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Created [file join $proj_dir $proj_name.xpr]"
