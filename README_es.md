# Falcon030 para Poseidon

*[English version](README.md)*

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
| Discos: las 7 ranuras de hps_io sobre las 4 de user_io, y las respuestas del SCSI que en MiSTer da el Main (READ TOC, MODE SENSE) | `rtl/falcon_sd_bridge.sv` |
| FPU 68882 (en MiSTer la calcula el ARM) | `rtl/falcon_fpu_mbox.sv` + `rtl/fpu/` |
| Vídeo VGA con reloj de píxel uniforme (25,2 MHz, relación exacta con el sistema) | `rtl/falcon_vga_resync.sv` |
| OSD, teclado, ratón, joysticks, reloj, carga de ficheros | `rtl/falcon_mist_top.sv` + mist-modules |
| Proyecto de Quartus 17.0 | `poseidon/` |

Ocupación (Quartus 17.0): 124.646 LE de 149.760 (83 %) y el 46 % de la
memoria. El sistema va a 32,03 MHz, la SDRAM a 96,09 MHz (`SDRAM_CLK` es el
reloj del controlador invertido) y el píxel VGA a 25,205 MHz, los tres del
mismo VCO de 1537,5 MHz.

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
   | Floppy B / CD | B: (hasta 3 MB) o CD-ROM SCSI ID 2 (más de 3 MB) | `.ST`, `.ISO` |
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
imagen en una FIFO y la saca con un reloj de píxel de verdad. Ese reloj sale
del mismo VCO que el del sistema (VCO/61 = 25,205 MHz frente a VCO/48 =
32,03 MHz), y al compilar se cambia la relación del acumulador del Videl a
48/61 (`common/build_id.tcl`). Así la FIFO nunca deriva: todas las líneas
duran exactamente lo mismo y no hay que saltar ni repetir puntos (31,51 kHz,
59,97 Hz). Los modos con base de 32 MHz (RGB, TV, mono) no lo necesitan y
salen directos; el cambio entre los dos caminos es automático.

## Diferencias con la versión de MiSTer

- **4 imágenes en vez de 7.** El firmware de MiST admite 4 (`SD_IMAGES` en
  `idxfile.h`). Se han quedado Floppy A, Floppy B o CD-ROM, IDE master y SCSI 0;
  no hay IDE slave ni SCSI 1. La segunda entrada del OSD es el disquete B o el
  CD-ROM según el tamaño de la imagen: hasta 3 MB es un `.ST`; más, un `.ISO`
  (bloques de 2048 bytes) en el CD-ROM (SCSI ID 2), y la otra unidad se expulsa.
- **FPU 68882 en la FPGA.** En MiSTer la calcula un programa del ARM a través de
  un buzón en la DDR3; aquí `falcon_fpu_mbox` atiende ese buzón (que va por la
  SDRAM) con la FPU de `rtl/fpu` (proyecto aparte, `fpu68882`). El core no se
  modifica. Las operaciones básicas son exactas; las trascendentes, a 1–2 ulp.
  Es más lenta que la de MiSTer en las trascendentes (unos 1.400 ciclos, ~45 µs).
- **Respuestas del SCSI.** INQUIRY y READ CAPACITY las da el core. READ TOC (una
  pista de datos y el lead-out) y MODE SENSE (cabecera y descriptor de bloque)
  las da `falcon_sd_bridge`, que en MiSTer las pide al Main. No hay audio de CD
  (PLAY AUDIO se acepta sin hacer nada) ni READ SUB-CHANNEL, y las imágenes
  BIN/CUE no valen: solo `.ISO`.
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

`tb/` tiene bancos de pruebas para Icarus Verilog de los módulos propios:

```
iverilog -g2012 -o tb_sdram tb/tb_sdram.sv rtl/falcon_sdram.sv && vvp tb_sdram
iverilog -g2012 -o tb_sd tb/tb_sd_bridge.sv rtl/falcon_sd_bridge.sv && vvp tb_sd
iverilog -g2012 -o tb_vga tb/tb_vga_resync.sv rtl/falcon_vga_resync.sv && vvp tb_vga
cp rtl/fpu/*.hex . && iverilog -g2012 -Irtl/fpu -o tb_mbox tb/tb_fpu_mbox.sv rtl/falcon_fpu_mbox.sv rtl/fpu/fpu_*.sv && vvp tb_mbox
```

- `tb_sdram`: 6.000 lecturas de 1 y 4 palabras y escrituras con byte enables
  al azar contra un modelo de SDRAM (comprueba tRCD, bancos abiertos y
  refrescos).
- `tb_sd`: lecturas de varios bloques del SCSI, lecturas de ventana, escritura
  del IDE, lectura de la disquetera, montaje del CD (expulsa B), READ TOC en
  LBA y MSF, MODE SENSE y lecturas del CD contra un modelo de user_io.
- `tb_mbox`: el buzón de la FPU como lo usa el puente (accesos de 16 bits):
  firma, versión y latido, reset, FSAVE nulo e idle, FMOVE.X, FADD y FSIN.
- `tb_vga`: 640x480 VGA con el acumulador del Videl, con 1 y 2 puntos por
  píxel y la relación de relojes 48/61: todas las líneas salen con 800 puntos
  exactos, sin perder ni repetir píxeles.

## Créditos

- Core Falcon030 y AP68030: apolkosnik.
- mist-modules: MiST-devel, en la versión de teiram.
- Port a Poseidon y FPU 68882: Shaeon (Carlos Palmero).
- Gracias a **RetroWiki** y a su equipo FPGA-dev, en especial a Ron, que lo ha
  probado en su Poseidon.
- Gracias a [actsl.com](https://www.actsl.com) por los tokens de Claude con los
  que se ha hecho el port.

## Licencia

Cada submódulo conserva su licencia (AP68030: GPL v2). El código propio de este
repositorio se publica con la GPL v2 o posterior (`LICENSE`). Atari y Falcon030
son marcas de sus propietarios.

---

Desarrollado con la ayuda de Claude (Anthropic).
