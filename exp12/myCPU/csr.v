module csr(
    input  wire        clk,
    input  wire        reset,
    // READ PORT 1 (instruction, ID stage)
    input  wire [13:0] raddr1,
    output wire [31:0] rdata1,
    // WRITE PORT (instruction, WB stage)
    input  wire        we,       //write enable, HIGH valid
    input  wire [13:0] waddr,
    input  wire [31:0] wdata,
    // READ PORT 2 (ertn in ID -> ERA; exception in EX -> EENTRY)
    input  wire [13:0] raddr2,
    output wire [31:0] rdata2,
    // current mode output (for PRMD save on exception)
    output wire [31:0] crmd_out,
    // EXCEPTION WRITE PORT (EX stage, parallel write of CRMD/PRMD/ESTAT/ERA)
    input  wire        ex_wen,
    input  wire [31:0] ex_crmd_wdata,
    input  wire [31:0] ex_prmd_wdata,
    input  wire [31:0] ex_estat_wdata,
    input  wire [31:0] ex_era_wdata
);
reg [31:0] crmd;
reg [31:0] prmd;
reg [31:0] estat;
reg [31:0] era;
reg [31:0] eentry;
reg [31:0] save0;
reg [31:0] save1;
reg [31:0] save2;
reg [31:0] save3;

//WRITE: exception port has priority (architecturally a later event)
always @(posedge clk) begin
    if (reset) crmd <= 32'b0;
    else if (ex_wen) crmd <= ex_crmd_wdata;
    else if (we && waddr == 14'h0) crmd <= wdata;
end

always @(posedge clk) begin
    if (reset) prmd <= 32'b0;
    else if (ex_wen) prmd <= ex_prmd_wdata;
    else if (we && waddr == 14'h1) prmd <= wdata;
end

always @(posedge clk) begin
    if (reset) estat <= 32'b0;
    else if (ex_wen) estat <= ex_estat_wdata;
    else if (we && waddr == 14'h5) estat <= wdata;
end

always @(posedge clk) begin
    if (reset) era <= 32'b0;
    else if (ex_wen) era <= ex_era_wdata;
    else if (we && waddr == 14'h6) era <= wdata;
end

always @(posedge clk) begin
    if (reset) eentry <= 32'b0;
    else if (we && waddr == 14'hc) eentry <= wdata;
end

always @(posedge clk) begin
    if (reset) save0 <= 32'b0;
    else if (we && waddr == 14'h30) save0 <= wdata;
end

always @(posedge clk) begin
    if (reset) save1 <= 32'b0;
    else if (we && waddr == 14'h31) save1 <= wdata;
end

always @(posedge clk) begin
    if (reset) save2 <= 32'b0;
    else if (we && waddr == 14'h32) save2 <= wdata;
end

always @(posedge clk) begin
    if (reset) save3 <= 32'b0;
    else if (we && waddr == 14'h33) save3 <= wdata;
end

//READ OUT 1 (unimplemented CSR returns 0)
assign rdata1 = (raddr1 == 14'h0)  ? crmd   :
                (raddr1 == 14'h1)  ? prmd   :
                (raddr1 == 14'h5)  ? estat  :
                (raddr1 == 14'h6)  ? era    :
                (raddr1 == 14'hc)  ? eentry :
                (raddr1 == 14'h30) ? save0  :
                (raddr1 == 14'h31) ? save1  :
                (raddr1 == 14'h32) ? save2  :
                (raddr1 == 14'h33) ? save3  : 32'b0;

//READ OUT 2
assign rdata2 = (raddr2 == 14'h0)  ? crmd   :
                (raddr2 == 14'h1)  ? prmd   :
                (raddr2 == 14'h5)  ? estat  :
                (raddr2 == 14'h6)  ? era    :
                (raddr2 == 14'hc)  ? eentry :
                (raddr2 == 14'h30) ? save0  :
                (raddr2 == 14'h31) ? save1  :
                (raddr2 == 14'h32) ? save2  :
                (raddr2 == 14'h33) ? save3  : 32'b0;

assign crmd_out = crmd;

endmodule
