//============================================================================
// Falcon030 para Poseidon - imagenes de disco de hps_io (MiSTer) sobre
// user_io (MiST)
//
// El Falcon de MiSTer usa siete ranuras de hps_io:
//   0 Floppy A, 1 Floppy B, 2 IDE master, 3 IDE slave, 4..6 SCSI 0..2
// El firmware de MiST admite cuatro imagenes. Se quedan:
//   MiST 0 -> 0 (Floppy A)   MiST 1 -> 1 (Floppy B)
//   MiST 2 -> 2 (IDE master) MiST 3 -> 4 (SCSI 0)
// Las ranuras sin imagen nunca se montan, asi que el core no las pide.
//
// Diferencias que se cubren aqui:
//   - hps_io lleva un sd_lba y un sd_ack por ranura; user_io, uno para todas.
//   - El SCSI pide varios bloques de una vez (sd_blk_cnt, hasta 32) y
//     sd_buff_addr lleva el bloque en los bits altos. MiST va bloque a
//     bloque: se piden uno detras de otro y se mantiene el ack del core
//     durante toda la peticion, con el numero de bloque en sd_buff_addr.
//   - Las lecturas de "ventana" del SCSI (LBA 0x7E....../0x7D......) las
//     resuelve en MiSTer el Main modificado. Aqui no hay quien las conteste:
//     se responden con un bloque de ceros (longitud 0 = "sin respuesta") y
//     el SCSI usa sus respuestas internas (INQUIRY, READ CAPACITY). Las
//     escrituras de ventana se dan por hechas sin datos.
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
	output wire  [6:0] c_img_mounted,

	// lado de user_io (MiST, 4 imagenes)
	output reg  [31:0] m_lba,
	output reg   [3:0] m_rd = 4'd0,
	output reg   [3:0] m_wr = 4'd0,
	input  wire        m_ack,
	input  wire  [8:0] m_buff_addr,
	input  wire  [7:0] m_dout,
	input  wire        m_dout_strobe,
	output wire  [7:0] m_din,
	input  wire  [3:0] m_img_mounted
);

// ranura del core para cada imagen de MiST
function automatic [2:0] slot_of(input [1:0] m);
	case (m)
		2'd0: slot_of = 3'd0;
		2'd1: slot_of = 3'd1;
		2'd2: slot_of = 3'd2;
		default: slot_of = 3'd4;
	endcase
endfunction

assign c_img_mounted = {2'b00, m_img_mounted[3], 1'b0, m_img_mounted[2:0]};

localparam [2:0] S_IDLE = 3'd0, S_REQ = 3'd1, S_XFER = 3'd2, S_NEXT = 3'd3,
                 S_FAKE = 3'd4, S_END = 3'd5;
reg  [2:0] st = S_IDLE;
reg  [1:0] mi;                    // imagen de MiST en curso
reg  [2:0] cs;                    // ranura del core en curso
reg        we;
reg  [5:0] nblk, blk;
reg [31:0] lba0;
reg        ack_d;

// bloque de ceros para las ventanas
reg  [8:0] f_addr;
reg        f_wr = 1'b0;
reg        f_ph;

wire       fake = (st == S_FAKE);
assign c_buff_addr = {blk[4:0], fake ? f_addr : m_buff_addr};
assign c_buff_dout = fake ? 8'h00 : m_dout;
assign c_buff_wr   = fake ? f_wr : (m_dout_strobe && st == S_XFER);
assign m_din       = c_buff_din[cs];

// peticion pendiente por imagen de MiST (prioridad a la mas baja)
wire [3:0] want = { c_rd[4] | c_wr[4], c_rd[2] | c_wr[2], c_rd[1] | c_wr[1], c_rd[0] | c_wr[0] };
wire [1:0] wsel = want[0] ? 2'd0 : want[1] ? 2'd1 : want[2] ? 2'd2 : 2'd3;
wire [2:0] wslot = slot_of(wsel);
wire [31:0] wlba = c_lba[wslot];
wire       wwin = (wslot == 3'd4) && (wlba[31:24] == 8'h7D || wlba[31:24] == 8'h7E);
reg  [2:0] end_cnt;

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
				st     <= c_wr[wslot] ? S_END : S_FAKE;
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

	// 512 ceros, uno cada dos ciclos, para cada bloque pedido
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
