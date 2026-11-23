# Falcon030 for Poseidon

*[Versión en español](README_es.md)*

Port of the MiSTer **Atari Falcon030** core
([apolkosnik/Falcon_MiSTer](https://github.com/apolkosnik/Falcon_MiSTer), branch
`ap030`, with the [AP68030](https://github.com/apolkosnik/AP68030) 68030) to the
**Poseidon** board (Cyclone IV GX EP4CGX150), which works like a MiST.

The MiSTer core is a submodule and is **not modified**: this repository only
adds what replaces the MiSTer `sys/` framework.

## Contents

| Part | Where |
|------|-------|
| 68030, Videl, DSP56001, blitter, MFP, YM2149, IDE, SCSI, floppy… | `Falcon_MiSTer/` (unchanged) |
| Memory: MiSTer's DDR3 mapped onto the 32 MB SDRAM | `rtl/falcon_sdram.sv` |
| Disks: the 7 hps_io slots on the 4 user_io slots, plus the SCSI replies that the MiSTer Main gives (READ TOC, MODE SENSE) | `rtl/falcon_sd_bridge.sv` |
| 68882 FPU (on MiSTer it is computed by the ARM) | `rtl/falcon_fpu_mbox.sv` + `rtl/fpu/` |
| VGA video with an even pixel clock (25.2 MHz, exact ratio to the system clock) | `rtl/falcon_vga_resync.sv` |
| OSD, keyboard, mouse, joysticks, RTC, file loading | `rtl/falcon_mist_top.sv` + mist-modules |
| Quartus 17.0 project | `poseidon/` |

Resources (Quartus 17.0): 124,646 LE of 149,760 (83 %) and 46 % of the memory
bits. The system runs at 32.03 MHz, the SDRAM at 96.09 MHz (`SDRAM_CLK` is the
controller clock inverted) and the VGA pixel clock at 25.205 MHz, all three
from the same 1537.5 MHz VCO.

## Usage

1. Copy the `.rbf` to the SD card.
2. TOS: a 512 KB TOS 4.0x or EmuTOS image in the root of the SD card named
   `FALCON.ROM` (loaded when the core starts), or load it from the OSD with
   "Load TOS". EmuTOS (`etos512*.img`) is free and boots from IDE and SCSI
   without a driver.
3. Disks from the OSD:

   | OSD entry | Falcon drive | Formats |
   |-----------|--------------|---------|
   | Floppy A | A: | `.ST` |
   | Floppy B / CD | B: (up to 3 MB) or SCSI CD-ROM ID 2 (over 3 MB) | `.ST`, `.ISO` |
   | IDE Master | IDE 0 | `.VHD`, `.IMG`, `.HDF` |
   | SCSI 0 | SCSI ID 0 | `.VHD`, `.IMG`, `.HDF` |

   The CD-ROM needs a TOS driver such as ExtenDOS or SPIN!.

4. Monitor: the "Monitor" option (VGA, RGB, TV, mono) is what TOS reads at
   `$FF8006`. VGA and mono come out as they are (31 kHz or more); RGB and TV
   (15 kHz) go through the scandoubler unless it is disabled in the firmware.
   Without a TOS loaded the core shows a black screen with the OSD, so you can
   load one.

### VGA video

The Videl counts VGA dots at 25.175 MHz with an accumulator on the 32 MHz
system clock, so every dot lasts 1 or 2 cycles (31 or 62 ns). On MiSTer the
scaler hides it; here `falcon_vga_resync` writes the picture into a FIFO and
reads it with a real pixel clock. That clock comes from the same VCO as the
system clock (VCO/61 = 25.205 MHz against VCO/48 = 32.03 MHz), and at build
time the Videl accumulator ratio is changed to 48/61 (`common/build_id.tcl`).
The FIFO never drifts: every line has exactly the same length and no dot is
skipped or repeated (31.51 kHz, 59.97 Hz). Modes based on 32 MHz (RGB, TV,
mono) don't need it and go out directly; switching between the two paths is
automatic.

## Differences from the MiSTer version

- **4 images instead of 7.** The MiST firmware supports 4 (`SD_IMAGES` in
  `idxfile.h`): Floppy A, Floppy B or CD-ROM, IDE master and SCSI 0; there is
  no IDE slave or SCSI 1. The second OSD entry is floppy B or the CD-ROM
  depending on the image size: up to 3 MB it is a `.ST`; larger, an `.ISO`
  (2048-byte blocks) on the CD-ROM (SCSI ID 2), and the other drive is ejected.
- **68882 FPU in the FPGA.** On MiSTer an ARM program computes it through a
  mailbox in DDR3; here `falcon_fpu_mbox` serves that mailbox (which lives in
  SDRAM) with the FPU in `rtl/fpu` (a separate project, `fpu68882`). The core
  is not modified. Basic operations are exact; transcendentals are within
  1–2 ulp and slower than on MiSTer (about 1,400 cycles, ~45 µs).
- **SCSI replies.** INQUIRY and READ CAPACITY come from the core. READ TOC (one
  data track plus lead-out) and MODE SENSE (header and block descriptor) come
  from `falcon_sd_bridge`; on MiSTer the Main answers them. There is no CD
  audio (PLAY AUDIO is accepted and ignored) and no READ SUB-CHANNEL, and
  BIN/CUE images don't work: `.ISO` only.
- **NVRAM is not saved.** It goes back to the defaults at every boot.
- No serial port or MIDI (the Poseidon has no pins for them).

## Building

With Quartus Prime Lite 17.0:

```
git submodule update --init --recursive
cd poseidon
quartus_sh --flow compile falcon_poseidon
```

or open `poseidon/falcon_poseidon.qpf` in the GUI. The pre-flow script
(`common/build_id.tcl`) writes `build_id.v`, copies the FPU ROMs and the `.mem`
tables the core reads with `$readmemh`, and generates the patched
`poseidon/rtl/falcon/falcon_videl.sv`.

GitHub Actions builds the core on every push (`.github/workflows/build.yml`,
Quartus 17.0 in Docker, Node.js 24 actions, not as root) and leaves the `.rbf`
in the Actions tab; a `v*` tag also creates a Release with the `.rbf`.

## Tests

`tb/` has Icarus Verilog testbenches for the modules of this repository:

```
iverilog -g2012 -o tb_sdram tb/tb_sdram.sv rtl/falcon_sdram.sv && vvp tb_sdram
iverilog -g2012 -o tb_sd tb/tb_sd_bridge.sv rtl/falcon_sd_bridge.sv && vvp tb_sd
iverilog -g2012 -o tb_vga tb/tb_vga_resync.sv rtl/falcon_vga_resync.sv && vvp tb_vga
cp rtl/fpu/*.hex . && iverilog -g2012 -Irtl/fpu -o tb_mbox tb/tb_fpu_mbox.sv rtl/falcon_fpu_mbox.sv rtl/fpu/fpu_*.sv && vvp tb_mbox
```

- `tb_sdram`: 6,000 random 1- and 4-word reads and byte-enable writes against
  an SDRAM model (checks tRCD, open banks and refresh).
- `tb_sd`: multi-block SCSI reads, window reads, IDE writes, floppy reads, CD
  mount (ejects B), READ TOC in LBA and MSF, MODE SENSE and CD reads against a
  user_io model.
- `tb_mbox`: the FPU mailbox as the bridge uses it (16-bit accesses):
  signature, version and heartbeat, reset, null and idle FSAVE, FMOVE.X, FADD
  and FSIN.
- `tb_vga`: 640x480 VGA with the Videl accumulator, 1 and 2 dots per pixel and
  the 48/61 clock ratio: every line is exactly 800 dots, no pixel lost or
  repeated.

## Credits

- Falcon030 core and AP68030: apolkosnik.
- mist-modules: MiST-devel, teiram's version.
- Poseidon port and 68882 FPU: Shaeon (Carlos Palmero).
- Thanks to **RetroWiki** and its FPGA-dev team, especially Ron, who tested it
  on his Poseidon.
- Thanks to [actsl.com](https://www.actsl.com) for the Claude tokens used to
  make this port.

## Licence

Each submodule keeps its own licence (AP68030: GPL v2). The code of this
repository is released under the GPL v2 or later (`LICENSE`). Atari and
Falcon030 are trademarks of their respective owners.

---

Developed with the help of Claude (Anthropic).
