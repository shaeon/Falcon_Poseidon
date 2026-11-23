// Banco de pruebas de falcon_vga_resync: un Videl de mentira da 640x480 VGA
// (800 x 525 puntos) con el acumulador de 25,175 MHz sobre 32 MHz, con 1 y 2
// puntos por pixel; se comprueba que a la salida todas las lineas duran
// exactamente 800 puntos y que la parte visible no pierde ni repite pixeles.
`timescale 1ps/1ps
module tb;
reg clk = 0; always #15600 clk = ~clk;                 // ~32 MHz (48 x 325 ps)
reg clk_pix = 0; always #19825 clk_pix = ~clk_pix;     // 61 x 325 ps: 48/61 de clk, como en la placa
integer DOTS = 1;                                       // puntos por pixel
reg [31:0] facc = 0; reg ce_base = 0; reg [1:0] ph = 0; reg ce = 0;
integer hpos = 0, vpos = 0;
reg [5:0] r_in = 0; reg hs_in = 1, vs_in = 1, hb_in = 1, vb_in = 1;
always @(posedge clk) begin
	if (facc + 48 >= 61) begin facc <= facc + 48 - 61; ce_base <= 1; end
	else begin facc <= facc + 48; ce_base <= 0; end
	ce <= 0;
	if (ce_base) begin
		ph = (ph + 1) % DOTS;
		if (ph == 0) begin
			ce <= 1;
			hpos = hpos + DOTS; if (hpos >= 800) begin hpos = 0; vpos = (vpos + 1) % 525; end
			hb_in <= (hpos >= 640); vb_in <= (vpos >= 480);
			hs_in <= !(hpos >= 656 && hpos < 752); vs_in <= !(vpos >= 490 && vpos < 492);
			r_in <= (hpos / DOTS) & 6'h3F;
		end
	end
end
wire use25; wire [5:0] r, g, b; wire hs, vs, hb, vb;
falcon_vga_resync dut (.clk(clk), .reset(1'b0), .ce_pix(ce), .r_in(r_in), .g_in(6'd0), .b_in(6'd0),
	.hs_in(hs_in), .vs_in(vs_in), .hb_in(hb_in), .vb_in(vb_in), .use25(use25),
	.clk_pix(clk_pix), .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .hb(hb), .vb(vb));
integer t = 0, last = 0, lines = 0, errors = 0, minl = 99999, maxl = 0, fixes = 0, n799 = 0, n801 = 0;
reg hb_d = 1; reg [5:0] exp_r; integer col = 0; reg vis_d = 0; integer st = 0;
always @(posedge clk_pix) begin
	t = t + 1; hb_d <= hb;
	if (hb && !hb_d) begin
		if (lines > 50 && use25) begin
			if (t - last < minl) minl = t - last;
			if (t - last > maxl) maxl = t - last;
			if (t - last != 800) fixes = fixes + 1;
		end
		last = t; lines = lines + 1;
	end
	// parte visible: r cuenta de 0 a 639/DOTS, un valor por pixel
	if (!hb && !vb) begin
		if (hb_d) begin col = 0; st = 0; end
		if (st == 0 && lines > 50) begin
			if (r !== (col & 6'h3F)) begin errors = errors + 1; if (errors < 5) $display("ERROR linea %0d col %0d: %0d", lines, col, r); end
		end
		st = (st + 1) % DOTS;   // el lector repite cada pixel DOTS ciclos
		if (st == 0) col = col + 1;
	end
end
initial begin
	DOTS = 1;
	#(64'd20_000_000_000);                         // 20 ms
	$display("1 punto/pixel: use25=%0d lineas %0d, largo %0d..%0d ciclos (%0d lineas corregidas), %0d errores", use25, lines, minl, maxl, fixes, errors);
	DOTS = 2; minl = 99999; maxl = 0; errors = 0; lines = 0; fixes = 0;
	#(64'd20_000_000_000);
	$display("2 puntos/pixel: use25=%0d lineas %0d, largo %0d..%0d ciclos (%0d lineas corregidas), %0d errores", use25, lines, minl, maxl, fixes, errors);
	$finish;
end
endmodule
