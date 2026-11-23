//============================================================================
// fpu_engine - motor aritmetico iterativo de la FPU 68882
//
// Un solo camino de datos para todas las operaciones: un desplazador a la
// derecha con sticky, un normalizador (contador de ceros + desplazador a la
// izquierda), un sumador de 68 bits y un multiplicador de 64 x 16 (en los
// bloques DSP). Division, raiz y resto van bit a bit.
//
// Formato interno (UF, 85 bits), el de los registros FP0-FP7 y temporales:
//   [84:83] clase: 0 normal, 1 cero, 2 infinito, 3 NaN
//   [82]    signo
//   [81:64] exponente sin sesgo, 18 bits con signo (cabe todo el rango
//           intermedio: desnormales normalizados, productos, FSCALE)
//   [63:0]  mantisa con el bit entero explicito: [63] = 1 en los normales
//           (los desnormales se guardan normalizados, con exponente < emin)
//           NaN: [62] = 1 silencioso, 0 senalizador; el resto, la carga
//
// Mantisa de trabajo: 68 bits, [67] acarreo, [66] bit entero, [65:3] la
// fraccion de 63 bits, [2:0] guarda, redondeo y sticky.
//
// Convenio de operandos: a = destino (FPn), b = fuente. ADD a+b, SUB a-b,
// MUL a*b, DIV a/b, REM/MOD a rem b, SCALE a*2^int(b), CMP a-b (solo cc).
// Las monadicas (MOV, ABS, NEG, SQRT, INT, GETEXP...) usan a.
//
// Redondeo (rc):
//   0 FPCR (precision y modo), rango extendido      (resultado normal)
//   1 extendido, al mas cercano                      (pasos internos)
//   2 simple, modo FPCR, rango simple                (FMOVE.S, FSxxx)
//   3 doble,  modo FPCR, rango doble                 (FMOVE.D, FDxxx)
//   4 simple, modo FPCR, rango extendido             (FSGLMUL, FSGLDIV)
//   5 extendido, hacia -inf                          (suelo, en FMOVE.P)
//   6 extendido, hacia cero                          (pasos internos)
//   7 doble, modo FPCR, rango extendido              (FDxxx)
//============================================================================
`default_nettype none

module fpu_engine (
	input  wire        clk,
	input  wire        start,
	input  wire  [4:0] op,
	input  wire  [2:0] rc,
	input  wire  [2:0] fmt,          // UNPK/PACK: 0 L 1 S 2 X 3 P 4 W 5 D 6 B
	input  wire  [1:0] fpcr_mode,    // 0 RN 1 RZ 2 RM 3 RP
	input  wire  [1:0] fpcr_prec,    // 0 X 1 S 2 D
	input  wire [84:0] a,
	input  wire [84:0] b,
	input  wire signed [31:0] i_in,  // I2F; PENC: exponente decimal
	input  wire  [4:0] i_len,        // PENC: numero de digitos
	input  wire [95:0] raw_in,       // UNPK/PDEC: operando en memoria
	output reg         done = 1'b0,
	output reg         r_we,         // hay resultado para el registro destino
	output reg  [84:0] r,
	output reg   [7:0] exc,          // {BSUN,SNAN,OPERR,OVFL,UNFL,DZ,INEX2,INEX1}
	output reg   [3:0] cc,           // {N,Z,I,NAN}
	output reg         q_we,         // REM/MOD: byte de cociente valido
	output reg   [7:0] quot,
	output reg         i_we,         // F2I, PDEC, GETEXP entero
	output reg signed [31:0] i_out,
	output reg  [95:0] raw_out
);

`include "fpu_ops.vh"

localparam [1:0] C_NORM = 2'd0, C_ZERO = 2'd1, C_INF = 2'd2, C_NAN = 2'd3;
localparam [63:0] QNAN_M = 64'hFFFF_FFFF_FFFF_FFFF;   // NaN por defecto

//---------------------------------------------------------------------------
// Utilidades combinacionales (un ejemplar de cada una)
//---------------------------------------------------------------------------
function automatic [6:0] lzc68(input [67:0] x);
	integer i;
	reg found;
	begin
		lzc68 = 7'd68;
		found = 1'b0;
		for (i = 67; i >= 0; i = i - 1)
			if (!found && x[i]) begin
				lzc68 = 7'(67 - i);
				found = 1'b1;
			end
	end
endfunction

// x >> n con lo que sale por abajo acumulado en el bit 0 (sticky)
function automatic [67:0] rsh_st(input [67:0] x, input [17:0] n);
	reg [67:0] y, lost;
	begin
		if (n >= 18'd68) begin
			y = 68'd0;
			lost = x;
		end else begin
			y = x >> n[6:0];
			lost = x & ~(68'hF_FFFF_FFFF_FFFF_FFFF << n[6:0]);
		end
		rsh_st = y | {67'd0, |lost};
	end
endfunction

//---------------------------------------------------------------------------
// Estado
//---------------------------------------------------------------------------
localparam [4:0]
	S_IDLE = 5'd0,  S_PRE  = 5'd1,  S_ALIGN = 5'd2, S_ADD  = 5'd3,
	S_MUL  = 5'd4,  S_DIV  = 5'd5,  S_SQRT  = 5'd6, S_REM  = 5'd7,
	S_REM2 = 5'd8,  S_NORM = 5'd9,  S_R1    = 5'd10, S_R2  = 5'd11,
	S_R3   = 5'd12, S_RENO = 5'd13, S_PACK  = 5'd14, S_PDEC = 5'd15,
	S_PENC = 5'd16, S_PDF  = 5'd17, S_FIN   = 5'd18, S_IEXT = 5'd19,
	S_PFIN = 5'd20;

reg  [4:0] st = S_IDLE;
reg  [4:0] o;                      // operacion en curso
reg  [2:0] f;                      // formato
reg  [1:0] ca, cb;                 // clases
reg        sa, sb, rs;
reg signed [17:0] ea, eb, re;
reg [67:0] ma, mb, rm;
reg [127:0] acc;                   // producto / resto
reg [69:0] rem;                    // division, raiz, resto
reg [67:0] q;                      // cociente / raiz
reg [15:0] cnt;
reg [1:0] rcls;                    // clase del resultado
reg        tiny;
reg        no_reno;                // PACK: no volver a normalizar
reg        int_mode;               // redondeo a entero (INT, PACK L/W/B, F2I)
reg  [6:0] p;                      // bits que se conservan
reg signed [17:0] emin, emax;
reg  [1:0] mode;
reg [67:0] bcd;                    // PENC: 17 digitos
reg [15:0] bcde;                   // PENC: exponente en BCD
reg [63:0] bin;
reg [12:0] bine;

// parametros de redondeo segun rc
task automatic set_round(input [2:0] c);
	begin
		int_mode <= 1'b0;
		emin <= -18'sd16383; emax <= 18'sd16383; p <= 7'd64; mode <= fpcr_mode;
		case (c)
		3'd0: p <= (fpcr_prec == 2'd1) ? 7'd24 : (fpcr_prec == 2'd2) ? 7'd53 : 7'd64;
		3'd1: mode <= 2'd0;
		3'd2: begin p <= 7'd24; emin <= -18'sd126;  emax <= 18'sd127;  end
		3'd3: begin p <= 7'd53; emin <= -18'sd1022; emax <= 18'sd1023; end
		3'd4: p <= 7'd24;
		3'd5: mode <= 2'd2;
		3'd6: mode <= 2'd1;
		3'd7: p <= 7'd53;
		default: ;
		endcase
	end
endtask

wire        a_snan = (a[84:83] == C_NAN) && !a[62];
wire        b_snan = (b[84:83] == C_NAN) && !b[62];

// NaN de un operando, ya silenciado
function automatic [84:0] quiet(input [84:0] x);
	quiet = {x[84:63], 1'b1, x[61:0]};
endfunction

// mantisa entera de un valor ya redondeado a entero (re <= 62)
wire [63:0] int_mag = (re < 0) ? 64'd0 : (rm[66:3] >> (7'd63 - re[6:0]));

always @(posedge clk) begin
	done <= 1'b0;

	case (st)
	S_IDLE: if (start) begin
		o  <= op;
		f  <= fmt;
		ca <= a[84:83]; sa <= a[82]; ea <= a[81:64]; ma <= {1'b0, a[63:0], 3'b000};
		cb <= b[84:83]; sb <= b[82]; eb <= b[81:64]; mb <= {1'b0, b[63:0], 3'b000};
		exc <= 8'd0; r_we <= 1'b0; q_we <= 1'b0; i_we <= 1'b0;
		no_reno <= 1'b0; tiny <= 1'b0;
		set_round(rc);
		st <= S_PRE;
	end

	//-----------------------------------------------------------------------
	// Casos especiales y preparacion
	//-----------------------------------------------------------------------
	S_PRE: begin
		rcls <= C_NORM;
		r_we <= 1'b1;
		st   <= S_NORM;           // por defecto: normalizar y redondear rs/re/rm
		case (o)
		OP_MOV, OP_ABS, OP_NEG, OP_TST: begin
			rs <= (o == OP_ABS) ? 1'b0 : (o == OP_NEG) ? ~sa : sa;
			re <= ea; rm <= ma; rcls <= ca;
			if (ca == C_NAN) begin exc[6] <= a_snan; rs <= sa; rm <= {1'b0, a[63], 1'b1, a[61:0], 3'b0}; st <= S_FIN; end
			else if (ca != C_NORM) st <= S_FIN;
			if (o == OP_TST) r_we <= 1'b0;
		end

		OP_ADD, OP_SUB, OP_CMP: begin
			if (o == OP_CMP) r_we <= 1'b0;
			if (ca == C_NAN || cb == C_NAN) begin
				exc[6] <= a_snan | b_snan;
				{rcls, rs, re} <= {C_NAN, (ca == C_NAN) ? sa : sb, 18'sd0};
				rm <= (ca == C_NAN) ? {1'b0, a[63], 1'b1, a[61:0], 3'b0} : {1'b0, b[63], 1'b1, b[61:0], 3'b0};
				st <= S_FIN;
			end else if (ca == C_INF && cb == C_INF) begin
				if (sa ^ sb ^ (o != OP_ADD)) begin       // inf - inf
					exc[5] <= 1'b1; rcls <= C_NAN; rs <= 1'b0; rm <= {1'b0, QNAN_M, 3'b0};
				end else begin rcls <= C_INF; rs <= sa; end
				st <= S_FIN;
			end else if (ca == C_INF) begin rcls <= C_INF; rs <= sa; st <= S_FIN; end
			else if (cb == C_INF) begin rcls <= C_INF; rs <= sb ^ (o != OP_ADD); st <= S_FIN; end
			else if (ca == C_ZERO && cb == C_ZERO) begin
				rcls <= C_ZERO;
				// +0 + -0: +0 salvo hacia -inf
				rs <= (sa == (sb ^ (o != OP_ADD))) ? sa : (mode == 2'd2);
				st <= S_FIN;
			end else if (cb == C_ZERO) begin rs <= sa; re <= ea; rm <= ma; end
			else if (ca == C_ZERO) begin rs <= sb ^ (o != OP_ADD); re <= eb; rm <= mb; end
			else st <= S_ALIGN;
		end

		OP_MUL: begin
			rs <= sa ^ sb;
			if (ca == C_NAN || cb == C_NAN) begin
				exc[6] <= a_snan | b_snan;
				{rcls, rs} <= {C_NAN, (ca == C_NAN) ? sa : sb};
				rm <= (ca == C_NAN) ? {1'b0, a[63], 1'b1, a[61:0], 3'b0} : {1'b0, b[63], 1'b1, b[61:0], 3'b0};
				st <= S_FIN;
			end else if ((ca == C_INF && cb == C_ZERO) || (ca == C_ZERO && cb == C_INF)) begin
				exc[5] <= 1'b1; rcls <= C_NAN; rs <= 1'b0; rm <= {1'b0, QNAN_M, 3'b0}; st <= S_FIN;
			end else if (ca == C_INF || cb == C_INF) begin rcls <= C_INF; st <= S_FIN; end
			else if (ca == C_ZERO || cb == C_ZERO) begin rcls <= C_ZERO; st <= S_FIN; end
			else begin
				re  <= ea + eb;
				acc <= 128'd0;
				cnt <= 16'd0;
				st  <= S_MUL;
			end
		end

		OP_DIV: begin
			rs <= sa ^ sb;
			if (ca == C_NAN || cb == C_NAN) begin
				exc[6] <= a_snan | b_snan;
				{rcls, rs} <= {C_NAN, (ca == C_NAN) ? sa : sb};
				rm <= (ca == C_NAN) ? {1'b0, a[63], 1'b1, a[61:0], 3'b0} : {1'b0, b[63], 1'b1, b[61:0], 3'b0};
				st <= S_FIN;
			end else if ((ca == C_INF && cb == C_INF) || (ca == C_ZERO && cb == C_ZERO)) begin
				exc[5] <= 1'b1; rcls <= C_NAN; rs <= 1'b0; rm <= {1'b0, QNAN_M, 3'b0}; st <= S_FIN;
			end else if (ca == C_INF) begin rcls <= C_INF; st <= S_FIN; end
			else if (cb == C_ZERO) begin exc[2] <= 1'b1; rcls <= C_INF; st <= S_FIN; end
			else if (ca == C_ZERO || cb == C_INF) begin rcls <= C_ZERO; st <= S_FIN; end
			else begin
				re  <= ea - eb;
				rem <= {2'b00, ma};
				q   <= 68'd0;
				cnt <= 16'd0;
				st  <= S_DIV;
			end
		end

		OP_SQRT: begin
			rs <= sa;
			if (ca == C_NAN) begin exc[6] <= a_snan; rcls <= C_NAN; rm <= {1'b0, a[63], 1'b1, a[61:0], 3'b0}; st <= S_FIN; end
			else if (ca == C_ZERO) begin rcls <= C_ZERO; st <= S_FIN; end
			else if (sa) begin exc[5] <= 1'b1; rcls <= C_NAN; rs <= 1'b0; rm <= {1'b0, QNAN_M, 3'b0}; st <= S_FIN; end
			else if (ca == C_INF) begin rcls <= C_INF; st <= S_FIN; end
			else begin
				// exponente par: si es impar la mantisa pasa a [2,4)
				re  <= ea >>> 1;
				acc <= ea[0] ? {ma[66:0], 61'd0} : {1'b0, ma[66:0], 60'd0};
				rem <= 70'd0;
				q   <= 68'd0;
				cnt <= 16'd0;
				st  <= S_SQRT;
			end
		end

		OP_REM, OP_MOD: begin
			rs <= sa;
			if (ca == C_NAN || cb == C_NAN) begin
				exc[6] <= a_snan | b_snan;
				{rcls, rs} <= {C_NAN, (ca == C_NAN) ? sa : sb};
				rm <= (ca == C_NAN) ? {1'b0, a[63], 1'b1, a[61:0], 3'b0} : {1'b0, b[63], 1'b1, b[61:0], 3'b0};
				st <= S_FIN;
			end else if (ca == C_INF || cb == C_ZERO) begin
				exc[5] <= 1'b1; rcls <= C_NAN; rs <= 1'b0; rm <= {1'b0, QNAN_M, 3'b0}; st <= S_FIN;
			end else if (ca == C_ZERO || cb == C_INF) begin
				rcls <= ca; re <= ea; rm <= ma; q_we <= 1'b1; quot <= {sa ^ sb, 7'd0}; st <= S_FIN;
			end else begin
				q   <= 68'd0;
				rem <= {2'b00, ma};
				cnt <= 16'd0;
				st  <= S_REM;
			end
		end

		OP_INT, OP_INTRZ: begin
			rs <= sa; re <= ea; rm <= ma; rcls <= ca;
			if (ca == C_NAN) begin exc[6] <= a_snan; rm <= {1'b0, a[63], 1'b1, a[61:0], 3'b0}; st <= S_FIN; end
			else if (ca != C_NORM) st <= S_FIN;
			else begin
				int_mode <= 1'b1; emin <= -18'sd1;
				if (o == OP_INTRZ) mode <= 2'd1;
				st <= S_R1;
			end
		end

		OP_GETEXP: begin
			rs <= sa;
			if (ca == C_NAN) begin exc[6] <= a_snan; rcls <= C_NAN; rm <= {1'b0, a[63], 1'b1, a[61:0], 3'b0}; st <= S_FIN; end
			else if (ca == C_INF) begin exc[5] <= 1'b1; rcls <= C_NAN; rs <= 1'b0; rm <= {1'b0, QNAN_M, 3'b0}; st <= S_FIN; end
			else if (ca == C_ZERO) begin rcls <= C_ZERO; st <= S_FIN; end
			else begin
				// el exponente como numero: 18 bits con signo
				rs <= ea[17];
				rm <= {1'b0, ea[17] ? -ea : ea, 49'd0};
				re <= 18'sd17;
			end
		end

		OP_GETMAN: begin
			rs <= sa; rm <= ma; re <= 18'sd0; rcls <= ca;
			if (ca == C_NAN) begin exc[6] <= a_snan; rm <= {1'b0, a[63], 1'b1, a[61:0], 3'b0}; st <= S_FIN; end
			else if (ca == C_INF) begin exc[5] <= 1'b1; rcls <= C_NAN; rs <= 1'b0; rm <= {1'b0, QNAN_M, 3'b0}; st <= S_FIN; end
			else if (ca == C_ZERO) st <= S_FIN;
		end

		OP_SCALE: begin
			rs <= sa; rm <= ma; rcls <= ca;
			if (ca == C_NAN || cb == C_NAN) begin
				exc[6] <= a_snan | b_snan;
				{rcls, rs} <= {C_NAN, (ca == C_NAN) ? sa : sb};
				rm <= (ca == C_NAN) ? {1'b0, a[63], 1'b1, a[61:0], 3'b0} : {1'b0, b[63], 1'b1, b[61:0], 3'b0};
				st <= S_FIN;
			end else if (cb == C_INF) begin
				exc[5] <= 1'b1; rcls <= C_NAN; rs <= 1'b0; rm <= {1'b0, QNAN_M, 3'b0}; st <= S_FIN;
			end else if (ca != C_NORM) st <= S_FIN;
			else if (cb == C_ZERO || eb < 0) re <= ea;
			else if (eb >= 18'sd16) re <= sb ? ea - 18'sd65535 : ea + 18'sd65535;
			else begin
				// parte entera de b, truncada: |b| < 2^16
				re <= sb ? ea - $signed({2'b00, mb[66:51] >> (4'd15 - eb[3:0])})
				         : ea + $signed({2'b00, mb[66:51] >> (4'd15 - eb[3:0])});
			end
		end

		OP_I2F: begin
			rs <= i_in[31];
			if (i_in == 32'sd0) begin rcls <= C_ZERO; rs <= 1'b0; st <= S_FIN; end
			else begin
				rm <= {1'b0, i_in[31] ? -i_in : i_in, 35'd0};
				re <= 18'sd31;
			end
		end

		OP_F2I: begin
			// entero de 32 bits con signo, truncando, saturado
			r_we <= 1'b0;
			rs <= sa; re <= ea; rm <= ma;
			if (ca != C_NORM) begin
				i_we  <= 1'b1;
				i_out <= (ca == C_ZERO) ? 32'sd0 : sa ? 32'sh8000_0000 : 32'sh7FFF_FFFF;
				st    <= S_FIN;
				rcls  <= ca;
			end else begin
				int_mode <= 1'b1; emin <= -18'sd1; mode <= 2'd1; no_reno <= 1'b1;
				st <= S_R1;
			end
		end

		OP_IEXP: begin
			// exponente de a como entero (0 para cero/inf/NaN)
			r_we <= 1'b0; i_we <= 1'b1;
			i_out <= (ca == C_NORM) ? {{14{ea[17]}}, ea} : 32'sd0;
			rcls <= ca;
			st <= S_FIN;
		end

		OP_UNPK: begin
			rs <= 1'b0;
			case (f)
			3'd0, 3'd4, 3'd6: begin   // enteros: L, W, B
				begin : unpk_int
					reg signed [31:0] v;
					v = (f == 3'd0) ? raw_in[95:64] :
					    (f == 3'd4) ? {{16{raw_in[95]}}, raw_in[95:80]} :
					                  {{24{raw_in[95]}}, raw_in[95:88]};
					rs <= v[31];
					if (v == 32'sd0) begin rcls <= C_ZERO; st <= S_FIN; end
					else begin rm <= {1'b0, v[31] ? -v : v, 35'd0}; re <= 18'sd31; end
				end
			end
			3'd1: begin               // simple
				rs <= raw_in[95];
				if (raw_in[94:87] == 8'hFF) begin
					rcls <= (raw_in[86:64] == 23'd0) ? C_INF : C_NAN;
					rm <= {1'b0, 1'b1, raw_in[86:64], 40'd0, 3'b0};
					st <= S_FIN;
				end else if (raw_in[94:87] == 8'h00) begin
					if (raw_in[86:64] == 23'd0) begin rcls <= C_ZERO; st <= S_FIN; end
					else begin rm <= {1'b0, 1'b0, raw_in[86:64], 40'd0, 3'b0}; re <= -18'sd126; end
				end else begin
					rm <= {1'b0, 1'b1, raw_in[86:64], 40'd0, 3'b0};
					re <= $signed({10'd0, raw_in[94:87]}) - 18'sd127;
				end
			end
			3'd5: begin               // doble
				rs <= raw_in[95];
				if (raw_in[94:84] == 11'h7FF) begin
					rcls <= (raw_in[83:32] == 52'd0) ? C_INF : C_NAN;
					rm <= {1'b0, 1'b1, raw_in[83:32], 11'd0, 3'b0};
					st <= S_FIN;
				end else if (raw_in[94:84] == 11'h000) begin
					if (raw_in[83:32] == 52'd0) begin rcls <= C_ZERO; st <= S_FIN; end
					else begin rm <= {1'b0, 1'b0, raw_in[83:32], 11'd0, 3'b0}; re <= -18'sd1022; end
				end else begin
					rm <= {1'b0, 1'b1, raw_in[83:32], 11'd0, 3'b0};
					re <= $signed({7'd0, raw_in[94:84]}) - 18'sd1023;
				end
			end
			default: begin           // extendido
				rs <= raw_in[95];
				if (raw_in[94:80] == 15'h7FFF) begin
					rcls <= (raw_in[62:0] == 63'd0) ? C_INF : C_NAN;
					rm <= {1'b0, 1'b1, raw_in[62:0], 3'b0};
					st <= S_FIN;
				end else if (raw_in[63:0] == 64'd0) begin
					rcls <= C_ZERO; st <= S_FIN;
				end else begin
					// desnormales y no normalizados: se normalizan en S_NORM
					rm <= {1'b0, raw_in[63:0], 3'b0};
					re <= (raw_in[94:80] == 15'd0) ? -18'sd16383 : $signed({3'd0, raw_in[94:80]}) - 18'sd16383;
				end
			end
			endcase
			// la entrada en memoria es exacta en extendido: sin redondear
			p <= 7'd64; emin <= -18'sd131071; emax <= 18'sd131071;
		end

		OP_PACK: begin
			r_we <= 1'b0;
			rs <= sa; re <= ea; rm <= ma; rcls <= ca;
			no_reno <= 1'b1;
			if (ca == C_NAN) exc[6] <= a_snan;
			case (f)
			3'd0, 3'd4, 3'd6: begin
				int_mode <= 1'b1; emin <= -18'sd1;
				if (ca == C_NORM) st <= S_R1; else st <= S_PACK;
			end
			3'd1: begin p <= 7'd24; emin <= -18'sd126;  emax <= 18'sd127;  if (ca == C_NORM) st <= S_R1; else st <= S_PACK; end
			3'd5: begin p <= 7'd53; emin <= -18'sd1022; emax <= 18'sd1023; if (ca == C_NORM) st <= S_R1; else st <= S_PACK; end
			default: begin p <= 7'd64; emin <= -18'sd16383; emax <= 18'sd16383; if (ca == C_NORM) st <= S_R1; else st <= S_PACK; end
			endcase
		end

		OP_PDEC: begin
			// mantisa decimal (17 digitos) a binario; exponente a i_out
			rs  <= raw_in[95];
			bin <= 64'd0;
			cnt <= 16'd0;
			if (raw_in[91:80] == 12'hFFF) begin
				rcls <= (raw_in[67:0] == 68'd0) ? C_INF : C_NAN;
				rm <= {1'b0, 1'b1, raw_in[62:0], 3'b0};
				i_we <= 1'b1; i_out <= 32'sd0;
				st <= S_FIN;
			end else st <= S_PDEC;
		end

		OP_PENC: begin
			r_we <= 1'b0;
			rs <= sa; rcls <= ca;
			bin  <= (ca == C_NORM) ? int_mag_a : 64'd0;
			bine <= i_in[31] ? 13'(-i_in) : i_in[12:0];
			bcd  <= 68'd0;
			bcde <= 16'd0;
			cnt  <= 16'd0;
			st   <= S_PENC;
		end

		default: st <= S_FIN;
		endcase
	end

	//-----------------------------------------------------------------------
	// Suma y resta
	//-----------------------------------------------------------------------
	S_ALIGN: begin
		if (ea >= eb) begin
			re <= ea;
			mb <= rsh_st(mb, ea - eb);
		end else begin
			re <= eb;
			ma <= rsh_st(ma, eb - ea);
		end
		st <= S_ADD;
	end

	S_ADD: begin : add_blk
		reg sbe;
		reg [68:0] d;
		sbe = sb ^ (o != OP_ADD);
		if (sa == sbe) begin
			rm <= ma + mb;
			rs <= sa;
		end else begin
			d = {1'b0, ma} - {1'b0, mb};
			if (d[68]) begin rm <= mb - ma; rs <= sbe; end
			else begin rm <= d[67:0]; rs <= sa; end
			if (ma == mb) begin
				rcls <= C_ZERO;
				rs   <= (mode == 2'd2);
			end
		end
		st <= (sa != sbe && ma == mb) ? S_FIN : S_NORM;
	end

	//-----------------------------------------------------------------------
	// Producto: 64 x 16 por ciclo
	//-----------------------------------------------------------------------
	S_MUL: begin : mul_blk
		reg [79:0] pp;
		pp = {16'd0, ma[66:3]} * {64'd0, mb[3 + 16 * cnt[1:0] +: 16]};
		if (cnt == 16'd4) begin
			// producto en [1,4) * 2^126: [127] vale 2, [126] vale 1
			rm <= {acc[127:61], |acc[60:0]};
			st <= S_NORM;
		end else begin
			acc <= acc + ({48'd0, pp} << (16 * cnt[1:0]));
			cnt <= cnt + 16'd1;
		end
	end

	//-----------------------------------------------------------------------
	// Division con restauracion: 67 bits de cociente
	//-----------------------------------------------------------------------
	S_DIV: begin : div_blk
		reg [69:0] t;
		t = rem - {2'b00, mb};
		if (!t[69]) begin rem <= {t[68:0], 1'b0}; q <= {q[66:0], 1'b1}; end
		else        begin rem <= {rem[68:0], 1'b0}; q <= {q[66:0], 1'b0}; end
		cnt <= cnt + 16'd1;
		if (cnt == 16'd66) st <= S_IEXT;
	end

	// fin de la division: el sticky es el resto
	S_IEXT: begin
		rm <= {1'b0, q[66:1], q[0] | (rem != 70'd0)};
		st <= S_NORM;
	end

	//-----------------------------------------------------------------------
	// Raiz cuadrada bit a bit: 67 bits
	//-----------------------------------------------------------------------
	S_SQRT: begin : sqrt_blk
		reg [69:0] r2, trial;
		r2    = {rem[67:0], acc[127:126]};
		trial = {q[67:0], 2'b01};
		acc   <= {acc[125:0], 2'b00};
		if (r2 >= trial) begin rem <= r2 - trial; q <= {q[66:0], 1'b1}; end
		else             begin rem <= r2;         q <= {q[66:0], 1'b0}; end
		cnt <= cnt + 16'd1;
		if (cnt == 16'd66) st <= S_IEXT;
	end

	//-----------------------------------------------------------------------
	// FMOD / FREM: un bit de cociente por ciclo, ea - eb + 1 ciclos
	//-----------------------------------------------------------------------
	S_REM: begin : rem_blk
		reg [69:0] t;
		if (ea < eb) begin
			// |a| < |b|: cociente 0. FREM con |a| > |b|/2 (ea = eb - 1 y
			// ma > mb): cociente 1 y resto |b| - |a|, con el signo cambiado
			q_we <= 1'b1;
			re   <= ea;
			rm   <= ma;
			quot <= {sa ^ sb, 7'd0};
			if (o == OP_REM && ea == eb - 18'sd1 && ma > mb) begin
				rm   <= mb - rsh_st(ma, 18'd1);
				re   <= eb;
				rs   <= ~sa;
				quot <= {sa ^ sb, 7'd1};
			end
			st <= S_NORM;
		end else begin
			t = rem - {2'b00, mb};
			if (!t[69]) begin q <= {q[66:0], 1'b1}; rem <= (cnt == ea - eb) ? t : {t[68:0], 1'b0}; end
			else        begin q <= {q[66:0], 1'b0}; rem <= (cnt == ea - eb) ? rem : {rem[68:0], 1'b0}; end
			cnt <= cnt + 16'd1;
			if (cnt == ea - eb) begin re <= eb; st <= S_REM2; end
		end
	end

	// resto < |b| con exponente eb; FREM: cociente al mas cercano (empate a par)
	S_REM2: begin : rem2_blk
		reg round_up;
		round_up = (o == OP_REM) &&
		           (({rem[68:0], 1'b0} > {2'b00, mb}) || ({rem[68:0], 1'b0} == {2'b00, mb} && q[0]));
		q_we <= 1'b1;
		quot <= {sa ^ sb, q[6:0] + {6'd0, round_up}};
		if (round_up) begin
			rm <= mb - rem[67:0];
			rs <= ~sa;
			st <= S_NORM;
		end else begin
			rm <= rem[67:0];
			if (rem == 70'd0) begin rcls <= C_ZERO; st <= S_FIN; end
			else st <= S_NORM;
		end
	end

	//-----------------------------------------------------------------------
	// Normalizar: deja el bit entero en [66]
	//-----------------------------------------------------------------------
	S_NORM: begin
		if (rm == 68'd0) begin
			rcls <= C_ZERO;
			st   <= (o == OP_PACK) ? S_PACK : S_FIN;
		end else begin
			if (rm[67]) begin
				rm <= {1'b0, rm[67:2], rm[1] | rm[0]};
				re <= re + 18'sd1;
			end else begin
				rm <= rm << (lzc68(rm) - 7'd1);
				re <= re - $signed({11'd0, lzc68(rm) - 7'd1});
			end
			st <= S_R1;
		end
	end

	//-----------------------------------------------------------------------
	// Redondeo
	//-----------------------------------------------------------------------
	// R1: por debajo del minimo se desnormaliza (o, en modo entero, se deja
	// en 2^-1 para redondear con 0 bits enteros)
	S_R1: begin
		if (re < emin) begin
			rm   <= rsh_st(rm, emin - re);
			re   <= emin;
			tiny <= !int_mode;
		end
		st <= S_R2;
	end

	// R2: incremento en la posicion del bit menos significativo
	S_R2: begin : r2_blk
		reg [6:0]  pk;
		reg [6:0]  L;
		reg [67:0] lowm;
		reg        lsb, rb, stk, inx, inc;
		pk   = int_mode ? ((re >= 18'sd63) ? 7'd64 : 7'(re + 18'sd1)) : p;
		L    = 7'd67 - pk;
		lowm = ~(68'hF_FFFF_FFFF_FFFF_FFFF << L);
		lsb  = rm[L];
		rb   = (L == 7'd0) ? 1'b0 : rm[L - 7'd1];
		stk  = (L <= 7'd1) ? 1'b0 : |(rm & ~(68'hF_FFFF_FFFF_FFFF_FFFF << (L - 7'd1)));
		inx  = |(rm & lowm);
		case (mode)
			2'd0: inc = rb & (stk | lsb);
			2'd1: inc = 1'b0;
			2'd2: inc = rs & inx;
			default: inc = !rs & inx;
		endcase
		rm <= (rm & ~lowm) + (inc ? (68'd1 << L) : 68'd0);
		if (inx) begin
			exc[1] <= 1'b1;                     // INEX2
			if (tiny) exc[3] <= 1'b1;           // UNFL
		end
		st <= S_R3;
	end

	// R3: acarreo, desbordamiento y cero
	S_R3: begin
		if (rm[67]) begin
			rm <= {1'b0, rm[67:1]};
			re <= re + 18'sd1;
		end
		st <= S_RENO;
		if (rm == 68'd0) begin
			rcls <= C_ZERO;
			st   <= (o == OP_PACK) ? S_PACK : S_FIN;
		end else if (!int_mode && (re > emax || (re == emax && rm[67]))) begin
			exc[4] <= 1'b1; exc[1] <= 1'b1;     // OVFL, INEX2
			re <= emax;
			if (mode == 2'd0 || (mode == 2'd2 && rs) || (mode == 2'd3 && !rs))
				rcls <= C_INF;
			else
				rm <= ((68'd1 << p) - 68'd1) << (7'd67 - p);   // p unos desde [66]
			st <= (o == OP_PACK) ? S_PACK : S_FIN;
		end
	end

	// RENO: los desnormales vuelven a normalizarse para guardarlos (salvo PACK)
	S_RENO: begin
		if (!no_reno && !rm[66] && rm != 68'd0) begin
			rm <= rm << (lzc68(rm) - 7'd1);
			re <= re - $signed({11'd0, lzc68(rm) - 7'd1});
		end
		st <= (o == OP_PACK) ? S_PACK :
		      (o == OP_F2I)  ? S_PACK : S_FIN;
	end

	//-----------------------------------------------------------------------
	// Empaquetar a memoria (y F2I)
	//-----------------------------------------------------------------------
	S_PACK: begin : pack_blk
		reg [63:0] mag;
		reg        ovf;
		mag = (rcls == C_ZERO) ? 64'd0 : int_mag;
		if (o == OP_F2I || f == 3'd0 || f == 3'd4 || f == 3'd6) begin
			// entero: comprobar el rango (-2^(n-1) .. 2^(n-1)-1)
			ovf = (rcls == C_NAN) || (rcls == C_INF) || (re > 18'sd62) ||
			      ((f == 3'd6 && o != OP_F2I) ? (mag > (rs ? 64'd128 : 64'd127)) :
			       (f == 3'd4 && o != OP_F2I) ? (mag > (rs ? 64'd32768 : 64'd32767)) :
			                                    (mag > (rs ? 64'h8000_0000 : 64'h7FFF_FFFF)));
			if (o == OP_F2I) begin
				i_we  <= 1'b1;
				i_out <= ovf ? (rs ? 32'sh8000_0000 : 32'sh7FFF_FFFF) : rs ? -$signed(mag[31:0]) : $signed(mag[31:0]);
				exc[1] <= 1'b0;
			end else begin
				if (ovf) exc[5] <= 1'b1;   // OPERR
				case (f)
				3'd6: raw_out <= {ovf ? (rs ? 8'h80 : 8'h7F) : (rs ? -mag[7:0] : mag[7:0]), 88'd0};
				3'd4: raw_out <= {ovf ? (rs ? 16'h8000 : 16'h7FFF) : (rs ? -mag[15:0] : mag[15:0]), 80'd0};
				default: raw_out <= {ovf ? (rs ? 32'h8000_0000 : 32'h7FFF_FFFF) : (rs ? -mag[31:0] : mag[31:0]), 64'd0};
				endcase
			end
		end else case (f)
			3'd1: case (rcls)
				C_ZERO: raw_out <= {rs, 31'd0, 64'd0};
				C_INF:  raw_out <= {rs, 8'hFF, 23'd0, 64'd0};
				C_NAN:  raw_out <= {rs, 8'hFF, 1'b1, rm[64:43], 64'd0};
				default: raw_out <= {rs, rm[66] ? 8'(re + 18'sd127) : 8'd0, rm[65:43], 64'd0};
				endcase
			3'd5: case (rcls)
				C_ZERO: raw_out <= {rs, 63'd0, 32'd0};
				C_INF:  raw_out <= {rs, 11'h7FF, 52'd0, 32'd0};
				C_NAN:  raw_out <= {rs, 11'h7FF, 1'b1, rm[64:14], 32'd0};
				default: raw_out <= {rs, rm[66] ? 11'(re + 18'sd1023) : 11'd0, rm[65:14], 32'd0};
				endcase
			default: case (rcls)
				C_ZERO: raw_out <= {rs, 15'd0, 16'd0, 64'd0};
				C_INF:  raw_out <= {rs, 15'h7FFF, 16'd0, 64'd0};
				C_NAN:  raw_out <= {rs, 15'h7FFF, 16'd0, 1'b1, 1'b1, rm[64:3]};
				default: raw_out <= {rs, rm[66] ? 15'(re + 18'sd16383) : 15'd0, 16'd0, rm[66:3]};
				endcase
		endcase
		st <= S_FIN;
	end

	//-----------------------------------------------------------------------
	// Decimal empaquetado
	//-----------------------------------------------------------------------
	// PDEC: 17 digitos (d0 en raw[67:64], d1..d16 en raw[63:0]) a binario
	S_PDEC: begin
		bin <= (bin << 3) + (bin << 1) + {60'd0, raw_in[67 - 4 * cnt[4:0] -: 4]};
		cnt <= cnt + 16'd1;
		if (cnt == 16'd16) begin
			st <= S_PDF;
		end
	end

	// PDF (tras PDEC): mantisa binaria al formato interno y exponente
	S_PDF: begin : pdec_fin
		reg [11:0] e3;
		reg signed [31:0] ed;
		e3 = raw_in[91:80];
		ed = 32'(e3[11:8]) * 32'sd100 + 32'(e3[7:4]) * 32'sd10 + 32'(e3[3:0]);
		i_we  <= 1'b1;
		i_out <= (raw_in[94] ? -ed : ed) - 32'sd16;
		if (bin == 64'd0) begin rcls <= C_ZERO; st <= S_FIN; end
		else begin
			rm <= {1'b0, bin, 3'b0};
			re <= 18'sd63;
			p <= 7'd64; emin <= -18'sd131071; emax <= 18'sd131071;
			st <= S_NORM;
		end
	end

	// PENC: binario a BCD (doble dabble), un bit por ciclo
	S_PENC: begin : penc_blk
		reg [67:0] d;
		reg [15:0] de;
		integer k;
		d  = bcd;
		de = bcde;
		for (k = 0; k < 17; k = k + 1)
			if (d[4*k +: 4] >= 4'd5) d[4*k +: 4] = d[4*k +: 4] + 4'd3;
		for (k = 0; k < 4; k = k + 1)
			if (de[4*k +: 4] >= 4'd5) de[4*k +: 4] = de[4*k +: 4] + 4'd3;
		bcd  <= {d[66:0], bin[63]};
		bin  <= {bin[62:0], 1'b0};
		if (cnt < 16'd13) begin
			bcde <= {de[14:0], bine[12]};
			bine <= {bine[11:0], 1'b0};
		end
		cnt <= cnt + 16'd1;
		if (cnt == 16'd63) st <= S_PFIN;
	end

	S_PFIN: begin : penc_fin
		reg [67:0] digits;
		// digitos alineados a la izquierda (LEN digitos significativos)
		digits = bcd << (4 * (5'd17 - i_len));
		case (rcls)
		C_ZERO: raw_out <= {rs, 1'b0, 2'b00, 12'd0, 16'd0, 64'd0};
		C_INF:  raw_out <= {rs, 1'b1, 2'b11, 12'hFFF, 16'd0, 64'd0};
		C_NAN:  raw_out <= {rs, 1'b1, 2'b11, 12'hFFF, 16'd0, a[63:0]};
		default: raw_out <= {rs, i_in[31], 2'b00, bcde[11:0], bcde[15:12], 8'd0, digits[67:64], digits[63:0]};
		endcase
		st <= S_FIN;
	end

	//-----------------------------------------------------------------------
	S_FIN: begin
		r  <= {rcls, rs, (rcls == C_NORM) ? re : 18'sd0,
		       (rcls == C_NORM || rcls == C_NAN) ? rm[66:3] : 64'd0};
		if (rcls == C_INF) r[63:0] <= 64'd0;
		cc <= {rs, rcls == C_ZERO, rcls == C_INF, rcls == C_NAN};
		done <= 1'b1;
		st <= S_IDLE;
	end

	default: st <= S_IDLE;
	endcase
end

// PENC: magnitud entera de a (a ya es entero, menor que 10^17)
wire [63:0] int_mag_a = (ea < 0) ? 64'd0 : (ma[66:3] >> (7'd63 - ea[6:0]));

endmodule

`default_nettype wire
