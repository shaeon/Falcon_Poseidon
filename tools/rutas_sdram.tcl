# Detalle de tiempos de los pines de la SDRAM (ejecutar en poseidon/):
#   quartus_sta -t ../tools/rutas_sdram.tcl
# Deja output_files/rutas_sdram.txt con las peores rutas de entrada y salida.
project_open falcon_poseidon
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set f output_files/rutas_sdram.txt
file delete -force $f
foreach corner {slow fast} {
	if {$corner == "fast"} {
		delete_timing_netlist
		create_timing_netlist -model fast
		read_sdc
		update_timing_netlist
	}
	report_timing -setup -from [get_ports {SDRAM_DQ[*]}] -npaths 3 -detail summary -file $f -append -panel_name "$corner lectura setup"
	report_timing -hold  -from [get_ports {SDRAM_DQ[*]}] -npaths 3 -detail summary -file $f -append -panel_name "$corner lectura hold"
	report_timing -setup -to [get_ports {SDRAM_*}] -npaths 3 -detail summary -file $f -append -panel_name "$corner salida setup"
	report_timing -hold  -to [get_ports {SDRAM_*}] -npaths 3 -detail summary -file $f -append -panel_name "$corner salida hold"
}
delete_timing_netlist
project_close
