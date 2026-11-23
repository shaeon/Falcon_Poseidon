# Falcon030 para Poseidon

Port del core **Atari Falcon030** de MiSTer
([apolkosnik/Falcon_MiSTer](https://github.com/apolkosnik/Falcon_MiSTer), rama
`ap030`, con el 68030 [AP68030](https://github.com/apolkosnik/AP68030)) a la
placa **Poseidon** (Cyclone IV GX EP4CGX150), que funciona como un MiST.

El core de MiSTer va como submódulo y **no se modifica**: este repositorio solo
añade lo que sustituye al framework `sys/` de MiSTer.

## Qué lleva

| Parte | De dónde |
|-------|----------|
| 68030, Videl, DSP56001, blitter, MFP, YM2149, IDE, SCSI, disquetera… | `Falcon_MiSTer/` (sin cambios) |
| Memoria: la DDR3 de MiSTer sobre la SDRAM de 32 MB | `rtl/falcon_sdram.sv` |
| Discos: las 7 ranuras de hps_io sobre las 4 de user_io | `rtl/falcon_sd_bridge.sv` |
| Vídeo VGA con reloj de píxel uniforme (25,17 MHz) | `rtl/falcon_vga_resync.sv` |
| OSD, teclado, ratón, joysticks, reloj, carga de ficheros | `rtl/falcon_mist_top.sv` + mist-modules |
| Proyecto de Quartus 17.0 | `poseidon/` |

Ocupación (Quartus 17.0): unos 100.000 LE de 149.760 y la mitad de los M9K.
El sistema va a 32 MHz y la SDRAM a 96 MHz.

## Uso

1. Copia el `.rbf` a la SD.
2. TOS: una imagen de 512 KB de TOS 4.0x o de EmuTOS en la raíz de la SD con el
   nombre `FALCON.ROM` (se carga al arrancar el core), o cárgala desde el OSD
   con "Load TOS". EmuTOS (`etos512*.img`) es libre y arranca desde IDE y SCSI
   sin controlador.
3. Discos desde el OSD:

   | Entrada del OSD | Unidad del Falcon | Formatos |
   |-----------------|-------------------|----------|
   | Floppy A | A: | `.ST` |
   | Floppy B | B: | `.ST` |
   | IDE Master | IDE 0 | `.VHD`, `.IMG`, `.HDF` |
   | SCSI 0 | SCSI ID 0 | `.VHD`, `.IMG`, `.HDF` |

4. Monitor: la opción "Monitor" (VGA, RGB, TV, mono) es lo que ve el TOS en
   `$FF8006`. En VGA y mono la imagen sale tal cual (31 kHz o más); en RGB y TV
   (15 kHz) pasa por el scandoubler, salvo que esté desactivado en el
   firmware. Sin TOS cargada sale una imagen negra con el OSD, para poder
   cargarla.

### Vídeo VGA

El Videl cuenta los puntos de los modos VGA a 25,175 MHz con un acumulador
sobre los 32 MHz del sistema, así que cada punto dura 1 o 2 ciclos (31 o
62 ns). En MiSTer el escalador lo arregla; aquí `falcon_vga_resync` mete la
imagen en una FIFO y la saca con un reloj de píxel de verdad (25,1736 MHz, de
un segundo PLL). La diferencia con 25,175 MHz se corrige saltándose o
repitiendo un punto del borrado horizontal una vez cada unas 30 líneas. Los
modos con base de 32 MHz (RGB, TV, mono) no lo necesitan y salen directos;
el cambio entre los dos caminos es automático.

## Diferencias con la versión de MiSTer

- **4 discos en vez de 7.** El firmware de MiST admite 4 imágenes. Se han
  quedado Floppy A, Floppy B, IDE master y SCSI 0; no hay IDE slave, SCSI 1 ni
  CD-ROM.
- **Sin FPU 68882.** En MiSTer la calcula el ARM; aquí no hay dónde. El core se
  compila con `FALCON_NO_FPU` y el 68030 toma la excepción de línea F, como un
  Falcon sin coprocesador.
- **El SCSI usa sus respuestas internas.** En MiSTer, INQUIRY, READ CAPACITY,
  MODE SENSE y la tabla del CD los construye el Main modificado. Aquí
  `falcon_sd_bridge` responde "sin respuesta" a esas consultas y el core usa las
  suyas: INQUIRY y READ CAPACITY funcionan, y MODE SENSE contesta CHECK
  CONDITION (lo mismo que en MiSTer con un Main sin modificar).
- **La NVRAM no se guarda.** Vuelve a los valores por defecto en cada arranque.
- Sin puerto serie ni MIDI (la Poseidon no tiene pines para ellos).

## Compilar

Con Quartus Prime Lite 17.0:

```
cd poseidon
quartus_sh --flow compile falcon_poseidon
```

o desde la interfaz, abriendo `poseidon/falcon_poseidon.qpf`. Hace falta
descargar los submódulos antes:

```
git submodule update --init --recursive
```

El paso previo (`common/build_id.tcl`) genera `build_id.v` y copia a
`poseidon/rtl/falcon/` las tablas `.mem` que el core lee con `$readmemh`.

GitHub Actions compila el core en cada push (`.github/workflows/build.yml`) y
deja el `.rbf` en la pestaña Actions; con una etiqueta `v*` crea una Release.

## Pruebas

`tb/` tiene bancos de pruebas para Icarus Verilog de los dos módulos propios:

```
iverilog -g2012 -o tb_sdram tb/tb_sdram.sv rtl/falcon_sdram.sv && vvp tb_sdram
iverilog -g2012 -o tb_sd tb/tb_sd_bridge.sv rtl/falcon_sd_bridge.sv && vvp tb_sd
iverilog -g2012 -o tb_vga tb/tb_vga_resync.sv rtl/falcon_vga_resync.sv && vvp tb_vga
```

- `tb_sdram`: 6.000 lecturas de 1 y 4 palabras y escrituras con byte enables
  al azar contra un modelo de SDRAM (comprueba tRCD, bancos abiertos y
  refrescos).
- `tb_sd`: lecturas de varios bloques del SCSI, lecturas de ventana, escritura
  del IDE y lectura de la disquetera contra un modelo de user_io.
- `tb_vga`: 640x480 VGA con el acumulador del Videl, con 1 y 2 puntos por
  píxel: todas las líneas salen con 800 puntos (±1 al corregir la deriva) y
  sin perder ni repetir píxeles.

## Créditos

- Core Falcon030 y AP68030: apolkosnik.
- mist-modules: MiST-devel, en la versión de teiram.
- Port a Poseidon: Shaeon (Carlos Palmero).

El port se ha hecho con ayuda de Claude (Anthropic).
