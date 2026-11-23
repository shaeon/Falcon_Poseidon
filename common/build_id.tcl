# Paso previo a la compilacion (se ejecuta en poseidon/):
#  - build_id.v con la fecha de compilacion (version del OSD)
#  - copia las tablas que el core de MiSTer lee con $readmemh, que las busca
#    con rutas relativas al proyecto (rtl/falcon/...)
set buildDate [clock format [clock seconds] -format %y%m%d]
set outputFile [open "build_id.v" "w"]
puts $outputFile "`define BUILD_DATE \"$buildDate\""
close $outputFile

# ROM de microcodigo, constantes y despacho de la FPU ($readmemh relativo al proyecto)
foreach f {fpu_ucode.hex fpu_const.hex fpu_disp.hex} {
	file copy -force ../rtl/fpu/$f $f
}

file mkdir rtl/falcon
foreach f {falcon_optbl.mem falcon_psg_vol.mem} {
	file copy -force ../Falcon_MiSTer/rtl/falcon/$f rtl/falcon/$f
}

# Videl con la base de 25,175 MHz en relacion exacta 48/61 con clk_sys: en la
# Poseidon clk_sys sale del VCO de 1537,5 MHz / 48 y clk_pix del mismo VCO / 61
# (falcon_mist_top, pll c3). Asi la FIFO de falcon_vga_resync no deriva nunca y
# todas las lineas duran lo mismo. El reloj de pixel queda en 25,205 MHz
# (+0,12 %): 31,51 kHz / 59,97 Hz.
set fi [open ../Falcon_MiSTer/rtl/falcon/falcon_videl.sv r]
set src [read $fi]
close $fi
set n 0
incr n [regsub {localparam \[31:0\] F25 = 32'd25175000;} $src {localparam [31:0] F25 = 32'd48;   // Poseidon: clk_pix/clk_sys = 48/61} src]
incr n [regsub {localparam \[31:0\] F32 = 32'd32000000;} $src {localparam [31:0] F32 = 32'd61;} src]
incr n [regsub {localparam \[31:0\] FCLK = CLK_HZ;} $src {localparam [31:0] FCLK = 32'd61;} src]
if {$n != 3} { error "build_id.tcl: no se ha podido parchear falcon_videl.sv ($n de 3)" }
set fo [open rtl/falcon/falcon_videl.sv w]
puts -nonewline $fo $src
close $fo
