# Atari Falcon030 para Poseidon - restricciones de tiempos
#
# PLL principal (50 MHz):
#   clk[0]  32 MHz  clk_sys: CPU, chipset, DSP, user_io, video
#   clk[1]  96 MHz  clk_mem: controlador de la SDRAM
#   clk[2]  96 MHz  clk_rd: retrasado 7,2 ns, coge el dato leido en el pin
# SDRAM_CLK es clk_mem invertido (registro DDR del pin).
# Los tres salen del mismo PLL y en fase entera (96 = 3 x 32), asi que los
# cruces clk_sys <-> clk_mem se analizan como sincronos (10,4 ns).

create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
create_clock -name SPI_SCK  -period 41.666 [get_ports {SPI_SCK}]

derive_pll_clocks -create_base_clocks

set clk_sys {pll|altpll_component|auto_generated|pll1|clk[0]}
set clk_mem {pll|altpll_component|auto_generated|pll1|clk[1]}
set clk_rd  {pll|altpll_component|auto_generated|pll1|clk[2]}
# segundo PLL: reloj de pixel de los modos VGA (25,1736 MHz), sin relacion
# con los demas (falcon_vga_resync cruza con una FIFO de doble reloj y Gray)
set clk_pix {pll_vga|altpll_component|auto_generated|pll1|clk[0]}

# El reloj que ve la SDRAM, en la pata: clk_mem invertido (incluye el
# retardo del registro DDR)
create_generated_clock -name sdram_clk -source [get_pins "$clk_mem"] -invert [get_ports {SDRAM_CLK}]

derive_clock_uncertainty

set_clock_groups -asynchronous \
	-group [get_clocks {SPI_SCK}] \
	-group [get_clocks [list $clk_sys $clk_mem $clk_rd sdram_clk]] \
	-group [get_clocks $clk_pix]

# SDRAM (valores de una -7 a CAS 3: tAC 5,4, tOH 2,5, tIS 1,5, tIH 0,8,
# mas ~0,5 ns de pistas)
set_input_delay  -clock sdram_clk -max 6.0  [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min 2.5  [get_ports {SDRAM_DQ[*]}]
set_output_delay -clock sdram_clk -max 2.0  [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQM* SDRAM_n* SDRAM_CKE}]
set_output_delay -clock sdram_clk -min -0.8 [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQM* SDRAM_n* SDRAM_CKE}]

# El dato que la SDRAM saca tras un flanco de sdram_clk lo coge clk_rd dos
# flancos despues, no en el primero, y clk_mem lo toma 3,2 ns mas tarde
# (RD_LAT = 5 en falcon_sdram). Sin multiciclo de hold: con -setup 2 la
# comprobacion de hold ya queda en el flanco anterior al de captura.
set_multicycle_path -from [get_clocks sdram_clk] -to [get_clocks $clk_rd] -setup -end 2

# Pines lentos sin relacion con ningun reloj
set_false_path -to   [get_ports {LED VGA_* I2S_*}]
set_false_path -from [get_ports {CONF_DATA0 SPI_DI SPI_SS2 SPI_SS3}]
set_false_path -to   [get_ports {SPI_DO}]
