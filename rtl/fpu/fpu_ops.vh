// Operaciones del motor (fpu_engine) y del microcodigo
localparam [4:0]
	OP_MOV    = 5'd0,  OP_ABS    = 5'd1,  OP_NEG    = 5'd2,  OP_TST    = 5'd3,
	OP_ADD    = 5'd4,  OP_SUB    = 5'd5,  OP_CMP    = 5'd6,  OP_MUL    = 5'd7,
	OP_DIV    = 5'd8,  OP_SQRT   = 5'd9,  OP_REM    = 5'd10, OP_MOD    = 5'd11,
	OP_INT    = 5'd12, OP_INTRZ  = 5'd13, OP_GETEXP = 5'd14, OP_GETMAN = 5'd15,
	OP_SCALE  = 5'd16, OP_I2F    = 5'd17, OP_F2I    = 5'd18, OP_IEXP   = 5'd19,
	OP_UNPK   = 5'd20, OP_PACK   = 5'd21, OP_PDEC   = 5'd22, OP_PENC   = 5'd23;
