//============================================================================
// fpu_top - FPU 68882 en la FPGA
//
// Atiende las mismas peticiones que el servicio falcon_fpu del ARM en
// Falcon_MiSTer (falcon_fpu_bridge.sv, buzon de docs/FPU_ARM.md):
//   KIND 1 ejecutar (cmd, aux = Dn, iaddr = direccion de la instruccion)
//   KIND 2 reset   KIND 3 condicion (cmd[5:0])   KIND 4 FSAVE   KIND 5 FRESTORE
// Los operandos llegan en el bufer de entrada (8 x 96 bits, alineados a la
// izquierda, big endian como en memoria) y los resultados salen en el de
// salida (FMOVE out, FMOVEM, control, marco de FSAVE).
//
// El calculo lo hace fpu_seq (microcodigo) con fpu_engine.
//============================================================================
`default_nettype none

module fpu_top (
	input  wire        clk,
	input  wire        reset,

	input  wire        req,
	input  wire  [2:0] kind,
	input  wire [15:0] cmd,
	input  wire [31:0] aux,
	input  wire [31:0] iaddr,
	input  wire        iaddr_valid,

	input  wire        ob_we,
	input  wire  [2:0] ob_wa,
	input  wire [95:0] ob_wd,
	input  wire  [2:0] rb_ra,
	output reg  [95:0] rb_rd,

	output reg         ack = 1'b0,
	output wire        busy,
	output reg  [31:0] fpcr = 32'd0,
	output reg  [31:0] fpsr = 32'd0,
	output reg  [31:0] fpiar = 32'd0,
	output wire        exc_pending,
	output wire  [7:0] vector,
	output reg         cond_true = 1'b0,
	output reg         bsun_exc = 1'b0,
	output reg         not_impl = 1'b0,
	// respuesta en el formato del buzon (FLAGS bits 4..0 y vector)
	output wire  [4:0] rflags,
	output wire  [7:0] rvec
);

`include "fpu_ops.vh"
`include "fpu_entries.vh"

//---------------------------------------------------------------------------
// Buferes
//---------------------------------------------------------------------------
reg [95:0] obuf [0:7];
reg [95:0] rbuf [0:7];
wire [2:0] s_ob_idx;
reg [95:0] ob_q;
wire       s_rb_we;
wire [2:0] s_rb_idx;
wire [95:0] s_rb_data;
reg        f_rb_we = 1'b0;
reg  [2:0] f_rb_idx;
reg [95:0] f_rb_data;
always @(posedge clk) begin
	if (ob_we) obuf[ob_wa] <= ob_wd;
	ob_q <= obuf[s_ob_idx];
	if (s_rb_we) rbuf[s_rb_idx] <= s_rb_data;
	else if (f_rb_we) rbuf[f_rb_idx] <= f_rb_data;
	rb_rd <= rbuf[rb_ra];
end

// el primer operando (registros de control) y el quinto (ultimo largo del
// cuerpo de un marco de FRESTORE) se leen directamente
reg [95:0] op0, op4;
always @(posedge clk) begin
	if (ob_we && ob_wa == 3'd0) op0 <= ob_wd;
	if (ob_we && ob_wa == 3'd4) op4 <= ob_wd;
end

//---------------------------------------------------------------------------
// Secuenciador
//---------------------------------------------------------------------------
reg        s_start = 1'b0, s_xstart = 1'b0;
reg  [9:0] s_entry;
reg [47:0] s_xins;
wire       s_busy, s_done;
reg signed [31:0] kfac;
reg        clr_status = 1'b0;
wire [7:0] st_exc, st_quot;
wire [3:0] st_cc;
wire       st_qv;
reg [15:0] c;                      // cmd de la peticion en curso
reg [31:0] x;                      // aux

fpu_seq seq (
	.clk(clk), .reset(reset),
	.start(s_start), .entry(s_entry), .xstart(s_xstart), .xins(s_xins),
	.busy(s_busy), .done(s_done),
	.cmd(c), .kfac(kfac), .fpcr_mode(fpcr[5:4]), .fpcr_prec(fpcr[7:6]),
	.clr_status(clr_status), .st_exc(st_exc), .st_cc(st_cc), .st_qv(st_qv), .st_quot(st_quot),
	.ob_idx(s_ob_idx), .ob_data(ob_q),
	.rb_we(s_rb_we), .rb_idx(s_rb_idx), .rb_data(s_rb_data)
);

// instrucciones sueltas: {uop, d, a, b, rc, sx, ri, rj, cond, imm}
function automatic [47:0] mk(input [5:0] uop, input [4:0] d, input [4:0] a, input [4:0] b,
                             input [2:0] rc, input sx, input [13:0] imm);
	mk = {uop, d, a, b, rc, sx, 3'd0, 3'd0, 3'd0, imm};
endfunction

// tabla de despacho: opmode -> programa
reg [9:0] disp [0:127];
initial $readmemh("fpu_disp.hex", disp);
reg [9:0] disp_q;
always @(posedge clk) disp_q <= disp[c[6:0]];

//---------------------------------------------------------------------------
// Excepcion pendiente: la de mas prioridad de las habilitadas
//---------------------------------------------------------------------------
wire [7:0] en_exc = fpsr[15:8] & fpcr[15:8];
function automatic [7:0] vec_of(input [7:0] e);
	vec_of = e[7] ? 8'd48 :      // BSUN
	         e[6] ? 8'd54 :      // SNAN
	         e[5] ? 8'd52 :      // OPERR
	         e[4] ? 8'd53 :      // OVFL
	         e[3] ? 8'd51 :      // UNFL
	         e[2] ? 8'd50 :      // DZ
	                8'd49;       // INEX1/INEX2
endfunction
assign vector = vec_of(en_exc);

// Excepcion pendiente (UM 6.4.2.2, como el 68882 de Hatari): la deja una
// instruccion aritmetica con una excepcion habilitada; el puente la da a la
// siguiente instruccion; FSAVE la absorbe en el marco (bit 27 de BIU a 0) y
// FRESTORE de ese marco la vuelve a armar.
reg        pend = 1'b0, raised = 1'b0, nullst = 1'b1;
reg  [7:0] pend_vec = 8'd0, raised_vec = 8'd0;
assign exc_pending = pend;
assign rflags = {raised, |fpcr[14:8], cond_true, pend, not_impl};
assign rvec   = raised ? raised_vec : pend ? pend_vec : 8'd0;

//---------------------------------------------------------------------------
// Predicados de FBcc/FScc/FDBcc/FTRAPcc (UM 4.4), con N Z I NAN del FPSR
//---------------------------------------------------------------------------
function automatic pred(input [4:0] p, input n, input z, input nan);
	reg r;
	begin
		case (p[3:0])
			4'h0: r = 1'b0;                       // F
			4'h1: r = z;                          // EQ
			4'h2: r = !(nan || z || n);           // OGT
			4'h3: r = z || !(nan || n);           // OGE
			4'h4: r = n && !(nan || z);           // OLT
			4'h5: r = z || (n && !nan);           // OLE
			4'h6: r = !(nan || z);                // OGL
			4'h7: r = !nan;                       // OR
			4'h8: r = nan;                        // UN
			4'h9: r = nan || z;                   // UEQ
			4'hA: r = nan || !(n || z);           // UGT
			4'hB: r = nan || z || !n;             // UGE
			4'hC: r = nan || (n && !z);           // ULT
			4'hD: r = nan || z || n;              // ULE
			4'hE: r = !z;                         // NE
			default: r = 1'b1;                    // T
		endcase
		pred = r;
	end
endfunction

//---------------------------------------------------------------------------
// Control
//---------------------------------------------------------------------------
localparam [3:0]
	T_IDLE = 4'd0, T_WAIT = 4'd1, T_OP  = 4'd2, T_FIN  = 4'd3, T_CR2 = 4'd4,
	T_MMIN = 4'd5, T_MMOT = 4'd6, T_RST = 4'd7, T_OFIN = 4'd8, T_ACK = 4'd9,
	T_DISP = 4'd10, T_DSP0 = 4'd11, T_SAVE = 4'd12;

reg  [3:0] t = T_IDLE;
reg  [3:0] t_next;                 // a donde ir cuando termine el secuenciador
reg  [2:0] kd;
reg  [3:0] mi;                     // FMOVEM / reset: registro
reg  [2:0] mk_idx;                 // FMOVEM: indice en el bufer
reg  [7:0] mlist;

assign busy = (t != T_IDLE);

// FPSR al acabar una instruccion aritmetica
task automatic fpsr_update(input set_cc);
	reg [7:0] e;
	begin
		e = st_exc;
		fpsr[15:8] <= e;
		fpsr[7]    <= fpsr[7] | e[7] | e[6] | e[5];
		fpsr[6]    <= fpsr[6] | e[4];
		fpsr[5]    <= fpsr[5] | (e[3] & e[1]);
		fpsr[4]    <= fpsr[4] | e[2];
		fpsr[3]    <= fpsr[3] | e[1] | e[0] | e[4];
		if (set_cc) fpsr[27:24] <= st_cc;
		if (st_qv) fpsr[23:16] <= st_quot;
	end
endtask

always @(posedge clk) begin
	ack        <= 1'b0;
	s_start    <= 1'b0;
	s_xstart   <= 1'b0;
	clr_status <= 1'b0;
	f_rb_we    <= 1'b0;

	if (reset) begin
		t <= T_IDLE;
		fpcr <= 32'd0; fpsr <= 32'd0; fpiar <= 32'd0;
	end else case (t)
	T_IDLE: if (req) begin
		c <= cmd; x <= aux; kd <= kind;
		not_impl <= 1'b0; bsun_exc <= 1'b0; raised <= 1'b0;
		clr_status <= 1'b1;
		if (kind == 3'd1 || kind == 3'd3) nullst <= 1'b0;
		case (kind)
		3'd1: begin
			if (iaddr_valid) fpiar <= iaddr;
			case (cmd[15:13])
			3'b000: t <= T_DSP0;
			3'b010: begin
				if (cmd[12:10] == 3'd7) begin
					// FMOVECR: constante de la ROM y redondeo segun FPCR
					s_xins   <= mk(6'd33, 5'd30, 5'd0, 5'd0, 3'd0, 1'b0, {7'd0, cmd[6:0]});
					s_xstart <= 1'b1;
					t <= T_WAIT; t_next <= T_CR2;
				end else if (cmd[12:10] == 3'd3) begin
					s_entry <= E_PIN; s_start <= 1'b1;
					t <= T_WAIT; t_next <= T_DSP0;
				end else begin
					s_xins   <= mk({1'b0, OP_UNPK}, 5'd8, 5'd0, 5'd0, 3'd1, 1'b1, 14'h0008);
					s_xstart <= 1'b1;
					t <= T_WAIT; t_next <= T_DSP0;
				end
			end
			3'b011: begin
				if (cmd[12:10] == 3'd3 || cmd[12:10] == 3'd7) begin
					kfac <= (cmd[12:10] == 3'd3) ? {{25{cmd[6]}}, cmd[6:0]} : {{25{aux[6]}}, aux[6:0]};
					s_entry <= E_POUT; s_start <= 1'b1;
				end else begin
					s_xins   <= mk({1'b0, OP_PACK}, 5'd0, 5'd30, 5'd0, 3'd0, 1'b1, 14'h0008);
					s_xstart <= 1'b1;
				end
				t <= T_WAIT; t_next <= T_OFIN;
			end
			3'b100: begin
				// <ea> -> FPcr: en orden FPCR, FPSR, FPIAR
				begin : crin
					reg [95:0] v;
					v = op0;
					if (cmd[12]) begin fpcr  <= {16'd0, v[79:64]}; v = v << 32; end
					if (cmd[11]) begin fpsr  <= v[95:64];          v = v << 32; end
					if (cmd[10]) begin fpiar <= v[95:64]; end
				end
				t <= T_ACK;
			end
			3'b101: begin
				begin : crout
					reg [95:0] v;
					v = 96'd0;
					if (cmd[10]) v = {fpiar, v[95:32]};
					if (cmd[11]) v = {fpsr,  v[95:32]};
					if (cmd[12]) v = {fpcr,  v[95:32]};
					f_rb_we <= 1'b1; f_rb_idx <= 3'd0; f_rb_data <= v;
				end
				t <= T_ACK;
			end
			3'b110, 3'b111: begin
				mlist  <= cmd[11] ? aux[7:0] : cmd[7:0];
				mi     <= 4'd0;
				mk_idx <= 3'd0;
				t <= (cmd[15:13] == 3'b110) ? T_MMIN : T_MMOT;
			end
			default: begin not_impl <= 1'b1; t <= T_ACK; end
			endcase
		end
		3'd2: begin mi <= 4'd0; fpcr <= 32'd0; fpsr <= 32'd0; fpiar <= 32'd0; nullst <= 1'b1; pend <= 1'b0; t <= T_RST; end
		3'd3: begin
			// condicion: los predicados $10-$1F con NaN activan BSUN
			cond_true <= pred(cmd[4:0], fpsr[27], fpsr[26], fpsr[24]);
			if (cmd[4] && fpsr[24]) begin
				fpsr[15] <= 1'b1;
				fpsr[7]  <= 1'b1;
				bsun_exc <= fpcr[15];
				if (fpcr[15]) begin raised <= 1'b1; raised_vec <= 8'd48; end
			end
			t <= T_ACK;
		end
		3'd4: begin
			// FSAVE: nulo ($00380000) tras un reset; si no, "idle" del 68882
			// ($1F38 y $38 bytes de cuerpo; el ultimo largo, BIU, con el bit
			// 27 a 0 si hay una excepcion pendiente, que queda absorbida)
			mi <= 4'd0;
			t  <= T_SAVE;
		end
		3'd5: begin
			// FRESTORE: un marco nulo resetea la FPU; uno idle/busy con el bit
			// 27 de BIU a 0 vuelve a dejar pendiente la excepcion
			if (aux[15:8] == 8'h00) begin
				mi <= 4'd0; fpcr <= 32'd0; fpsr <= 32'd0; fpiar <= 32'd0;
				nullst <= 1'b1; pend <= 1'b0; t <= T_RST;
			end else begin
				nullst <= 1'b0;
				if (!op4[59] && |(fpsr[15:8] & fpcr[15:8])) begin
					pend <= 1'b1; pend_vec <= vec_of(fpsr[15:8] & fpcr[15:8]);
				end
				t <= T_ACK;
			end
		end
		default: begin not_impl <= 1'b1; t <= T_ACK; end
		endcase
	end

	T_WAIT: if (s_done) t <= t_next;

	// opmode -> programa: un ciclo para leer la tabla con c[6:0]
	T_DSP0: t <= T_DISP;
	T_DISP: begin
		s_entry <= disp_q; s_start <= 1'b1;
		t <= T_WAIT; t_next <= T_FIN;
	end

	T_CR2: begin
		s_xins   <= mk({1'b0, OP_MOV}, 5'd30, 5'd30, 5'd0, 3'd0, 1'b1, 14'd0);
		s_xstart <= 1'b1;
		t <= T_WAIT; t_next <= T_FIN;
	end

	T_FIN: begin
		fpsr_update(1'b1);
		if (|(st_exc & fpcr[15:8])) begin pend <= 1'b1; pend_vec <= vec_of(st_exc & fpcr[15:8]); end
		t <= T_ACK;
	end
	T_OFIN: begin
		fpsr_update(1'b0);
		if (|(st_exc & fpcr[15:8])) begin raised <= 1'b1; raised_vec <= vec_of(st_exc & fpcr[15:8]); end
		t <= T_ACK;
	end

	// FSAVE: cinco trozos de 12 bytes (formato y cuerpo)
	T_SAVE: begin
		f_rb_we  <= 1'b1;
		f_rb_idx <= mi[2:0];
		case (mi[2:0])
			3'd0: f_rb_data <= nullst ? {32'h0038_0000, 64'd0} : {32'h1F38_0000, 64'd0};
			3'd4: f_rb_data <= {64'd0, pend ? 32'h0000_0000 : 32'h0800_0000};
			default: f_rb_data <= 96'd0;
		endcase
		mi <= mi + 4'd1;
		if (mi == 4'd4) begin
			if (!nullst) pend <= 1'b0;
			t <= T_ACK;
		end
	end

	// FMOVEM a la FPU: en memoria van de FP0 a FP7
	T_MMIN: begin
		if (mi == 4'd8) t <= T_ACK;
		else if (c[12] ? mlist[3'd7 - mi[2:0]] : mlist[mi[2:0]]) begin
			s_xins   <= mk({1'b0, OP_UNPK}, {2'b00, mi[2:0]}, 5'd0, 5'd0, 3'd1, 1'b0, {7'd0, mk_idx, 4'd2});
			s_xstart <= 1'b1;
			mk_idx   <= mk_idx + 3'd1;
			mi       <= mi + 4'd1;
			t <= T_WAIT; t_next <= T_MMIN;
		end else mi <= mi + 4'd1;
	end

	T_MMOT: begin
		if (mi == 4'd8) t <= T_ACK;
		else if (c[12] ? mlist[3'd7 - mi[2:0]] : mlist[mi[2:0]]) begin
			s_xins   <= mk({1'b0, OP_PACK}, 5'd0, {2'b00, mi[2:0]}, 5'd0, 3'd1, 1'b0, {7'd0, mk_idx, 4'd2});
			s_xstart <= 1'b1;
			mk_idx   <= mk_idx + 3'd1;
			mi       <= mi + 4'd1;
			t <= T_WAIT; t_next <= T_MMOT;
		end else mi <= mi + 4'd1;
	end

	// reset: FP0-FP7 a NaN
	T_RST: begin
		if (mi == 4'd8) t <= T_ACK;
		else begin
			s_xins   <= mk(6'd33, {2'b00, mi[2:0]}, 5'd0, 5'd0, 3'd0, 1'b0, C_NAN_IDX);
			s_xstart <= 1'b1;
			mi       <= mi + 4'd1;
			t <= T_WAIT; t_next <= T_RST;
		end
	end

	T_ACK: begin ack <= 1'b1; t <= T_IDLE; end

	default: t <= T_IDLE;
	endcase
end

endmodule

`default_nettype wire
