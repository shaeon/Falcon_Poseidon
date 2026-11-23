// Banco de pruebas de falcon_fpu_mbox: hace de falcon_fpu_bridge por el
// puerto DDRAM (accesos de 16 bits como el puerto d3 de falcon_memarb)
`timescale 1ns/1ps
module tb;
reg clk = 0; always #15.625 clk = ~clk;
reg reset = 1;
wire busy, rdy; wire [63:0] dout;
reg rd = 0, we = 0; reg [28:0] addr = 0; reg [63:0] din = 0; reg [7:0] be = 0;
falcon_fpu_mbox #(.CLK_HZ(320000)) dut (.clk(clk), .reset(reset),
	.c_BUSY(busy), .c_BURSTCNT(8'd1), .c_ADDR(addr), .c_DOUT(dout), .c_DOUT_READY(rdy),
	.c_RD(rd), .c_DIN(din), .c_BE(be), .c_WE(we),
	.s_BUSY(1'b0), .s_BURSTCNT(), .s_ADDR(), .s_DOUT(64'd0), .s_DOUT_READY(1'b0),
	.s_RD(), .s_DIN(), .s_BE(), .s_WE());

// palabra de 16 bits en el offset off del buzon (orden guest)
task automatic wr16(input [9:0] off, input [15:0] v);
	reg [2:0] k;
	begin
		k = off[2:0];
		@(posedge clk);
		addr <= {8'h06, 21'h1D2000 + off[9:3]};
		din <= 64'd0; din[8*k +: 8] <= v[15:8]; din[8*(k+1) +: 8] <= v[7:0];
		be <= 8'd3 << k; we <= 1;
		@(negedge clk); while (busy) @(negedge clk);   // aceptada en el flanco siguiente
		@(posedge clk); we <= 0;
	end
endtask
task automatic rd16(input [9:0] off, output [15:0] v);
	reg [2:0] k;
	begin
		k = off[2:0];
		@(posedge clk); addr <= {8'h06, 21'h1D2000 + off[9:3]}; rd <= 1;
		@(negedge clk); while (busy) @(negedge clk);
		@(posedge clk); rd <= 0;
		while (!rdy) @(posedge clk);
		v = {dout[8*k +: 8], dout[8*(k+1) +: 8]};
	end
endtask

reg [15:0] seq = 0, st, w;
integer errors = 0, i;
task automatic request(input [15:0] kind, input [15:0] cmd, input [15:0] aux, input [95:0] op);
	begin
		wr16(10'h102, kind); wr16(10'h104, cmd); wr16(10'h106, aux); wr16(10'h108, 16'd12);
		for (i = 0; i < 6; i = i + 1) wr16(10'h110 + 2 * i, op[95 - 16 * i -: 16]);
		seq = seq + 1;
		wr16(10'h100, seq);
		st = 0;
		while (st[15:12] !== seq[3:0]) rd16(10'h200, st);
	end
endtask
reg [95:0] res;
task automatic result;
	for (i = 0; i < 6; i = i + 1) begin rd16(10'h210 + 2 * i, w); res[95 - 16 * i -: 16] = w; end
endtask

initial begin
	repeat (4) @(posedge clk); reset <= 0;
	repeat (20) @(posedge clk);
	rd16(10'h000, w); $display("MAGIC %h", w); if (w != 16'h4650) errors = errors + 1;
	rd16(10'h004, w); $display("VERSION %h", w); if (w != 16'h0004) errors = errors + 1;
	rd16(10'h002, w); repeat (20000) @(posedge clk); rd16(10'h002, st);
	$display("HEARTBEAT %h -> %h", w, st); if (w == st) errors = errors + 1;
	request(2, 0, 0, 0);                                         // reset
	request(4, 0, 0, 0); result; $display("FSAVE tras reset %h", res[95:64]);
	if (res[95:64] !== 32'h00380000) errors = errors + 1;
	request(1, 16'h4800, 0, 96'h3FFF_0000_C000000000000000);    // FMOVE.X 1.5,FP0
	request(1, 16'h4880, 0, 96'h4000_0000_A000000000000000);    // FMOVE.X 2.5,FP1
	request(1, 16'h0422, 0, 0);                                  // FADD FP1,FP0
	request(1, 16'h6800, 0, 0); result;                          // FMOVE.X FP0,<ea>
	$display("1.5 + 2.5 = %h  STATUS %h", res, st);
	if (res !== 96'h4001_0000_8000000000000000) errors = errors + 1;
	request(1, 16'h040E, 0, 0); request(1, 16'h6800, 0, 0); result;   // FSIN FP1,FP0
	$display("sin(2.5) = %h", res);
	if (res !== 96'h3ffe_0000_9935786e7e558405) errors = errors + 1;   // 0,5984721441 (mpmath)
	request(4, 0, 0, 0); result; $display("FSAVE %h", res[95:64]);
	if (res[95:64] !== 32'h1F380000) errors = errors + 1;
	$display("FIN: %0d errores", errors);
	$finish;
end
initial begin #700_000_000; $display("TIMEOUT"); $finish; end
endmodule
