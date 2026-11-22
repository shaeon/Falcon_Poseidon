//============================================================================
// Atari Falcon030 para Poseidon (placa estilo MiST)
//
// Envoltorio de falcon_system (Falcon_MiSTer de apolkosnik, rama ap030) con
// los modulos de MiST: user_io, data_io y mist_video. Sustituye a Falcon.sv
// y al framework sys/ de MiSTer.
//
//   - Memoria: la DDR3 de MiSTer pasa a la SDRAM (falcon_sdram).
//   - Discos: 4 imagenes (Floppy A, Floppy B, IDE master, SCSI 0) por
//     falcon_sd_bridge.
//   - Sin FPU (FALCON_NO_FPU), sin persistencia de NVRAM y sin CD-ROM: en
//     MiSTer los tres dependen del ARM o del Main modificado.
//
// Port de Shaeon (Carlos Palmero).
//============================================================================

module falcon_mist_top
(
	input         CLOCK_50,

	output        LED,

	output  [5:0] VGA_R,
	output  [5:0] VGA_G,
	output  [5:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,

	input         SPI_SCK,
	inout         SPI_DO,
	input         SPI_DI,
	input         SPI_SS2,
	input         SPI_SS3,
	input         CONF_DATA0,

	output        I2S_BCK,
	output        I2S_LRCK,
	output        I2S_DATA,

	output [12:0] SDRAM_A,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nWE,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nCS,
	output  [1:0] SDRAM_BA,
	output        SDRAM_CLK,
	output        SDRAM_CKE
);

`include "build_id.v"

`ifdef BIG_OSD
localparam bit BIG_OSD = 1;
`else
localparam bit BIG_OSD = 0;
`endif

// Indices de data_io: 0 = FALCON.ROM, que el firmware carga solo al
// arrancar; 1 = "Load TOS"; 2 = cartucho. Imagenes: S0..S3.
localparam CONF_STR = {
	"FALCON;;",
	"F,IMGROM,Load TOS;",
	"F,STCIMGROM,Load Cartridge;",
	"S0U,ST ,Floppy A:;",
	"S1U,ST ,Floppy B:;",
	"S2U,VHDIMGHDF,IDE Master;",
	"S3U,VHDIMGHDF,SCSI 0;",
	"O12,Monitor,VGA,RGB,TV,Mono;",
	"O3,ST-RAM,14 MB,4 MB;",
	"O9,CPU,32 MHz turbo,Falcon 16 MHz;",
	"O45,Scanlines,Off,25%,50%,75%;",
	"T0,Reset;",
	"T7,Cold Reset;",
	"V,v",`BUILD_DATE
};

/////////////////  RELOJES  ////////////////////////
wire clk_sys;      // 32 MHz: CPU, chipset, DSP
wire clk_mem;      // 96 MHz: SDRAM
wire clk_sdr;      // 96 MHz desfasado: pata SDRAM_CLK
wire pll_locked;

pll pll
(
	.inclk0(CLOCK_50),
	.c0(clk_sys),
	.c1(clk_mem),
	.c2(clk_sdr),
	.locked(pll_locked)
);

// SDRAM_CLK sale por un registro DDR del propio pin, como las ordenes y
// los datos, para que los retardos vayan emparejados. La fase la da c2.
altddio_out #(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone IV GX"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
) sdramclk_ddr (
	.datain_h(1'b1),
	.datain_l(1'b0),
	.outclock(clk_sdr),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

/////////////////  USER_IO / DATA_IO  //////////////
wire [63:0] status;
wire  [1:0] buttons;
wire        scandoubler_disable, no_csync, ypbpr;
wire [31:0] joystick_0, joystick_1;
wire [63:0] rtc_mist;

wire        key_pressed, key_extended, key_strobe;
wire  [7:0] key_code;
wire  [8:0] mouse_x, mouse_y;
wire  [7:0] mouse_flags;
wire        mouse_strobe;

wire [31:0] m_lba;
wire  [3:0] m_rd, m_wr;
wire        m_ack;
wire  [8:0] m_buff_addr;
wire  [7:0] m_dout, m_din;
wire        m_dout_strobe;
wire  [3:0] m_img_mounted;
wire [63:0] img_size;

user_io #(
	.STRLEN($size(CONF_STR)>>3),
	.SD_IMAGES(4),
	.FEATURES(32'h0 | (BIG_OSD << 13))
) user_io (
	.clk_sys(clk_sys),
	.clk_sd(clk_sys),
	.SPI_SS_IO(CONF_DATA0),
	.SPI_CLK(SPI_SCK),
	.SPI_MOSI(SPI_DI),
	.SPI_MISO(SPI_DO),
	.conf_str(CONF_STR),
	.status(status),
	.buttons(buttons),
	.scandoubler_disable(scandoubler_disable),
	.ypbpr(ypbpr),
	.no_csync(no_csync),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.rtc(rtc_mist),
	.key_strobe(key_strobe),
	.key_pressed(key_pressed),
	.key_extended(key_extended),
	.key_code(key_code),
	.mouse_x(mouse_x),
	.mouse_y(mouse_y),
	.mouse_flags(mouse_flags),
	.mouse_strobe(mouse_strobe),
	.ps2_kbd_clk_i(1'b1),
	.ps2_kbd_data_i(1'b1),
	.ps2_mouse_clk_i(1'b1),
	.ps2_mouse_data_i(1'b1),
	.sd_lba(m_lba),
	.sd_rd(m_rd),
	.sd_wr(m_wr),
	.sd_ack(m_ack),
	.sd_ack_conf(),
	.sd_ack_x(),
	.sd_conf(1'b0),
	.sd_sdhc(1'b1),
	.sd_dout(m_dout),
	.sd_dout_strobe(m_dout_strobe),
	.sd_din(m_din),
	.sd_din_strobe(),
	.sd_buff_addr(m_buff_addr),
	.img_mounted(m_img_mounted),
	.img_size(img_size)
);

wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;

data_io data_io (
	.clk_sys(clk_sys),
	.SPI_SCK(SPI_SCK),
	.SPI_SS2(SPI_SS2),
	.SPI_SS4(1'b1),
	.SPI_DI(SPI_DI),
	.SPI_DO(SPI_DO),
	.clkref_n(1'b0),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout)
);

/////////////////  ENTRADAS AL FORMATO DE MISTER  ////
// ps2_key: {cambia, pulsada, extendida, codigo}
reg [10:0] ps2_key = 11'd0;
always @(posedge clk_sys)
	if (key_strobe) ps2_key <= {~ps2_key[10], key_pressed, key_extended, key_code};

// ps2_mouse: {cambia, dy, dx, flags}, los mismos bytes del PS/2
reg [24:0] ps2_mouse = 25'd0;
always @(posedge clk_sys)
	if (mouse_strobe) ps2_mouse <= {~ps2_mouse[24], mouse_y[7:0], mouse_x[7:0], mouse_flags};

// RTC: MiST da los mismos 64 bits (BCD) que MiSTer; el bit 64 cambia con
// cada dato nuevo
reg [64:0] rtc = 65'd0;
always @(posedge clk_sys)
	if (rtc_mist != rtc[63:0]) rtc <= {~rtc[64], rtc_mist};

/////////////////  RESET Y CARGA DE ROM  ////////////
// Igual que Falcon.sv: TOS en $E00000 (indices 0 y 1), cartucho en $FA0000
wire rom_download  = ioctl_download && (ioctl_index[5:0] <= 6'd1);
wire cart_download = ioctl_download && (ioctl_index[5:0] == 6'd2);
reg  rom_loaded = 0;
always @(posedge clk_sys) if (rom_download) rom_loaded <= 1;

// FIFO entre data_io y el cargador: data_io no espera (en MiSTer el
// cargador frena a hps_io con ioctl_wait), y una escritura en la SDRAM
// puede coincidir con una rafaga de video y un refresco
reg  [31:0] ld_fifo [0:15];       // {direccion, dato}
reg   [3:0] ld_wp = 4'd0, ld_rp = 4'd0;
wire        ld_empty = (ld_wp == ld_rp);
wire        ld_busy;
reg         ld_wr = 1'b0;
reg  [23:0] ld_addr;
reg   [7:0] ld_data;
wire [23:0] ld_in_addr = rom_download ? {5'b11100, ioctl_addr[18:0]} : {7'b1111101, ioctl_addr[16:0]};

always @(posedge clk_sys) begin
	ld_wr <= 1'b0;
	if (ioctl_wr && (rom_download || cart_download)) begin
		ld_fifo[ld_wp] <= {ld_in_addr, ioctl_dout};
		ld_wp <= ld_wp + 4'd1;
	end
	// falcon_memarb guarda el byte en ld_wr y baja ld_busy al tomarlo
	if (!ld_empty && !ld_busy && !ld_wr) begin
		{ld_addr, ld_data} <= ld_fifo[ld_rp];
		ld_rp <= ld_rp + 4'd1;
		ld_wr <= 1'b1;
	end
end
wire ld_pending = !ld_empty || ld_wr || ld_busy;

// La TOS en RAM (TOS 4.92) empieza con move #$2700,sr
reg [31:0] rom_head = 0;
always @(posedge clk_sys)
	if (rom_download && ioctl_wr && ioctl_addr < 27'd4)
		rom_head <= {rom_head[23:0], ioctl_dout};
wire ram_tos = (rom_head == 32'h46FC2700);

reg [7:0] por_cnt = 0;
wire      por = ~&por_cnt;
always @(posedge clk_sys) if (por && pll_locked) por_cnt <= por_cnt + 1'd1;

wire cold_reset = por | status[7] | rom_download;
wire reset      = cold_reset | status[0] | buttons[1] |
                  rom_download | cart_download | ld_pending | ~rom_loaded;

/////////////////  FALCON  ////////////////////////
wire  [7:0] r, g, b;
wire        hs, vs, hblank, vblank, ce_pix;
wire signed [15:0] audio_l, audio_r;
wire        fdd_led, hdd_led;

wire  [6:0] img_mounted;
wire [31:0] sd_lba [7];
wire  [6:0] sd_rd, sd_wr, sd_ack;
wire  [5:0] sd_blk_cnt [7];
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din [7];
wire        sd_buff_wr;

wire        DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
wire  [7:0] DDRAM_BURSTCNT, DDRAM_BE;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DOUT, DDRAM_DIN;

// monitor: el valor de $FF8006 (00 mono, 01 RGB, 10 VGA, 11 TV)
wire [1:0] monitor = status[2:1] == 2'd0 ? 2'b10 : status[2:1] == 2'd1 ? 2'b01 :
                     status[2:1] == 2'd2 ? 2'b11 : 2'b00;

falcon_system #(.CLK_HZ(32000000)) system
(
	.clk(clk_sys),
	.reset(reset),
	.cold_reset(cold_reset),
	.por(por),

	.ram_mb(status[3] ? 4'd4 : 4'd14),
	.ram_tos(ram_tos),
	.monitor(monitor),
	.cpu_turbo(~status[9]),
	.tstat_en(1'b0),

	.ld_wr(ld_wr),
	.ld_addr(ld_addr),
	.ld_data(ld_data),
	.ld_busy(ld_busy),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.joy0(joystick_0),
	.joy1(joystick_1),
	.ana0(16'd0),
	.ana1(16'd0),
	.rtc(rtc),
	.nv_init(1'b0), .nv_ready(), .nv_addr(6'd0),
	.nv_dout(), .nv_din(8'd0), .nv_wr(1'b0), .nv_changed(),

	.img_mounted(img_mounted),
	.img_readonly(1'b0),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.r(r), .g(g), .b(b),
	.hsync(hs), .vsync(vs), .hblank(hblank), .vblank(vblank), .ce_pix(ce_pix),

	.audio_l(audio_l),
	.audio_r(audio_r),

	.midi_rx(1'b1),
	.midi_tx(),
	.ser_rx(1'b1),
	.ser_tx(),

	.fdd_led(fdd_led),
	.hdd_led(hdd_led),

	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);

falcon_sd_bridge sd_bridge
(
	.clk(clk_sys),
	.reset(por),
	.c_lba(sd_lba),
	.c_rd(sd_rd),
	.c_wr(sd_wr),
	.c_blk_cnt(sd_blk_cnt),
	.c_ack(sd_ack),
	.c_buff_addr(sd_buff_addr),
	.c_buff_dout(sd_buff_dout),
	.c_buff_wr(sd_buff_wr),
	.c_buff_din(sd_buff_din),
	.c_img_mounted(img_mounted),
	.m_lba(m_lba),
	.m_rd(m_rd),
	.m_wr(m_wr),
	.m_ack(m_ack),
	.m_buff_addr(m_buff_addr),
	.m_dout(m_dout),
	.m_dout_strobe(m_dout_strobe),
	.m_din(m_din),
	.m_img_mounted(m_img_mounted)
);

/////////////////  SDRAM  /////////////////////////
falcon_sdram sdram
(
	.clk(clk_sys),
	.clk_mem(clk_mem),
	.init(~pll_locked),

	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),

	.SDRAM_A(SDRAM_A),
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_CKE(SDRAM_CKE)
);

/////////////////  VIDEO  /////////////////////////
// En VGA y monocromo el Videl ya da 31 kHz o mas (SM124: 71 Hz): va sin
// scandoubler y con H y V separadas. En RGB y TV (15 kHz) el scandoubler
// sigue la opcion del firmware.
wire native_hi = (monitor == 2'b10) || (monitor == 2'b00);
wire sd_off    = scandoubler_disable | native_hi;

mist_video #(
	.COLOR_DEPTH(6),
	.SD_HCNT_WIDTH(11),
	.USE_BLANKS(1'b1),
	.OUT_COLOR_DEPTH(6),
	.BIG_OSD(BIG_OSD)
) mist_video (
	.clk_sys(clk_sys),
	.SPI_SCK(SPI_SCK),
	.SPI_SS3(SPI_SS3),
	.SPI_DI(SPI_DI),
	.R(r[7:2]), .G(g[7:2]), .B(b[7:2]),
	.HBlank(hblank), .VBlank(vblank),
	.HSync(hs), .VSync(vs),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_VS(VGA_VS), .VGA_HS(VGA_HS),
	.ce_divider(3'd1),
	.scandoubler_disable(sd_off),
	.no_csync(no_csync | native_hi),
	.scanlines(status[5:4]),
	.ypbpr(ypbpr),
	.rotate(2'b00),
	.blend(1'b0)
);

/////////////////  AUDIO  /////////////////////////
i2s i2s (
	.reset(1'b0),
	.clk(clk_sys),
	.clk_rate(32'd32_000_000),
	.sclk(I2S_BCK),
	.lrclk(I2S_LRCK),
	.sdata(I2S_DATA),
	.left_chan(audio_l),
	.right_chan(audio_r)
);

// LED de la placa, activo a nivel bajo: disquete o disco duro
assign LED = ~(fdd_led | hdd_led);

endmodule
