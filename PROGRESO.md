# Port del Falcon030 a la Poseidon — progreso

Core de origen: apolkosnik/Falcon_MiSTer, rama `ap030` (submódulo `Falcon_MiSTer/`,
sin modificar). Placa: Poseidon, EP4CGX150DF27I7, Quartus 17.0.

## Decisiones

- El core de MiSTer no se toca: todo lo propio va en `rtl/` y `poseidon/`.
- Memoria: `rtl/falcon_sdram.sv` hace de puerto DDR3 de MiSTer (palabras de
  64 bits, ráfagas de 1 o 4) sobre la SDRAM de 16 bits. SDRAM a 96 MHz
  (3 × clk_sys de 32 MHz, mismo PLL), CAS 3, ráfaga de 4, autoprecarga.
- Discos: el firmware MiST admite 4 imágenes. Se quedan Floppy A (S0),
  Floppy B (S1), IDE master (S2) y SCSI 0 (S3). `rtl/falcon_sd_bridge.sv`
  traduce las 7 ranuras de hps_io a las 4 de user_io, parte las peticiones de
  varios bloques del SCSI en bloques sueltos y contesta él mismo (con ceros)
  a las lecturas de "ventana" del SCSI (LBA 0x7E/0x7D…), que en MiSTer
  resuelve el Main: así el SCSI usa sus respuestas internas.
- Sin FPU (macro FALCON_NO_FPU: en MiSTer la calcula el ARM).
- Sin persistencia de NVRAM (falcon_nvram_store no se instancia: valores por
  defecto en cada arranque).
- Sin CD-ROM (necesita el Main modificado de MiSTer).
- TOS: `FALCON.ROM` en la SD (índice 0, se carga al arrancar) o "Load TOS".

## Prueba en placa 1 (Ron, 20261122)

- Pantalla negra al principio: era la ROM (con una TOS buena arranca hasta
  el escritorio, con disquetes y disco duro).
- Aun asi se cambia: el Falcon tiene el Videl en reset hasta que hay TOS
  (~rom_loaded) y en reset no da sincronismos; en MiST el OSD se pinta sobre
  el video del core. Ahora sale una imagen negra de respaldo (31,25 kHz /
  59,5 Hz) con OSD mientras la maquina esta en reset: sin TOS se puede
  cargar desde el OSD.
- Video VGA "un poco raro" (31,48 kHz / 59,94 Hz, columnas irregulares): el
  Videl saca los 25,175 MHz con un acumulador sobre 32 MHz, cada punto dura
  1 o 2 ciclos. Nuevo rtl/falcon_vga_resync.sv: FIFO escrita con ce_pix y
  leida con un reloj de pixel de verdad (pll_vga, 25,1736 MHz), con
  correccion de deriva en el borrado horizontal; salida por una segunda
  instancia de mist_video. Cambio automatico midiendo ciclos por pixel.
  tb/tb_vga_resync.sv: lineas de 800 puntos (+-1 al corregir), sin perder ni
  repetir pixeles, con 1 y 2 puntos por pixel.
- SDRAM_CLK pasa a clk_mem invertido (preferencia del usuario para todos los
  cores). Para no perder margen de hold, las lecturas se cogen en el pin con
  clk_rd (c2, 7200 ps) y pasan a clk_mem 3,2 ns despues.

## FPU y CD-ROM (20261123)

- FPU 68882 propia (proyecto aparte /fpu68882, copia en rtl/fpu): 13.455 LE
  sola, 41,8 MHz; basicas exactas, trascendentes a 1-2 ulp.
- rtl/falcon_fpu_mbox.sv: entre falcon_system y falcon_sdram atiende el buzon
  del puente ($E90000, docs/FPU_ARM.md del core) como el programa del ARM.
  Sin FALCON_NO_FPU. tb/tb_fpu_mbox.sv: firma, version, latido, reset, FSAVE
  nulo/idle, FMOVE.X, FADD, FSIN.
- CD-ROM: el firmware de MiST solo admite 4 imagenes (SD_IMAGES 4 en
  idxfile.h), asi que no hay quinta unidad: la imagen 1 es Floppy B (<= 3 MB)
  o el CD-ROM SCSI ID 2 (> 3 MB, .ISO), y la otra se expulsa. READ TOC y
  MODE SENSE los responde falcon_sd_bridge (en MiSTer, el Main).
  tb/tb_sd_bridge.sv amplia: montaje, TOC LBA/MSF, MODE SENSE, lectura.
- La primera sintesis dio 145.677 LE: la memoria del buzon se hizo con
  registros. Ahora va en 8 carriles de 8 bits (M9K).

## Prueba en placa 2 (Ron, 20261123): la imagen VGA tiembla; en baja se pierde

- Causa: clk_pix era 25,1736 MHz (55 ppm por debajo del Videl) y la FIFO
  corregia saltando o repitiendo un punto cada ~30 lineas, tambien en la zona
  visible: lineas de longitud distinta. En baja (2 puntos por pixel) el salto
  es de 2 puntos y el monitor pierde el enganche.
- Arreglo (como en el FP-1100 y el NewBrain: relojes de relacion exacta
  sacados del mismo VCO): el PLL principal ya iba a VCO 1537,5 MHz (50x123/4;
  32/96 exactos no salen con PFD >= 5 MHz), clk_sys = VCO/48 = 32,03 MHz.
  clk_pix = VCO/61 = 25,205 MHz (salida c3) y el acumulador del Videl se
  parchea a 48/61 en common/build_id.tcl (genera poseidon/rtl/falcon/
  falcon_videl.sv a partir del submodulo). VGA a 31,51 kHz / 59,97 Hz.
  Sin correcciones: tb_vga_resync da 800 puntos en todas las lineas.
- Probado y descartado: dos PLL en cascada para 1007/1280 exacto (Quartus no
  consigue el x53 y lo aproxima a 48/29).
- Compilacion con FPU + CD + clk_pix nuevo (fp9, semilla 2): 124.646 LE
  (83 %); releases/Falcon_poseidon_20261123b.rbf. clk_sys -0,251 ns solo en
  el modelo lento de 85 C (2 rutas: RAM externa del DSP -> cpubus d_i), con
  +2,38 ns a 0 C; el resto de relojes cumple. Pendiente: otra semilla para
  dejarlo limpio.
- Compilacion con FPU + CD + reloj anterior (fp8): 125.201 LE (84 %),
  tiempos cumplidos en todos los relojes.

## Comprobado

- [x] Compilacion 20261123 (video VGA nuevo, SDRAM_CLK invertido, clk_rd
      7200 ps, semilla 2, 0-85 C como el resto de proyectos de la Poseidon):
      100.099 LE (67 %), 391 M9K (54 %), sin holguras negativas. clk_sys
      +0,278 ns (85 C), hold peor +0,071 ns. SDRAM: lectura setup >= 1,6 /
      hold >= 2,3 ns; ordenes setup >= 2,7 / hold >= 4,2 ns.
      releases/Falcon_poseidon_20261123.rbf (Quartus 17.0.2).
      Con la semilla 1 el reloj del sistema fallaba por 0,32 ns (100 C) en la
      lectura de la RAM externa del DSP: el core va justo a 32 MHz en esta
      FPGA; si una compilacion futura no cierra, probar otras semillas.

### Historial

- [x] Recursos: el core solo (sin sys/) en la EP4CGX150: 99.124 LE (66 %),
      372 M9K (52 %), 32 MHz con +0,78 ns de holgura (camino peor en la RAM
      externa del DSP).
- [x] rtl/falcon_sdram.sv: tb/tb_sdram.sv, 6.000 operaciones al azar sin
      errores (modelo de SDRAM con comprobación de tRCD, bancos y refresco).
- [x] rtl/falcon_sd_bridge.sv: tb/tb_sd_bridge.sv sin errores (SCSI de 3
      bloques, ventana, escritura IDE, disquete B).
- [x] Compilación completa (fase de SDRAM_CLK 6510 ps): 99.289 LE (66 %),
      386 M9K (54 %), sin holguras negativas en ninguna esquina (setup peor
      +0,445 ns en clk_sys, hold peor +0,075 ns). RBF generado.
- [x] Rutas de la SDRAM (tools/rutas_sdram.tcl): con 6510 ps la lectura iba
      con 3,3 ns de setup y 0,46 ns de hold (modelo rápido) → fase a 7700 ps.
- [x] Compilación con 7700 ps: mismas cifras del core; SDRAM en el peor modelo:
      lectura setup +2,0 / hold +1,76 ns, órdenes setup +4,4 / hold +1,8 ns.
      releases/Falcon_poseidon_20261122.rbf (Quartus 17.0.2).

## Pendiente

- [ ] Subir a GitHub (shaeon/Falcon_Poseidon) y comprobar el workflow
- [ ] Prueba en la placa (la hace el usuario): arranque con EmuTOS/TOS 4.04,
      disquete, IDE, SCSI, teclado, ratón, vídeo en VGA/RGB
- [ ] Si la SDRAM falla en la placa: ajustar la fase de c2 en poseidon/pll.v
      (o RD_LAT en falcon_sdram)
- [ ] FPU 68882 en la FPGA (en MiSTer la calcula el ARM): el puente ya
      existe, faltaria la unidad aritmetica de 80 bits; hay sitio (~50k LE)
- [ ] Probar en la placa: deteccion de la FPU (EmuTOS/TOS: _FPU), FPUTEST.TOS
      del core (tools/fputest), CD con un driver SCSI (ExtenDOS, SPIN!)
- [ ] Quinta imagen real: cambiar SD_IMAGES en el firmware (mist-firmware /
      calypso-firmware) y user_io.v
- [ ] Mejoras posibles: guardar la NVRAM (data_io tiene subida), más discos si
      el firmware lo permite

## Dudas a confirmar en la placa

- Geometría de la SDRAM de la Poseidon: se supone 32 MB (13 filas, 9 columnas).
  Parámetro COL_BITS en falcon_sdram.
- Fase del reloj de la SDRAM / latencia de lectura (parámetro RD_LAT).
