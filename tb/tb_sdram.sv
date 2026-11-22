// Banco de pruebas de falcon_sdram: un modelo del arbitro (falcon_memarb)
// hace lecturas de 1 y 4 palabras y escrituras con byte enables al azar y
// compara con una memoria de referencia; un modelo de SDRAM (CAS 3, rafaga
// de 4) comprueba tRCD y que las ordenes van a la fila abierta.
`timescale 1ns/1ps
module tb;
reg clk = 0, clk_mem = 0;
always #15.625 clk = ~clk;              // 32 MHz
initial begin #0.001; forever #5.2083 clk_mem = ~clk_mem; end   // 96 MHz, en fase
reg init = 1;

wire busy, dready; wire [63:0] dout;
reg rd = 0, we = 0; reg [7:0] bc = 1; reg [28:0] addr = 0; reg [63:0] din = 0; reg [7:0] be = 0;
wire [12:0] A; wire [15:0] DQ; wire dqml, dqmh, nwe, ncas, nras, ncs, cke; wire [1:0] BA;

falcon_sdram #(.COL_BITS(9), .MEM_HZ(96_000_000)) dut (
	.clk(clk), .clk_mem(clk_mem), .init(init),
	.DDRAM_BUSY(busy), .DDRAM_BURSTCNT(bc), .DDRAM_ADDR(addr), .DDRAM_DOUT(dout),
	.DDRAM_DOUT_READY(dready), .DDRAM_RD(rd), .DDRAM_DIN(din), .DDRAM_BE(be), .DDRAM_WE(we),
	.SDRAM_A(A), .SDRAM_DQ(DQ), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_nWE(nwe),
	.SDRAM_nCAS(ncas), .SDRAM_nRAS(nras), .SDRAM_nCS(ncs), .SDRAM_BA(BA), .SDRAM_CKE(cke));

// ---------------- modelo de SDRAM ----------------
reg [15:0] mem [0:(1<<22)-1];           // 8 MB bastan para la prueba (filas 0..2047)
reg [12:0] open_row [0:3]; reg [3:0] open_v = 0; integer act_t [0:3];
integer cyc = 0;
reg [15:0] q [0:15]; reg qv [0:15];
integer i; reg [15:0] dq_drv; reg dq_en = 0;
assign DQ = dq_en ? dq_drv : 16'bZ;
integer wr_left = 0; reg [21:0] wr_a; reg wr_ap; reg [1:0] wr_b;
integer errors = 0;
initial for (i = 0; i < 16; i = i + 1) qv[i] = 0;
function [21:0] maddr(input [1:0] b, input [12:0] r, input [8:0] c);
	maddr = {r[10:0], b, c};
endfunction
always @(posedge clk_mem) begin
	cyc = cyc + 1;
	// salida de lectura: la cola avanza un ciclo
	dq_en  <= qv[0]; dq_drv <= q[0];
	for (i = 0; i < 15; i = i + 1) begin q[i] = q[i+1]; qv[i] = qv[i+1]; end
	qv[15] = 0;
	// datos de escritura
	if (wr_left > 0) begin
		if (!dqml) mem[wr_a][7:0]  = DQ[7:0];
		if (!dqmh) mem[wr_a][15:8] = DQ[15:8];
		wr_a = wr_a + 1; wr_left = wr_left - 1;
		if (wr_left == 0 && wr_ap) open_v[wr_b] = 0;
	end
	case ({ncs, nras, ncas, nwe})
	4'b0011: begin
		if (open_v[BA]) begin $display("ERROR %0d: ACT a banco abierto", cyc); errors = errors + 1; end
		open_row[BA] = A; open_v[BA] = 1; act_t[BA] = cyc;
	end
	4'b0101, 4'b0100: begin
		if (!open_v[BA]) begin $display("ERROR %0d: READ/WRITE a banco cerrado", cyc); errors = errors + 1; end
		if (cyc - act_t[BA] < 2) begin $display("ERROR %0d: tRCD", cyc); errors = errors + 1; end
		if (nwe) begin
			// el modelo ve la orden un ciclo despues (la SDRAM real, medio ciclo):
			// el dato en la pata en (E+2, E+3]: dq_in lo coge en E+3 (RD_LAT 5)
			for (i = 0; i < 4; i = i + 1) begin
				q[1 + i] = mem[maddr(BA, open_row[BA], {A[8:2], 2'b00} + i)];
				qv[1 + i] = 1;
			end
			if (A[10]) open_v[BA] = 0;
		end else begin
			wr_a = maddr(BA, open_row[BA], A[8:0]); wr_b = BA; wr_ap = A[10];
			if (!dqml) mem[wr_a][7:0]  = DQ[7:0];
			if (!dqmh) mem[wr_a][15:8] = DQ[15:8];
			wr_a = wr_a + 1; wr_left = 3;
		end
	end
	4'b0010: if (A[10]) open_v = 0; else open_v[BA] = 0;
	4'b0001: if (|open_v) begin $display("ERROR %0d: REF con bancos abiertos", cyc); errors = errors + 1; end
	default: ;
	endcase
end

// ---------------- modelo del arbitro ----------------
reg [63:0] ref_m [0:4095];              // palabras 0..4095 de cada una de 4 zonas
function [20:0] waddr(input [11:0] k);  // reparte por filas y bancos
	waddr = {8'd0, k[11:8], k[7:6], 1'b0, k[5:0]};   // 16 filas x 4 bancos
endfunction
integer n, j, k, beats; reg [63:0] exp_w, nw; reg [7:0] rbe;
// busy a mitad de ciclo = el valor que ve el flanco siguiente
reg busy_n = 1;
always @(negedge clk) busy_n = busy;
task automatic cmd_wait;          // vuelve justo despues del flanco que acepta la orden
	@(posedge clk); while (busy_n) @(posedge clk);
	rd <= 0; we <= 0;
endtask
task automatic beat_wait;         // vuelve despues del flanco con DOUT_READY
	@(posedge clk); while (!dready) @(posedge clk);
endtask
initial begin
	for (k = 0; k < 4096; k = k + 1) ref_m[k] = 64'd0;
	for (k = 0; k < (1<<22); k = k + 1) mem[k] = 16'd0;
	repeat (10) @(posedge clk); init <= 0;
	for (n = 0; n < 6000; n = n + 1) begin
		@(posedge clk);
		k = $urandom % 4096;
		case ($urandom % 3)
		0: begin    // escritura de una palabra
			nw = {$urandom, $urandom}; rbe = $urandom;
			if (rbe == 0) rbe = 8'h01;
			for (j = 0; j < 8; j = j + 1) if (rbe[j]) ref_m[k][8*j +: 8] = nw[8*j +: 8];
			addr <= {8'h06, waddr(k)}; din <= nw; be <= rbe; bc <= 1; we <= 1;
			cmd_wait;
		end
		1: begin    // lectura de una palabra
			addr <= {8'h06, waddr(k)}; bc <= 1; rd <= 1; be <= 8'hFF;
			cmd_wait;
			beat_wait;
			if (dout !== ref_m[k]) begin $display("ERROR lectura %0d: %h != %h", k, dout, ref_m[k]); errors = errors + 1; end
		end
		default: begin  // rafaga de 4 alineada
			k = k & ~3;
			addr <= {8'h06, waddr(k)}; bc <= 4; rd <= 1; be <= 8'hFF;
			cmd_wait;
			for (beats = 0; beats < 4; beats = beats + 1) begin
				beat_wait;
				if (dout !== ref_m[k + beats]) begin $display("ERROR rafaga %0d+%0d: %h != %h", k, beats, dout, ref_m[k+beats]); errors = errors + 1; end
			end
		end
		endcase
	end
	$display("FIN: %0d errores, %0d ciclos de memoria", errors, cyc);
	$finish;
end
initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
