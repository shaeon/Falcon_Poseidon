# Paso previo a la compilacion (se ejecuta en poseidon/):
#  - build_id.v con la fecha de compilacion (version del OSD)
#  - copia las tablas que el core de MiSTer lee con $readmemh, que las busca
#    con rutas relativas al proyecto (rtl/falcon/...)
set buildDate [clock format [clock seconds] -format %y%m%d]
set outputFile [open "build_id.v" "w"]
puts $outputFile "`define BUILD_DATE \"$buildDate\""
close $outputFile

file mkdir rtl/falcon
foreach f {falcon_optbl.mem falcon_psg_vol.mem} {
	file copy -force ../Falcon_MiSTer/rtl/falcon/$f rtl/falcon/$f
}
