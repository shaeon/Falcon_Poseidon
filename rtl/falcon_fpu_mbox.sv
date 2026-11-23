//============================================================================
// Falcon030 para Poseidon - la FPU 68882 en el buzon del puente
//
// En Falcon_MiSTer el 68882 lo calcula un programa del ARM (tools/falcon_fpu)
// que lee y escribe un buzon en la DDR3 (guest $E90000, docs/FPU_ARM.md). El
// puente del core (falcon_fpu_bridge) llega a ese buzon por el puerto d3 de
// falcon_memarb, es decir, por el puerto DDRAM que aqui va a la SDRAM.
//
// Este modulo se pone entre falcon_system y falcon_sdram: los accesos al
// buzon ($E90000-$E903FF) los atiende el con su propia memoria y hace el
// papel del programa del ARM con la FPU de rtl/fpu (fpu_top):
//   +$000 MAGIC $4650  +$002 HEARTBEAT (cada 10 ms)  +$004 VERSION 4
//   peticion: +$100 RSEQ (escrito el ultimo) KIND CMD AUX  +$108 NBYTES
//             +$10A IADDR  +$110 bytes del operando
//   respuesta: +$200 STATUS y FLAGS (escritos los ultimos)  +$210 resultado
// El core no se modifica: solo hay que compilarlo sin FALCON_NO_FPU.
//
// Orden de bytes: en el puerto DDRAM el byte k de una palabra de 64 bits
// (direccion guest 8n + k) va en [8k+7:8k] y en DDRAM_BE[k].
//============================================================================
`default_nettype none

module falcon_fpu_mbox #(
	parameter CLK_HZ = 32_000_000
) (
	input  wire        clk,
	input  wire        reset,

	// del core (falcon_system)
	output wire        c_BUSY,
	input  wire  [7:0] c_BURSTCNT,
	input  wire [28:0] c_ADDR,
	output wire [63:0] c_DOUT,
	output wire        c_DOUT_READY,
	input  wire        c_RD,
	input  wire [63:0] c_DIN,
	input  wire  [7:0] c_BE,
	input  wire        c_WE,

	// a la SDRAM (falcon_sdram)
	input  wire        s_BUSY,
	output wire  [7:0] s_BURSTCNT,
	output wire [28:0] s_ADDR,
	input  wire [63:0] s_DOUT,
	input  wire        s_DOUT_READY,
	output wire        s_RD,
	output wire [63:0] s_DIN,
	output wire  [7:0] s_BE,
	output wire        s_WE
);

// buzon: palabras de 64 bits $1D2000-$1D207F (guest $E90000-$E903FF)
wire sel = (c_ADDR[20:7] == 14'h3A40);

assign s_RD       = c_RD & !sel;
assign s_WE       = c_WE & !sel;
assign s_ADDR     = c_ADDR;
assign s_DIN      = c_DIN;
assign s_BE       = c_BE;
assign s_BURSTCNT = c_BURSTCNT;

reg        m_ready = 1'b0;
wire [63:0] m_q;
reg        v_we = 1'b0, v_rd = 1'b0;   // el servicio usa la memoria este ciclo
assign c_BUSY       = sel ? (v_we | v_rd) : s_BUSY;
assign c_DOUT       = m_ready ? m_q : s_DOUT;
assign c_DOUT_READY = s_DOUT_READY | m_ready;

//---------------------------------------------------------------------------
// Memoria del buzon (128 x 64 bits, con byte enables), un solo puerto. Los
// accesos del servicio (v_we, v_rd) van primero: mientras tanto c_BUSY esta
// a 1 y falcon_memarb espera, como con la DDR3 ocupada.
//---------------------------------------------------------------------------
wire       core_acc = sel && (c_RD || c_WE) && !(v_we || v_rd);

reg  [6:0] v_a;
reg [63:0] v_d;
reg  [7:0] v_be;

wire       p_we = core_acc ? c_WE : v_we;
wire [6:0] p_a  = core_acc ? c_ADDR[6:0] : v_a;
wire [63:0] p_d = core_acc ? c_DIN : v_d;
wire [7:0] p_be = core_acc ? c_BE : v_be;

// un carril de 8 bits por byte (asi Quartus la pone en M9K)
genvar g;
generate for (g = 0; g < 8; g = g + 1) begin : lane
	reg [7:0] m [0:127];
	reg [7:0] q;
	always @(posedge clk) begin
		if (p_we && p_be[g]) m[p_a] <= p_d[8*g +: 8];
		q <= m[p_a];
	end
	assign m_q[8*g +: 8] = q;
end endgenerate

always @(posedge clk) m_ready <= core_acc && c_RD;

// orden guest (byte 0 arriba) <-> orden DDRAM
function automatic [63:0] swap64(input [63:0] x);
	swap64 = {x[7:0], x[15:8], x[23:16], x[31:24], x[39:32], x[47:40], x[55:48], x[63:56]};
endfunction

// el puente escribe RSEQ (+$100) el ultimo
reg        go = 1'b0;
reg [15:0] rseq;
always @(posedge clk) begin
	if (core_acc && c_WE && c_ADDR[6:0] == 7'h20 && c_BE[0]) begin
		go   <= 1'b1;
		rseq <= {c_DIN[7:0], c_DIN[15:8]};
	end
	if (svc_take) go <= 1'b0;
end

//---------------------------------------------------------------------------
// FPU
//---------------------------------------------------------------------------
reg        f_req = 1'b0;
reg  [2:0] f_kind;
reg [15:0] f_cmd, f_aux;
reg [31:0] f_iaddr;
reg        f_obwe = 1'b0;
reg  [2:0] f_obwa;
reg [95:0] f_obwd;
reg  [2:0] f_rbra;
wire [95:0] f_rbrd;
wire       f_ack;
wire [31:0] f_fpcr, f_fpsr;
wire [4:0] f_flags;
wire [7:0] f_vec;

fpu_top fpu (
	.clk(clk), .reset(reset),
	.req(f_req), .kind(f_kind), .cmd(f_cmd), .aux({16'd0, f_aux}),
	.iaddr(f_iaddr), .iaddr_valid(|f_fpcr[14:8]),
	.ob_we(f_obwe), .ob_wa(f_obwa), .ob_wd(f_obwd),
	.rb_ra(f_rbra), .rb_rd(f_rbrd),
	.ack(f_ack), .busy(), .fpcr(f_fpcr), .fpsr(f_fpsr), .fpiar(),
	.exc_pending(), .vector(), .cond_true(), .bsun_exc(), .not_impl(),
	.rflags(f_flags), .rvec(f_vec)
);

//---------------------------------------------------------------------------
// Servicio
//---------------------------------------------------------------------------
localparam [3:0] V_INIT = 4'd0, V_IDLE = 4'd1, V_HDR = 4'd2, V_OBUF = 4'd3,
                 V_REQ = 4'd4, V_WAIT = 4'd5, V_RBUF = 4'd6, V_RES = 4'd7,
                 V_STAT = 4'd8;
reg  [3:0] v = V_INIT;
reg  [4:0] n, got;
reg        rd_pend = 1'b0;          // en el ultimo flanco se leyo: m_q vale
reg [767:0] big;                    // operando o resultado: 96 bytes, orden guest
reg [15:0] hb = 16'd0;
localparam integer HB_CYC = CLK_HZ / 100;
reg [21:0] hb_cnt = 22'd0;
reg        hb_due = 1'b0;

wire       svc_take = (v == V_IDLE) && go;

wire [15:0] status = {rseq[3:0], f_fpsr[27:24],
                      (f_vec >= 8'd48 && f_vec <= 8'd54) ? 3'(f_vec - 8'd48) : 3'd0, f_flags};
wire [15:0] flagsw = {f_vec, 3'd0, f_flags};

always @(posedge clk) begin
	v_we    <= 1'b0;
	v_rd    <= 1'b0;
	rd_pend <= v_rd;
	f_req   <= 1'b0;
	f_obwe  <= 1'b0;

	if (hb_cnt == HB_CYC[21:0]) begin hb_cnt <= 22'd0; hb_due <= 1'b1; end
	else hb_cnt <= hb_cnt + 22'd1;

	if (reset) begin
		v <= V_INIT;
	end else case (v)
	// MAGIC "FP", HEARTBEAT, VERSION 4
	V_INIT: begin
		v_we <= 1'b1; v_a <= 7'h00; v_be <= 8'h3F;
		v_d  <= swap64({16'h4650, hb, 16'h0004, 16'h0000});
		v <= V_IDLE;
	end

	V_IDLE: begin
		n   <= 5'd0;
		got <= 5'd0;
		if (svc_take) v <= V_HDR;
		else if (hb_due) begin
			hb_due <= 1'b0;
			hb <= hb + 16'd1;
			v_we <= 1'b1; v_a <= 7'h00; v_be <= 8'h0C;
			v_d  <= swap64({16'h0000, hb + 16'd1, 32'd0});
		end
	end

	// 14 palabras desde +$100: cabecera (2) y operando (12, desde +$110)
	V_HDR: begin
		if (n != 5'd14) begin
			v_rd <= 1'b1;
			v_a  <= 7'h20 + {2'd0, n};
			n    <= n + 5'd1;
		end
		if (rd_pend) begin
			got <= got + 5'd1;
			case (got)
			5'd0: begin
				f_kind <= m_q[26:24];                  // KIND, bytes 2-3
				f_cmd  <= {m_q[39:32], m_q[47:40]};    // CMD, bytes 4-5
				f_aux  <= {m_q[55:48], m_q[63:56]};    // AUX, bytes 6-7
			end
			5'd1: f_iaddr <= {m_q[23:16], m_q[31:24], m_q[39:32], m_q[47:40]};
			default: big <= {big[703:0], swap64(m_q)};
			endcase
			if (got == 5'd13) begin n <= 5'd0; v <= V_OBUF; end
		end
	end

	V_OBUF: begin
		f_obwe <= 1'b1;
		f_obwa <= n[2:0];
		f_obwd <= big[767 - 96 * n[2:0] -: 96];
		n <= n + 5'd1;
		if (n == 5'd7) v <= V_REQ;
	end

	V_REQ: begin f_req <= 1'b1; v <= V_WAIT; end

	V_WAIT: if (f_ack) begin n <= 5'd0; f_rbra <= 3'd0; v <= V_RBUF; end

	// resultado: 8 trozos de 12 bytes (el bufer de salida tiene un ciclo)
	V_RBUF: begin
		f_rbra <= f_rbra + 3'd1;
		if (n >= 5'd1) big <= {big[671:0], f_rbrd};
		n <= n + 5'd1;
		if (n == 5'd8) begin n <= 5'd0; v <= V_RES; end
	end

	V_RES: begin
		v_we <= 1'b1; v_a <= 7'h42 + {3'd0, n[3:0]}; v_be <= 8'hFF;
		v_d  <= swap64(big[767 - 64 * n[3:0] -: 64]);
		n <= n + 5'd1;
		if (n == 5'd11) v <= V_STAT;
	end

	// STATUS y FLAGS juntos, los ultimos
	V_STAT: begin
		v_we <= 1'b1; v_a <= 7'h40; v_be <= 8'h0F;
		v_d  <= swap64({status, flagsw, 32'd0});
		v <= V_IDLE;
	end

	default: v <= V_IDLE;
	endcase
end

endmodule

`default_nettype wire
