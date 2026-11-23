//============================================================================
// fpu_seq - secuenciador de microcodigo de la FPU 68882
//
// Ejecuta programas de la ROM de microcodigo (fpu_ucode.hex, generada por
// tools/fpu_asm.py) o una sola instruccion que le pasa fpu_top (FMOVEM,
// reset). Cada instruccion de motor lee dos registros, arranca fpu_engine y
// escribe el resultado.
//
// Constantes: 256 x 85 bits (FMOVECR en 0-63, las del microcodigo despues).
// Registros (32 x 85 bits, en M9K):
//   0-7 FP0-FP7   8 SRC (operando de memoria)   9-28 temporales T0-T19
//   29 = fuente de la instruccion (FPm en registro a registro, si no SRC)
//   30 = destino (FPn, cmd[9:7])   31 = segundo destino de FSINCOS (cmd[2:0])
// Enteros: I0-I7 de 32 bits (exponentes decimales, cuadrantes, contadores).
//
// Instruccion (48 bits):
//   [47:42] uop: 0-23 operacion del motor (fpu_ops.vh), 32+ control
//   [41:37] d  [36:32] a  [31:27] b
//   [26:24] rc (redondeo)  [23] sx (fija cc y excepciones en el FPSR)
//   [22:20] ri  [19:17] rj (enteros I0-I7)  [16:14] cond
//   [13:0]  imm: destino de salto, indice de constante, entero con signo, o
//           en UNPK/PACK: [2:0] formato, [3] formato de cmd[12:10],
//           [6:4] indice del bufer de operandos/resultados
//============================================================================
`default_nettype none

module fpu_seq (
	input  wire        clk,
	input  wire        reset,

	input  wire        start,          // programa desde entry
	input  wire  [9:0] entry,
	input  wire        xstart,         // una sola instruccion
	input  wire [47:0] xins,
	output reg         busy = 1'b0,
	output reg         done = 1'b0,

	input  wire [15:0] cmd,
	input  wire signed [31:0] kfac,    // FMOVE.P: factor k
	input  wire  [1:0] fpcr_mode,
	input  wire  [1:0] fpcr_prec,

	// excepciones y codigos de condicion de la instruccion en curso
	input  wire        clr_status,
	output reg   [7:0] st_exc = 8'd0,
	output reg   [3:0] st_cc = 4'd0,
	output reg         st_qv = 1'b0,
	output reg   [7:0] st_quot = 8'd0,

	// bufer de operandos (lectura) y de resultados (escritura)
	output reg   [2:0] ob_idx,
	input  wire [95:0] ob_data,
	output reg         rb_we = 1'b0,
	output reg   [2:0] rb_idx,
	output reg  [95:0] rb_data
);

`include "fpu_ops.vh"

localparam [5:0]
	U_END  = 6'd32, U_LDC  = 6'd33, U_J    = 6'd34, U_JCLS = 6'd35,
	U_JCC  = 6'd36, U_JI   = 6'd37, U_IADD = 6'd38, U_IMOV = 6'd39,
	U_ISET = 6'd40, U_IKF  = 6'd41, U_CALL = 6'd42, U_RET  = 6'd43,
	U_SETX = 6'd44, U_ISHR = 6'd45, U_ISUB = 6'd46, U_INEG = 6'd47,
	U_LDCI = 6'd48, U_IQUO = 6'd49, U_ICMP = 6'd50;

//---------------------------------------------------------------------------
// Memorias
//---------------------------------------------------------------------------
reg [47:0] urom [0:1023];
initial $readmemh("fpu_ucode.hex", urom);
reg [84:0] crom [0:255];
initial $readmemh("fpu_const.hex", crom);

// banco de registros: dos copias (dos puertos de lectura)
reg [84:0] rfa [0:31];
reg [84:0] rfb [0:31];
reg  [4:0] ra_a, ra_b;
reg [84:0] qa, qb;
reg        rf_we = 1'b0;
reg  [4:0] rf_wa;
reg [84:0] rf_wd;
always @(posedge clk) begin
	if (rf_we) begin
		rfa[rf_wa] <= rf_wd;
		rfb[rf_wa] <= rf_wd;
	end
	qa <= rfa[ra_a];
	qb <= rfb[ra_b];
end

reg  [9:0] pc;
reg [47:0] ins;
reg [47:0] urom_q;
reg  [7:0] crom_a;
reg [84:0] crom_q;
always @(posedge clk) begin
	urom_q <= urom[pc];
	crom_q <= crom[crom_a];
end

// campos
wire [5:0] i_uop  = ins[47:42];
wire [4:0] i_d    = ins[41:37];
wire [4:0] i_a    = ins[36:32];
wire [4:0] i_b    = ins[31:27];
wire [2:0] i_rc   = ins[26:24];
wire       i_sx   = ins[23];
wire [2:0] i_ri   = ins[22:20];
wire [2:0] i_rj   = ins[19:17];
wire [2:0] i_cond = ins[16:14];
wire [13:0] i_imm = ins[13:0];
wire signed [31:0] i_simm = {{18{ins[13]}}, ins[13:0]};

// 29, 30 y 31 dependen de la instruccion del 68030
function automatic [4:0] rmap(input [4:0] x);
	case (x)
		5'd29: rmap = (cmd[15:13] == 3'b000) ? {2'b00, cmd[12:10]} : 5'd8;
		5'd30: rmap = {2'b00, cmd[9:7]};
		5'd31: rmap = {2'b00, cmd[2:0]};
		default: rmap = x;
	endcase
endfunction

reg signed [31:0] ir [0:7];
reg  [9:0] stack [0:3];
reg  [1:0] sp;
reg  [3:0] lcc;                    // cc de la ultima operacion del motor

//---------------------------------------------------------------------------
// Motor
//---------------------------------------------------------------------------
reg        e_start = 1'b0;
wire       e_done, e_rwe, e_qwe, e_iwe;
wire [84:0] e_r;
wire [7:0] e_exc, e_quot;
wire [3:0] e_cc;
wire signed [31:0] e_iout;
wire [95:0] e_raw;
wire [2:0] e_fmt = i_imm[3] ? cmd[12:10] : i_imm[2:0];

fpu_engine engine (
	.clk(clk), .start(e_start), .op(i_uop[4:0]), .rc(i_rc), .fmt(e_fmt),
	.fpcr_mode(fpcr_mode), .fpcr_prec(fpcr_prec),
	.a(qa), .b(qb), .i_in(ir[i_ri]), .i_len(ir[i_rj][4:0]), .raw_in(ob_data),
	.done(e_done), .r_we(e_rwe), .r(e_r), .exc(e_exc), .cc(e_cc),
	.q_we(e_qwe), .quot(e_quot), .i_we(e_iwe), .i_out(e_iout), .raw_out(e_raw)
);

//---------------------------------------------------------------------------
// Control
//---------------------------------------------------------------------------
localparam [2:0] Q_IDLE = 3'd0, Q_FETCH = 3'd1, Q_FET2 = 3'd2, Q_DEC = 3'd3,
                 Q_RD = 3'd4, Q_EXE = 3'd5, Q_WAIT = 3'd6, Q_LDC = 3'd7;
reg  [2:0] q = Q_IDLE;
reg        single;                 // instruccion externa: termina al acabar

// condiciones
function automatic cls_cond(input [84:0] x, input [2:0] c);
	reg r;
	begin
		case (c[1:0])
			2'd0: r = (x[84:83] == 2'd1);   // cero
			2'd1: r = (x[84:83] == 2'd2);   // infinito
			2'd2: r = (x[84:83] == 2'd3);   // NaN
			default: r = x[82];             // negativo
		endcase
		cls_cond = c[2] ? !r : r;
	end
endfunction

function automatic cc_cond(input [3:0] c4, input [2:0] c);
	// c4 = {N,Z,I,NAN} del ultimo CMP/TST
	case (c)
		3'd0: cc_cond = c4[2];                              // EQ
		3'd1: cc_cond = !c4[2];                             // NE
		3'd2: cc_cond = c4[3] && !c4[2] && !c4[0];          // LT
		3'd3: cc_cond = (!c4[3] || c4[2]) && !c4[0];        // GE
		3'd4: cc_cond = !c4[3] && !c4[2] && !c4[0];         // GT
		3'd5: cc_cond = (c4[3] || c4[2]) && !c4[0];         // LE
		3'd6: cc_cond = c4[0];                              // sin orden
		default: cc_cond = 1'b1;
	endcase
endfunction

function automatic int_cond(input signed [31:0] v, input [2:0] c);
	case (c)
		3'd0: int_cond = (v == 0);
		3'd1: int_cond = (v != 0);
		3'd2: int_cond = (v < 0);
		3'd3: int_cond = (v > 0);
		3'd4: int_cond = (v >= 0);
		3'd5: int_cond = v[0];
		3'd6: int_cond = !v[0];
		default: int_cond = v[1];
	endcase
endfunction

always @(posedge clk) begin
	done    <= 1'b0;
	e_start <= 1'b0;
	rf_we   <= 1'b0;
	rb_we   <= 1'b0;

	if (clr_status) begin
		st_exc <= 8'd0;
		st_qv  <= 1'b0;
	end

	if (reset) begin
		q <= Q_IDLE; busy <= 1'b0; sp <= 2'd0;
	end else case (q)
	Q_IDLE: begin
		if (start) begin
			pc <= entry; single <= 1'b0; busy <= 1'b1; sp <= 2'd0;
			q <= Q_FETCH;
		end else if (xstart) begin
			ins <= xins; single <= 1'b1; busy <= 1'b1;
			q <= Q_DEC;
		end
	end

	// la ROM de microcodigo tiene un ciclo de latencia
	Q_FETCH: q <= Q_FET2;

	Q_FET2: begin
		ins <= urom_q;
		q   <= Q_DEC;
	end

	Q_DEC: begin
		ra_a   <= rmap(i_a);
		ra_b   <= rmap(i_b);
		ob_idx <= i_imm[6:4];
		crom_a <= i_imm[7:0];
		if (!i_uop[5]) q <= Q_RD;                // motor: leer registros
		else begin
			q  <= Q_FETCH;
			pc <= pc + 10'd1;
			case (i_uop)
			U_END:  begin busy <= 1'b0; done <= 1'b1; q <= Q_IDLE; end
			U_LDC:  q <= Q_LDC;
			U_LDCI: begin crom_a <= i_imm[7:0] + ir[i_rj][7:0]; q <= Q_LDC; end
			U_J:    pc <= i_imm[9:0];
			U_JCLS: q <= Q_RD;                    // necesita el registro
			U_JCC:  if (cc_cond(lcc, i_cond)) pc <= i_imm[9:0];
			U_JI:   if (int_cond(ir[i_ri], i_cond)) pc <= i_imm[9:0];
			U_IADD: ir[i_ri] <= ir[i_ri] + i_simm;
			U_ISUB: ir[i_ri] <= ir[i_ri] - ir[i_rj];
			U_IMOV: ir[i_ri] <= ir[i_rj];
			U_ISET: ir[i_ri] <= i_simm;
			U_INEG: ir[i_ri] <= -ir[i_ri];
			U_ISHR: ir[i_ri] <= ir[i_ri] >>> 1;
			U_IKF:  ir[i_ri] <= kfac;
			U_IQUO: ir[i_ri] <= st_quot[7] ? -{25'd0, st_quot[6:0]} : {25'd0, st_quot[6:0]};
			U_ICMP: lcc <= {ir[i_ri] < ir[i_rj], ir[i_ri] == ir[i_rj], 2'b00};
			U_CALL: begin stack[sp] <= pc + 10'd1; sp <= sp + 2'd1; pc <= i_imm[9:0]; end
			U_RET:  begin pc <= stack[sp - 2'd1]; sp <= sp - 2'd1; end
			U_SETX: st_exc <= st_exc | i_imm[7:0];
			default: ;
			endcase
			if (single && i_uop != U_LDC && i_uop != U_LDCI) begin busy <= 1'b0; done <= 1'b1; q <= Q_IDLE; end
		end
	end

	// constantes: un ciclo de ROM; se escriben tal cual en Q_WAIT
	Q_LDC: q <= Q_WAIT;

	Q_RD: q <= Q_EXE;                         // espera los registros

	Q_EXE: begin
		if (i_uop == U_JCLS) begin
			if (cls_cond(qa, i_cond)) pc <= i_imm[9:0];   // pc ya avanzo en Q_DEC
			q  <= Q_FETCH;
		end else begin
			e_start <= 1'b1;
			q <= Q_WAIT;
		end
	end

	Q_WAIT: begin
		if (i_uop == U_LDC || i_uop == U_LDCI) begin
			// la constante ya esta en crom_q
			rf_we <= 1'b1; rf_wa <= rmap(i_d); rf_wd <= crom_q;
			if (single) begin busy <= 1'b0; done <= 1'b1; q <= Q_IDLE; end
			else q <= Q_FETCH;
		end else if (e_done) begin
			if (e_rwe && i_uop[4:0] != OP_CMP && i_uop[4:0] != OP_TST) begin
				rf_we <= 1'b1; rf_wa <= rmap(i_d); rf_wd <= e_r;
			end
			if (e_iwe) ir[i_ri] <= e_iout;
			if (i_uop[4:0] == OP_PACK || i_uop[4:0] == OP_PENC) begin
				rb_we <= 1'b1; rb_idx <= i_imm[6:4]; rb_data <= e_raw;
			end
			lcc <= e_cc;
			if (e_qwe) begin st_qv <= 1'b1; st_quot <= e_quot; end
			if (i_sx) begin
				st_exc <= st_exc | e_exc;
				st_cc  <= e_cc;
			end
			pc <= pc + 10'd1;
			if (single) begin busy <= 1'b0; done <= 1'b1; q <= Q_IDLE; end
			else q <= Q_FETCH;
		end
	end
	endcase
end

endmodule

`default_nettype wire
