//============================================================================
// Falcon030 para Poseidon - imagenes de disco de hps_io (MiSTer) sobre
// user_io (MiST)
//
// El Falcon de MiSTer usa siete ranuras de hps_io:
//   0 Floppy A, 1 Floppy B, 2 IDE master, 3 IDE slave, 4..6 SCSI ID 0..2
//   (ID 2 es el CD-ROM)
// El firmware de MiST admite cuatro imagenes. Se quedan:
//   MiST 0 -> 0 (Floppy A)
//   MiST 1 -> 1 (Floppy B) o 6 (CD-ROM, SCSI ID 2), segun el tamano de la
//             imagen al montarla: hasta 3 MB es un disquete (.ST), mas es un
//             CD (.ISO, bloques de 2048 bytes); la otra unidad se expulsa
//   MiST 2 -> 2 (IDE master)
//   MiST 3 -> 4 (SCSI ID 0)
//
// Diferencias que se cubren aqui:
//   - hps_io lleva un sd_lba y un sd_ack por ranura; user_io, uno para todas.
//   - El SCSI pide varios bloques de una vez (sd_blk_cnt, hasta 32) y
//     sd_buff_addr lleva el bloque en los bits altos. MiST va bloque a
//     bloque: se piden uno detras de otro y se mantiene el ack del core
//     durante toda la peticion, con el numero de bloque en sd_buff_addr.
//   - Las lecturas de "ventana" del SCSI (LBA 0x7E000000 | unidad<<20 |
//     flags<<16 | op<<8 | arg) las responde en MiSTer el Main modificado.
//     Aqui las responde este modulo (respuesta en el byte 0, longitud en
//     los bytes 510-511):
//       READ TOC (43), CD: una pista de datos (1, LBA 0) y el lead-out, en
//                 LBA o MSF; formato 0 (TOC) y 1 (sesion)
//       MODE SENSE(6) (1A) y (10) (5A): cabecera y descriptor de bloque
//                 (2048 bytes en el CD, 512 en los discos), sin paginas
//     El resto (INQUIRY, READ CAPACITY, READ SUB-CHANNEL...) va con longitud
//     0, "sin respuesta": el core usa las suyas o da CHECK CONDITION. Las
//     escrituras de ventana (0x7D..., MODE SELECT, PLAY AUDIO) se aceptan sin
//     datos.
//============================================================================
`default_nettype none

module falcon_sd_bridge (
	input  wire        clk,
	input  wire        reset,

	// lado del core (hps_io de MiSTer)
	input  wire [31:0] c_lba [7],
	input  wire  [6:0] c_rd,
	input  wire  [6:0] c_wr,
	input  wire  [5:0] c_blk_cnt [7],
	output reg   [6:0] c_ack = 7'd0,
	output wire [13:0] c_buff_addr,
	output wire  [7:0] c_buff_dout,
	output wire        c_buff_wr,
	input  wire  [7:0] c_buff_din [7],
	output reg   [6:0] c_img_mounted = 7'd0,
	output reg  [63:0] c_img_size,

	// lado de user_io (MiST, 4 imagenes)
	output reg  [31:0] m_lba,
	output reg   [3:0] m_rd = 4'd0,
	output reg   [3:0] m_wr = 4'd0,
	input  wire        m_ack,
	input  wire  [8:0] m_buff_addr,
	input  wire  [7:0] m_dout,
	input  wire        m_dout_strobe,
	output wire  [7:0] m_din,
	input  wire  [3:0] m_img_mounted,
	input  wire [63:0] m_img_size
);

//---------------------------------------------------------------------------
// Montaje: Floppy B o CD-ROM en la imagen 1 de MiST
//---------------------------------------------------------------------------
reg        cd1 = 1'b0;              // la imagen 1 es el CD
reg [21:0] cd_blocks = 22'd0;       // bloques de 2048 bytes del CD
reg  [6:0] lo_m, lo_s, lo_f;        // lead-out en MSF
reg  [1:0] mnt_ph = 2'd0;
reg [63:0] mnt_size;
reg        mnt_cd;
reg [21:0] msf_v;                   // cuenta del MSF del lead-out
reg        msf_run = 1'b0;

function automatic [2:0] slot_of(input [1:0] m);
	case (m)
		2'd0: slot_of = 3'd0;
		2'd1: slot_of = cd1 ? 3'd6 : 3'd1;
		2'd2: slot_of = 3'd2;
		default: slot_of = 3'd4;
	endcase
endfunction

always @(posedge clk) begin
	c_img_mounted <= 7'd0;
	c_img_size    <= m_img_size;
	case (mnt_ph)
	2'd0: begin
		// las imagenes 0, 2 y 3 pasan tal cual
		c_img_mounted[0] <= m_img_mounted[0];
		c_img_mounted[2] <= m_img_mounted[2];
		c_img_mounted[4] <= m_img_mounted[3];
		if (m_img_mounted[1]) begin
			mnt_size <= m_img_size;
			mnt_cd   <= (m_img_size > 64'd3_145_728);
			mnt_ph   <= 2'd1;
		end
	end
	// primero se expulsa la otra unidad (tamano 0) ...
	2'd1: begin
		c_img_size <= 64'd0;
		if (mnt_cd) c_img_mounted[1] <= 1'b1; else c_img_mounted[6] <= 1'b1;
		mnt_ph <= 2'd2;
	end
	// ... y luego se monta la que toca
	2'd2: begin
		c_img_size <= mnt_size;
		if (mnt_cd) c_img_mounted[6] <= 1'b1; else c_img_mounted[1] <= 1'b1;
		cd1 <= mnt_cd;
		if (mnt_cd) begin
			cd_blocks <= mnt_size[32:11];
			msf_v     <= mnt_size[32:11] + 22'd150;
			lo_m <= 7'd0; lo_s <= 7'd0;
			msf_run   <= 1'b1;
		end
		mnt_ph <= 2'd0;
	end
	default: mnt_ph <= 2'd0;
	endcase

	// MSF del lead-out: minutos de 4500 sectores, segundos de 75
	if (msf_run && mnt_ph == 2'd0) begin
		if (msf_v >= 22'd4500) begin msf_v <= msf_v - 22'd4500; lo_m <= lo_m + 7'd1; end
		else if (msf_v >= 22'd75) begin msf_v <= msf_v - 22'd75; lo_s <= lo_s + 7'd1; end
		else begin lo_f <= msf_v[6:0]; msf_run <= 1'b0; end
	end
end

//---------------------------------------------------------------------------
// Transferencias
//---------------------------------------------------------------------------
localparam [2:0] S_IDLE = 3'd0, S_REQ = 3'd1, S_XFER = 3'd2, S_NEXT = 3'd3,
                 S_FAKE = 3'd4, S_END = 3'd5;
reg  [2:0] st = S_IDLE;
reg  [1:0] mi;                    // imagen de MiST en curso
reg  [2:0] cs;                    // ranura del core en curso
reg        we;
reg  [5:0] nblk, blk;
reg [31:0] lba0;
reg        ack_d;

// respuesta de ventana: 20 bytes y su longitud
reg  [8:0] f_addr;
reg        f_wr = 1'b0;
reg        f_ph;
reg [159:0] resp;
reg  [7:0] rlen;
wire [7:0] f_byte = (f_addr < 9'd20) ? resp[159 - 8 * f_addr[4:0] -: 8] :
                    (f_addr == 9'd511) ? rlen : 8'h00;

wire       fake = (st == S_FAKE);
assign c_buff_addr = {blk[4:0], fake ? f_addr : m_buff_addr};
assign c_buff_dout = fake ? f_byte : m_dout;
assign c_buff_wr   = fake ? f_wr : (m_dout_strobe && st == S_XFER);
assign m_din       = c_buff_din[cs];

// peticion pendiente por imagen de MiST (prioridad a la mas baja)
wire [2:0] s1 = cd1 ? 3'd6 : 3'd1;
wire [3:0] want = { c_rd[4] | c_wr[4], c_rd[2] | c_wr[2], c_rd[s1] | c_wr[s1], c_rd[0] | c_wr[0] };
wire [1:0] wsel = want[0] ? 2'd0 : want[1] ? 2'd1 : want[2] ? 2'd2 : 2'd3;
wire [2:0] wslot = slot_of(wsel);
wire [31:0] wlba = c_lba[wslot];
wire       wwin = (wslot == 3'd4 || wslot == 3'd6) && (wlba[31:24] == 8'h7D || wlba[31:24] == 8'h7E);
reg  [2:0] end_cnt;

// respuestas de ventana
wire [7:0] w_op   = wlba[15:8];
wire [3:0] w_fl   = wlba[19:16];
wire [7:0] w_arg  = wlba[7:0];
wire       w_cd   = (wslot == 3'd6);
wire [31:0] lo_lba = {10'd0, cd_blocks};
wire [31:0] lo_msf = {8'd0, 1'b0, lo_m, 1'b0, lo_s, 1'b0, lo_f};
wire [31:0] lo_adr = w_fl[0] ? lo_msf : lo_lba;
wire [31:0] t1_adr = w_fl[0] ? 32'h0000_0200 : 32'd0;     // pista 1: LBA 0 = 00:02:00
wire [7:0] wp     = w_cd ? 8'h80 : 8'h00;                  // el CD es de solo lectura
wire [23:0] blen  = w_cd ? 24'd2048 : 24'd512;

always @(posedge clk) begin
	ack_d <= m_ack;
	f_wr  <= 1'b0;

	if (reset) begin
		st    <= S_IDLE;
		c_ack <= 7'd0;
		m_rd  <= 4'd0;
		m_wr  <= 4'd0;
	end else case (st)

	S_IDLE:
		if (|want) begin
			mi   <= wsel;
			cs   <= wslot;
			we   <= c_wr[wslot];
			nblk <= c_blk_cnt[wslot];
			blk  <= 6'd0;
			lba0 <= wlba;
			end_cnt <= 3'd0;
			// hps_io: el ack sube al empezar y el core suelta rd/wr al verlo
			c_ack[wslot] <= 1'b1;
			if (wwin) begin
				f_addr <= 9'd0;
				f_ph   <= 1'b0;
				resp   <= 160'd0;
				rlen   <= 8'd0;
				if (w_op == 8'h43 && w_cd && w_fl[2:1] == 2'd0 && w_arg <= 8'd1) begin
					// TOC: pista 1 y lead-out
					resp <= {16'd18, 8'd1, 8'd1,
					         8'd0, 8'h14, 8'd1, 8'd0, t1_adr,
					         8'd0, 8'h14, 8'hAA, 8'd0, lo_adr};
					rlen <= 8'd20;
				end else if (w_op == 8'h43 && w_cd && w_fl[2:1] == 2'd0) begin
					// TOC desde una pista posterior: solo el lead-out
					resp <= {16'd10, 8'd1, 8'd1,
					         8'd0, 8'h14, 8'hAA, 8'd0, lo_adr, 64'd0};
					rlen <= 8'd12;
				end else if (w_op == 8'h43 && w_cd && w_fl[2:1] == 2'd1) begin
					// informacion de sesion: una sesion, empieza en la pista 1
					resp <= {16'd10, 8'd1, 8'd1,
					         8'd0, 8'h14, 8'd1, 8'd0, t1_adr, 64'd0};
					rlen <= 8'd12;
				end else if (w_op == 8'h1A) begin
					// MODE SENSE(6): cabecera (4) y, sin DBD, un descriptor (8)
					if (w_fl[0]) begin resp <= {8'd3, 8'd0, wp, 8'd0, 128'd0}; rlen <= 8'd4; end
					else begin
						resp <= {8'd11, 8'd0, wp, 8'd8, 32'd0, 8'd0, blen, 64'd0};
						rlen <= 8'd12;
					end
				end else if (w_op == 8'h5A) begin
					// MODE SENSE(10): cabecera (8) y, sin DBD, un descriptor (8)
					if (w_fl[0]) begin resp <= {16'd6, 8'd0, wp, 32'd0, 96'd0}; rlen <= 8'd8; end
					else begin
						resp <= {16'd14, 8'd0, wp, 16'd0, 16'd8, 32'd0, 8'd0, blen, 32'd0};
						rlen <= 8'd16;
					end
				end
				st <= c_wr[wslot] ? S_END : S_FAKE;
			end else
				st <= S_REQ;
		end

	// pide un bloque a user_io y espera a que empiece
	S_REQ: begin
		m_lba <= lba0 + {26'd0, blk};
		if (we) m_wr[mi] <= 1'b1; else m_rd[mi] <= 1'b1;
		if (m_ack && !ack_d) begin
			m_rd <= 4'd0;
			m_wr <= 4'd0;
			st   <= S_XFER;
		end
	end

	// los bytes pasan tal cual; el bloque acaba cuando baja el ack
	S_XFER:
		if (!m_ack && ack_d) st <= S_NEXT;

	S_NEXT:
		if (blk == nblk) st <= S_END;
		else begin
			blk <= blk + 6'd1;
			st  <= S_REQ;
		end

	// el bloque de respuesta (512 bytes, uno cada dos ciclos)
	S_FAKE: begin
		f_ph <= ~f_ph;
		if (f_ph) f_wr <= 1'b1;
		if (f_wr) begin
			f_addr <= f_addr + 9'd1;
			if (f_addr == 9'd511) begin
				if (blk == nblk) st <= S_END;
				else blk <= blk + 6'd1;
			end
		end
	end

	// el ack del core se mantiene unos ciclos aunque no haya habido datos
	S_END: begin
		end_cnt <= end_cnt + 3'd1;
		if (&end_cnt) begin
			c_ack <= 7'd0;
			st    <= S_IDLE;
		end
	end

	default: st <= S_IDLE;
	endcase
end

endmodule

`default_nettype wire
