// Banco de pruebas de falcon_sd_bridge con un modelo de user_io: lecturas
// de varios bloques del SCSI, lecturas de ventana, escrituras del IDE y
// lecturas del disquete.
`timescale 1ns/1ps
module tb;
reg clk = 0; always #15.625 clk = ~clk;
reg reset = 1;

reg  [31:0] c_lba [7]; reg [6:0] c_rd = 0, c_wr = 0; reg [5:0] c_blk_cnt [7];
wire [6:0] c_ack; wire [13:0] c_buff_addr; wire [7:0] c_buff_dout; wire c_buff_wr;
reg  [7:0] c_buff_din [7]; wire [6:0] c_img_mounted; wire [63:0] c_img_size;
wire [31:0] m_lba; wire [3:0] m_rd, m_wr; reg m_ack = 0; reg [8:0] m_buff_addr = 0;
reg [7:0] m_dout = 0; reg m_dout_strobe = 0; wire [7:0] m_din; reg [3:0] m_img_mounted = 0; reg [63:0] m_img_size = 0;

falcon_sd_bridge dut (.*);

integer errors = 0, i;
// ---- modelo de user_io: dato = lba ^ direccion ----
reg [31:0] log_lba [0:63]; integer nlog = 0; reg [7:0] wbuf [0:511];
always @(posedge clk) if (|m_rd || |m_wr) begin end
initial begin : uio
	integer b;
	forever begin
		@(posedge clk);
		if (|m_rd || |m_wr) begin
			log_lba[nlog] = m_lba; nlog = nlog + 1;
			repeat (5) @(posedge clk);
			m_ack <= 1; m_buff_addr <= 0;
			if (|m_rd) begin
				for (b = 0; b < 512; b = b + 1) begin
					repeat (3) @(posedge clk);
					m_dout <= m_lba[7:0] ^ b[7:0]; m_dout_strobe <= 1;
					@(posedge clk); m_dout_strobe <= 0; m_buff_addr <= m_buff_addr + 1;
				end
			end else begin
				for (b = 0; b < 512; b = b + 1) begin
					repeat (3) @(posedge clk);
					wbuf[b] = m_din; m_buff_addr <= m_buff_addr + 1;
				end
			end
			repeat (3) @(posedge clk); m_ack <= 0; m_buff_addr <= 0;
		end
	end
end
// ---- lado del core: guarda lo escrito ----
reg [7:0] cmem [0:16383]; integer nwr = 0;
always @(posedge clk) if (c_buff_wr) begin cmem[c_buff_addr] <= c_buff_dout; nwr = nwr + 1; end
always @* for (i = 0; i < 7; i = i + 1) c_buff_din[i] = (c_buff_addr[7:0]) ^ i[7:0];

task automatic req(input [2:0] s, input [31:0] lba, input [5:0] n, input wr);
	c_lba[s] = lba; c_blk_cnt[s] = n;
	@(posedge clk); if (wr) c_wr[s] <= 1; else c_rd[s] <= 1;
	@(posedge clk); while (!c_ack[s]) @(posedge clk);
	c_rd[s] <= 0; c_wr[s] <= 0;
	while (c_ack[s]) @(posedge clk);
endtask

integer k, b;
initial begin
	for (i = 0; i < 7; i = i + 1) begin c_lba[i] = 0; c_blk_cnt[i] = 0; end
	repeat (5) @(posedge clk); reset <= 0;
	// SCSI 0: 3 bloques desde la 100
	nlog = 0; nwr = 0;
	req(3'd4, 32'd100, 6'd2, 0);
	if (nlog != 3 || log_lba[0] != 100 || log_lba[1] != 101 || log_lba[2] != 102) begin $display("ERROR lbas SCSI %0d", nlog); errors = errors + 1; end
	for (k = 0; k < 3; k = k + 1) for (b = 0; b < 512; b = b + 1)
		if (cmem[{k[4:0], b[8:0]}] !== ((8'd100 + k) ^ b[7:0])) begin errors = errors + 1; if (errors < 5) $display("ERROR dato blk %0d byte %0d", k, b); end
	if (nwr != 1536) begin $display("ERROR %0d escrituras", nwr); errors = errors + 1; end
	// ventana del SCSI: ceros sin pedir nada a user_io
	nlog = 0; nwr = 0; for (b = 0; b < 512; b = b + 1) cmem[b] = 8'hAA;
	req(3'd4, 32'h7E001200, 6'd0, 0);
	if (nlog != 0) begin $display("ERROR la ventana llego a user_io"); errors = errors + 1; end
	if (nwr != 512 || cmem[0] !== 0 || cmem[510] !== 0 || cmem[511] !== 0) begin $display("ERROR ventana: %0d bytes", nwr); errors = errors + 1; end
	// IDE master: escritura de un bloque
	nlog = 0;
	req(3'd2, 32'd7, 6'd0, 1);
	if (nlog != 1 || log_lba[0] != 7) begin $display("ERROR lba IDE"); errors = errors + 1; end
	// el primer byte puede ser el de la direccion 0 o 1 segun user_io: se mira el resto
	for (b = 2; b < 511; b = b + 1) if (wbuf[b] !== ((b[7:0] + 8'd1) ^ 8'd2) && wbuf[b] !== (b[7:0] ^ 8'd2)) begin errors = errors + 1; if (errors < 8) $display("ERROR escritura IDE byte %0d: %h", b, wbuf[b]); end
	// Floppy B: un bloque
	nlog = 0; nwr = 0;
	req(3'd1, 32'd33, 6'd0, 0);
	if (nlog != 1 || log_lba[0] != 33 || nwr != 512) begin $display("ERROR floppy B"); errors = errors + 1; end
	// CD: imagen de 650 MB en la ranura 1 -> expulsa B (tamano 0) y monta ID 2
	begin : cd
		integer seen1, seen6; reg [63:0] sz1, sz6;
		seen1 = 0; seen6 = 0;
		@(posedge clk); m_img_size <= 64'd681574400; m_img_mounted <= 4'b0010;
		@(posedge clk); m_img_mounted <= 0;
		repeat (8) begin
			@(posedge clk);
			if (c_img_mounted[1]) begin seen1 = 1; sz1 = c_img_size; end
			if (c_img_mounted[6]) begin seen6 = 1; sz6 = c_img_size; end
		end
		if (!seen1 || sz1 != 0 || !seen6 || sz6 != 64'd681574400) begin $display("ERROR montaje del CD %0d %0d %0d %0d", seen1, sz1, seen6, sz6); errors = errors + 1; end
		repeat (200) @(posedge clk);   // MSF del lead-out
		// READ TOC (unidad 2, LBA): pista 1 en 0 y lead-out en 332800
		nlog = 0; nwr = 0;
		req(3'd6, 32'h7E204300, 6'd0, 0);
		if (nlog != 0 || nwr != 512) begin $display("ERROR TOC: %0d %0d", nlog, nwr); errors = errors + 1; end
		if (cmem[1] != 8'd18 || cmem[2] != 1 || cmem[5] != 8'h14 || cmem[6] != 1 || cmem[14] != 8'hAA ||
		    {cmem[16], cmem[17], cmem[18], cmem[19]} != 32'd332800 || cmem[511] != 20) begin
			$display("ERROR TOC: %h %h %h ... %h %h%h%h%h len %0d", cmem[1], cmem[5], cmem[6], cmem[14], cmem[16], cmem[17], cmem[18], cmem[19], cmem[511]);
			errors = errors + 1;
		end
		// en MSF: 332800 + 150 = 332950 -> 73:59:25
		req(3'd6, 32'h7E214300, 6'd0, 0);
		if ({cmem[17], cmem[18], cmem[19]} != {8'd73, 8'd59, 8'd25}) begin $display("ERROR MSF %0d:%0d:%0d", cmem[17], cmem[18], cmem[19]); errors = errors + 1; end
		// MODE SENSE(6) del disco SCSI 0: bloques de 512
		req(3'd4, 32'h7E001A00, 6'd0, 0);
		if (cmem[0] != 11 || cmem[3] != 8 || {cmem[9], cmem[10], cmem[11]} != 24'd512 || cmem[511] != 12) begin $display("ERROR MODE SENSE"); errors = errors + 1; end
		// lectura de datos del CD: va a la imagen 1 de MiST
		nlog = 0;
		req(3'd6, 32'd4000, 6'd3, 0);
		if (nlog != 4 || log_lba[0] != 4000 || log_lba[3] != 4003) begin $display("ERROR lectura del CD"); errors = errors + 1; end
	end
	$display("FIN: %0d errores", errors);
	$finish;
end
initial begin #50_000_000; $display("TIMEOUT"); $finish; end
endmodule
