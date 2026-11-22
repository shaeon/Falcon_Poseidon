//============================================================================
// Falcon030 para Poseidon - puerto DDR3 de MiSTer sobre la SDRAM de la placa
//
// falcon_memarb habla con la DDR3 de MiSTer: palabras de 64 bits, una orden
// pendiente cada vez, lecturas de 1 o 4 palabras (BURSTCNT) y escrituras de
// una palabra con byte enables. Este modulo hace de esa DDR3 sobre una SDRAM
// de 16 bits, sin tocar el arbitro.
//
// Dos relojes del mismo PLL, en fase:
//   clk     32 MHz, el del sistema (lado DDRAM_*)
//   clk_mem 96 MHz, la SDRAM (3 x clk)
// Al ser multiplos exactos y en fase, los cruces son sincronos y TimeQuest
// los analiza con 10,4 ns; todo lo que cruza sale de un registro.
//
// Protocolo con el arbitro (el de Avalon que usa MiSTer):
//   - la orden (RD o WE) se acepta en el flanco en que DDRAM_BUSY esta a 0;
//   - BUSY se queda a 1 hasta que la orden termina: en las escrituras hasta
//     que la SDRAM tiene el dato, en las lecturas hasta la ultima palabra;
//   - las palabras leidas salen una por ciclo con DDRAM_DOUT_READY.
//
// SDRAM: CAS 3, rafaga de 4 (una palabra de 64 bits = 4 x 16), siempre con
// autoprecarga, asi que entre ordenes todos los bancos estan cerrados.
//   palabra de 64 bits w[20:0] -> media palabra hw = {w, 2'b00}
//   columna = hw[COL_BITS-1:0], banco = hw[COL_BITS+1:COL_BITS], fila = resto
// Una rafaga de 4 palabras son 16 columnas alineadas: misma fila siempre.
//
// Tiempos a 96 MHz (10,4 ns): tRCD 2, tRP 2, tRC 7, tRFC 8, tWR 2.
//============================================================================
`default_nettype none

module falcon_sdram #(
	parameter COL_BITS = 9,          // 9: 32 MB (8192 x 512 x 4); 8: 16 MB
	parameter RD_LAT   = 5,          // ciclos de clk_mem de la orden READ al dato en dq_in
	parameter MEM_HZ   = 96_000_000
) (
	input  wire        clk,
	input  wire        clk_mem,
	input  wire        init,          // a 1 hasta que el PLL engancha

	// lado DDR3 de MiSTer (clk)
	output wire        DDRAM_BUSY,
	input  wire  [7:0] DDRAM_BURSTCNT,
	input  wire [28:0] DDRAM_ADDR,
	output reg  [63:0] DDRAM_DOUT,
	output reg         DDRAM_DOUT_READY,
	input  wire        DDRAM_RD,
	input  wire [63:0] DDRAM_DIN,
	input  wire  [7:0] DDRAM_BE,
	input  wire        DDRAM_WE,

	// pines (clk_mem)
	output reg  [12:0] SDRAM_A,
	inout  wire [15:0] SDRAM_DQ,
	output reg         SDRAM_DQML,
	output reg         SDRAM_DQMH,
	output wire        SDRAM_nWE,
	output wire        SDRAM_nCAS,
	output wire        SDRAM_nRAS,
	output wire        SDRAM_nCS,
	output reg   [1:0] SDRAM_BA,
	output wire        SDRAM_CKE
);

//---------------------------------------------------------------------------
// Lado del sistema
//---------------------------------------------------------------------------
reg        busy = 1'b0;
wire       ready;                 // la SDRAM ha terminado el arranque (clk_mem)
reg        ready_s = 1'b0;
assign DDRAM_BUSY = busy | ~ready_s;

reg        req_t = 1'b0;          // cambia con cada orden aceptada
reg [20:0] r_addr;
reg [63:0] r_din;
reg  [7:0] r_be;
reg        r_we;
reg        r_burst;

wire       done_t;                // cambia cuando la SDRAM termina (clk_mem)
reg        done_s = 1'b0;         // done_t registrado en clk
reg        done_seen = 1'b0;
reg        emit = 1'b0;
reg  [1:0] beat;

(* ramstyle = "logic" *) reg [63:0] rbuf [0:3];            // escrito en clk_mem, leido aqui

always @(posedge clk) begin
	DDRAM_DOUT_READY <= 1'b0;
	done_s  <= done_t;
	ready_s <= ready;

	if (!busy && ready_s && (DDRAM_RD || DDRAM_WE)) begin
		r_addr  <= DDRAM_ADDR[20:0];
		r_din   <= DDRAM_DIN;
		r_be    <= DDRAM_BE;
		r_we    <= DDRAM_WE;
		r_burst <= DDRAM_RD && (DDRAM_BURSTCNT != 8'd1);
		req_t   <= ~req_t;
		busy    <= 1'b1;
		beat    <= 2'd0;
	end

	if (busy && !emit && done_s != done_seen) begin
		done_seen <= done_s;
		if (r_we) busy <= 1'b0;
		else      emit <= 1'b1;
	end

	if (emit) begin
		DDRAM_DOUT       <= rbuf[beat];
		DDRAM_DOUT_READY <= 1'b1;
		beat             <= beat + 2'd1;
		if (!r_burst || beat == 2'd3) begin
			emit <= 1'b0;
			busy <= 1'b0;
		end
	end
end

//---------------------------------------------------------------------------
// Lado de la SDRAM
//---------------------------------------------------------------------------
// nCS, nRAS, nCAS, nWE
localparam [3:0] CMD_NOP   = 4'b0111,
                 CMD_ACT   = 4'b0011,
                 CMD_READ  = 4'b0101,
                 CMD_WRITE = 4'b0100,
                 CMD_PRE   = 4'b0010,
                 CMD_REF   = 4'b0001,
                 CMD_LMR   = 4'b0000;

// modo: rafaga de 4 secuencial, CAS 3, escrituras en rafaga
localparam [12:0] MODE = 13'b000_0_00_011_0_010;

reg [3:0] cmd = CMD_NOP;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
assign SDRAM_CKE = 1'b1;

reg [15:0] dq_out;
reg        dq_oe = 1'b0;
assign SDRAM_DQ = dq_oe ? dq_out : 16'bZ;

// Registro de entrada sin logica delante: va al registro del propio pin
// (FAST_INPUT_REGISTER en el .qsf)
reg [15:0] dq_in;
always @(posedge clk_mem) dq_in <= SDRAM_DQ;

localparam [2:0] S_INIT = 3'd0, S_IDLE = 3'd1, S_RD = 3'd2, S_WR = 3'd3, S_WAIT = 3'd4;
reg  [2:0] st = S_INIT;
reg [15:0] cnt = 16'd0;           // contador de pasos dentro de cada estado
reg  [3:0] istep = 4'd0;

reg        req_s = 1'b0, req_seen = 1'b0;
reg        done_r = 1'b0;
assign done_t = done_r;
reg        ready_r = 1'b0;
assign ready = ready_r;

// copia de la orden en este dominio (estable desde que cambia req_t)
reg [20:0] m_addr;
reg [63:0] m_din;
reg  [7:0] m_be;
reg        m_burst;

wire [22:0] hw   = {m_addr, 2'b00};
wire [12:0] row  = hw[22 -: (21 - COL_BITS)] ;
wire  [1:0] bank = hw[COL_BITS +: 2];
wire  [8:0] col0 = hw[COL_BITS-1:0];

// refresco: 8192 filas cada 64 ms -> una cada 7,8 us; se pide cada 7 us
localparam integer REF_CYC  = MEM_HZ / 142_857;
localparam integer INIT_CYC = MEM_HZ / 5_000;         // 200 us
reg [10:0] ref_cnt = 11'd0;
reg        ref_due = 1'b0;

wire [1:0] wbeat = cnt[1:0] - 2'd2;   // dato de escritura en cnt = 2..5
reg  [4:0] rd_n;                  // medias palabras leidas
localparam integer RD_FIRST = 2 + RD_LAT;   // ciclo en que llega la primera

always @(posedge clk_mem) begin
	cmd   <= CMD_NOP;
	dq_oe <= 1'b0;
	req_s <= req_t;

	if (ref_cnt == REF_CYC[10:0]) begin
		ref_cnt <= 11'd0;
		ref_due <= 1'b1;
	end else
		ref_cnt <= ref_cnt + 11'd1;

	if (init) begin
		st         <= S_INIT;
		ready_r    <= 1'b0;
		cnt        <= 16'd0;
		istep      <= 4'd0;
		SDRAM_DQML <= 1'b1;
		SDRAM_DQMH <= 1'b1;
	end else case (st)

	// arranque: 200 us quieta, precarga de todo, dos refrescos y el modo
	S_INIT: begin
		cnt <= cnt + 16'd1;
		case (istep)
		4'd0: if (cnt == INIT_CYC[15:0]) begin
				cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1; istep <= 4'd1; cnt <= 16'd0;
			end
		4'd1: if (cnt == 16'd3) begin cmd <= CMD_REF; istep <= 4'd2; cnt <= 16'd0; end
		4'd2: if (cnt == 16'd9) begin cmd <= CMD_REF; istep <= 4'd3; cnt <= 16'd0; end
		4'd3: if (cnt == 16'd9) begin
				cmd <= CMD_LMR; SDRAM_A <= MODE; SDRAM_BA <= 2'b00; istep <= 4'd4; cnt <= 16'd0;
			end
		default: if (cnt == 16'd3) begin
				st <= S_IDLE; ready_r <= 1'b1;
				SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
			end
		endcase
	end

	S_IDLE: begin
		cnt <= 16'd0;
		if (ref_due) begin
			cmd     <= CMD_REF;
			ref_due <= 1'b0;
			st      <= S_WAIT;
			istep   <= 4'd8;              // tRFC
		end
		else if (req_s != req_seen) begin
			req_seen <= req_s;
			m_addr   <= r_addr;
			m_din    <= r_din;
			m_be     <= r_be;
			m_burst  <= r_burst;
			st       <= r_we ? S_WR : S_RD;
		end
	end

	// ACT en 0, READ en 2, 6, 10, 14 (la ultima con autoprecarga);
	// el dato de la orden del ciclo c esta en dq_in en c + RD_LAT
	S_RD: begin
		cnt <= cnt + 16'd1;
		case (cnt[5:0])
		6'd0: begin cmd <= CMD_ACT; SDRAM_A <= row; SDRAM_BA <= bank; rd_n <= 5'd0; end
		6'd2, 6'd6, 6'd10, 6'd14:
			if (cnt[5:0] == 6'd2 || m_burst) begin
				cmd <= CMD_READ;
				SDRAM_A <= 13'd0;
				// las rafagas llegan alineadas a 32 bytes: col0 es multiplo de 16
				SDRAM_A[8:0] <= col0 | {5'd0, cnt[3:0] - 4'd2};
				SDRAM_A[10] <= (!m_burst || cnt[5:0] == 6'd14);
			end
		default: ;
		endcase

		if (cnt[5:0] >= RD_FIRST && rd_n != (m_burst ? 5'd16 : 5'd4)) begin
			rbuf[rd_n[3:2]][16 * rd_n[1:0] +: 16] <= dq_in;
			rd_n <= rd_n + 5'd1;
			if (rd_n == (m_burst ? 5'd15 : 5'd3)) begin
				done_r <= ~done_r;
				st     <= S_IDLE;
			end
		end
	end

	// ACT en 0, WRITE con autoprecarga en 2 y los cuatro datos en 2..5;
	// la escritura se da por hecha al dar la orden (el siguiente ACT espera
	// en S_WAIT a tWR + tRP)
	S_WR: begin
		cnt <= cnt + 16'd1;
		case (cnt[2:0])
		3'd0: begin cmd <= CMD_ACT; SDRAM_A <= row; SDRAM_BA <= bank; end
		3'd2: begin
			cmd <= CMD_WRITE;
			SDRAM_A <= 13'd0; SDRAM_A[8:0] <= col0; SDRAM_A[10] <= 1'b1;
			done_r <= ~done_r;
		end
		default: ;
		endcase
		if (cnt[2:0] >= 3'd2 && cnt[2:0] <= 3'd5) begin
			dq_oe  <= 1'b1;
			dq_out <= m_din[16 * wbeat +: 16];
			{SDRAM_DQMH, SDRAM_DQML} <= ~m_be[2 * wbeat +: 2];
		end
		if (cnt[2:0] == 3'd5) begin
			st    <= S_WAIT;
			istep <= 4'd5;                // tWR 2 + tRP 2 + margen
		end
	end

	S_WAIT: begin
		{SDRAM_DQMH, SDRAM_DQML} <= 2'b00;
		if (istep == 4'd0) st <= S_IDLE;
		else istep <= istep - 4'd1;
	end

	default: st <= S_INIT;
	endcase
end

endmodule

`default_nettype wire
