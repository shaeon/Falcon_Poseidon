//============================================================================
// Falcon030 para Poseidon - reloj de pixel real para los modos VGA
//
// En los modos de monitor VGA el Videl cuenta los puntos a 25,175 MHz con un
// acumulador fraccionario sobre los 32 MHz del sistema: cada punto dura 1 o 2
// ciclos (31 o 62 ns) en vez de 39,7 ns. MiSTer no lo nota porque su
// escalador vuelve a muestrear la imagen; aqui saldria tal cual por la VGA y
// el monitor (o el OSSC) veria columnas de anchos distintos.
//
// Todas las salidas del Videl (color, sincronismos, blanking) cambian solo
// con ce_pix, asi que se escriben en una FIFO con ce_pix y se leen con un
// reloj de pixel de verdad: clk_pix = clk_sys x 48/61 (25,205 MHz, salida c3
// del mismo PLL), la misma relacion que usa el acumulador del Videl, que en
// la Poseidon se parchea a 48/61 (common/build_id.tcl). La FIFO no deriva:
// todas las lineas salen con la misma duracion, sin saltar ni repetir puntos (como el FP-1100 y el
// NewBrain, con relojes de relacion exacta). Solo se recoloca el puntero de
// lectura al arrancar o al cambiar de modo, cuando la ocupacion se sale de
// margen.
//
// Clase del modo, medida en cada linea (ciclos de 32 MHz por pixel):
//   1,00 / 2,00 / 4,00 -> base de 32 MHz (RGB, TV, mono): camino directo
//   1,27 / 2,54 / 5,08 -> base de 25,175 MHz (VGA): esta FIFO, leyendo un
//                         pixel cada 1, 2 o 4 ciclos de clk_pix
// use25 cambia cuando 8 lineas seguidas dan la misma clase.
//============================================================================
`default_nettype none

module falcon_vga_resync (
	input  wire       clk,          // 32 MHz
	input  wire       reset,
	input  wire       ce_pix,
	input  wire [5:0] r_in, g_in, b_in,
	input  wire       hs_in, vs_in, hb_in, vb_in,
	output reg        use25 = 1'b0, // (clk) la imagen debe salir por clk_pix

	input  wire       clk_pix,      // 25,205 MHz, 48/61 de clk
	output reg  [5:0] r, g, b,
	output reg        hs, vs, hb, vb
);

//---------------------------------------------------------------------------
// Clasificacion (clk)
//---------------------------------------------------------------------------
reg        hb_d;
reg [11:0] cyc = 12'd0;
reg [10:0] pix = 11'd0;
reg  [2:0] cls_last = 3'd0;
reg  [2:0] cls_run  = 3'd0;
reg  [1:0] div_w = 2'd0;          // log2 de puntos por pixel en la base 25

wire [19:0] c100 = cyc * 7'd100;
function automatic [2:0] classify(input [19:0] c, input [10:0] p);
	// 0: 32/1  1: 25/1  2: 32/2  3: 25/2  4: 32/4  5: 25/4  6: otro
	if      (c < p * 10'd113) classify = 3'd0;
	else if (c < p * 10'd160) classify = 3'd1;
	else if (c < p * 10'd227) classify = 3'd2;
	else if (c < p * 10'd320) classify = 3'd3;
	else if (c < p * 10'd450) classify = 3'd4;
	else if (c < p * 10'd600) classify = 3'd5;
	else                      classify = 3'd6;
endfunction
wire [2:0] cls_now = classify(c100, pix);

always @(posedge clk) begin
	if (ce_pix) hb_d <= hb_in;
	if (~&cyc) cyc <= cyc + 12'd1;
	if (ce_pix && ~&pix) pix <= pix + 11'd1;

	// una linea entera: de subida a subida del borrado horizontal
	if (ce_pix && hb_in && !hb_d) begin
		cyc <= 12'd1;
		pix <= 11'd1;
		cls_last <= cls_now;
		if (cls_now != cls_last) cls_run <= 3'd0;
		else if (cls_run != 3'd7) cls_run <= cls_run + 3'd1;
		if (cls_run == 3'd6 && cls_now == cls_last) begin
			use25 <= cls_now[0] && cls_now != 3'd6 && cls_now != 3'd7;
			div_w <= cls_now[2:1];
		end
	end

	if (reset) use25 <= 1'b0;
end

//---------------------------------------------------------------------------
// FIFO de 256 muestras {hb, vb, hs, vs, r, g, b}
//---------------------------------------------------------------------------
reg [21:0] mem [0:255];
reg  [7:0] wptr = 8'd0;
reg  [7:0] wgray = 8'd0;

always @(posedge clk) if (ce_pix) begin
	mem[wptr] <= {hb_in, vb_in, hs_in, vs_in, r_in, g_in, b_in};
	wptr  <= wptr + 8'd1;
	wgray <= (wptr + 8'd1) ^ ((wptr + 8'd1) >> 1);
end

//---------------------------------------------------------------------------
// Lectura (clk_pix)
//---------------------------------------------------------------------------
reg  [7:0] wg1, wg2;
reg  [1:0] div1, div2;
always @(posedge clk_pix) begin
	wg1 <= wgray; wg2 <= wg1;
	div1 <= div_w; div2 <= div1;
end

function automatic [7:0] gray2bin(input [7:0] g);
	integer i;
	begin
		gray2bin[7] = g[7];
		for (i = 6; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
	end
endfunction

localparam [7:0] TARGET = 8'd96;

reg  [7:0] rptr = 8'd0;
reg  [1:0] rdiv = 2'd0;
reg [21:0] q;
wire [7:0] wbin = gray2bin(wg2);
wire [7:0] occ  = wbin - rptr;

wire       rd_ce = (rdiv == ((2'd1 << div2) - 2'd1)) || (div2 == 2'd0);

always @(posedge clk_pix) begin
	rdiv <= rd_ce ? 2'd0 : rdiv + 2'd1;
	q <= mem[rptr];

	if (rd_ce) begin
		{hb, vb, hs, vs, r, g, b} <= q;
		if (occ < 8'd16 || occ > 8'd240)
			rptr <= wbin - TARGET;                    // arranque o cambio de modo
		else
			rptr <= rptr + 8'd1;
	end
end

endmodule

`default_nettype wire
