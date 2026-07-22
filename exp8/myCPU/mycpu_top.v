module mycpu_top(
    input  wire        clk,
    input  wire        resetn,
    // inst sram interface
    output wire        inst_sram_en,
    output wire [3:0]  inst_sram_we,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input  wire [31:0] inst_sram_rdata,
    // data sram interface
    output wire        data_sram_en,
    output wire [3:0]  data_sram_we,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire [31:0] data_sram_rdata,
    // trace debug interface
    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata,

    output wire [31:0] debug_ex_alu_src1,
    output wire [31:0] debug_ex_pc,
    output wire [31:0] debug_id_rj_value,
    output wire [31:0] debug_ex_alu_src1_raw
);
reg         reset;
always @(posedge clk) reset <= ~resetn;

reg         valid;
always @(posedge clk) begin
    if (reset) begin
        valid <= 1'b0;
    end
    else begin
        valid <= 1'b1;
    end
end

wire [31:0] seq_pc;
wire [31:0] nextpc;
wire        br_taken;
wire [31:0] br_target;
wire [31:0] inst;
reg  [31:0] pc;
// IF/ID pipeline registers declared below at line 139

wire [11:0] alu_op;
wire        load_op;
wire        src1_is_pc;
wire        src2_is_imm;
wire        res_from_mem;
wire        dst_is_r1;
wire        gr_we;
wire        mem_we;
wire        src_reg_is_rd;
wire [4: 0] dest;
wire [31:0] rj_value;
wire [31:0] rkd_value;
wire [31:0] imm;
wire [31:0] br_offs;
wire [31:0] jirl_offs;

wire [ 5:0] op_31_26;
wire [ 3:0] op_25_22;
wire [ 1:0] op_21_20;
wire [ 4:0] op_19_15;
wire [ 4:0] rd;
wire [ 4:0] rj;
wire [ 4:0] rk;
wire [11:0] i12;
wire [19:0] i20;
wire [15:0] i16;
wire [25:0] i26;

wire [63:0] op_31_26_d;
wire [15:0] op_25_22_d;
wire [ 3:0] op_21_20_d;
wire [31:0] op_19_15_d;

wire        inst_add_w;
wire        inst_sub_w;
wire        inst_slt;
wire        inst_sltu;
wire        inst_nor;
wire        inst_and;
wire        inst_or;
wire        inst_xor;
wire        inst_slli_w;
wire        inst_srli_w;
wire        inst_srai_w;
wire        inst_addi_w;
wire        inst_ld_w;
wire        inst_st_w;
wire        inst_jirl;
wire        inst_b;
wire        inst_bl;
wire        inst_beq;
wire        inst_bne;
wire        inst_lu12i_w;

wire        need_ui5;
wire        need_si12;
wire        need_si16;
wire        need_si20;
wire        need_si26;
wire        src2_is_4;

wire [ 4:0] rf_raddr1;
wire [31:0] rf_rdata1;
wire [ 4:0] rf_raddr2;
wire [31:0] rf_rdata2;
wire        rf_we   ;
wire [ 4:0] rf_waddr;
wire [31:0] rf_wdata;

wire [31:0] alu_src1   ;
wire [31:0] alu_src2   ;
wire [31:0] alu_result ;
wire        rj_eq_rd   ;


assign seq_pc       = pc + 32'h4;
assign nextpc       = br_taken ? br_target : seq_pc;

always @(posedge clk) begin
    if (reset) begin
        pc       <= 32'h1bfffffc;     //trick: to make nextpc be 0x1c000000 during reset
    end
    else begin
        pc       <= nextpc;
    end
end

assign inst_sram_en    = 1'b1;
assign inst_sram_we    = 4'b0;
assign inst_sram_addr  = pc;
assign inst_sram_wdata = 32'b0;

// =========================================================================
// IF/ID pipeline register
//   BRAM has 1-cycle read latency. if_id_pc delays pc by 1 cycle to align
//   with inst_sram_rdata. if_id_valid gates invalid instructions.
// =========================================================================
reg [31:0] if_id_pc;       // PC of the instruction entering ID stage
reg        if_id_valid;     // 1 = valid, 0 = bubble (NOP)

always @(posedge clk) begin
    if (reset) begin
        if_id_pc    <= 32'h1bfffffc;
        if_id_valid <= 1'b0;
    end
    else if (id_flush) begin
        if_id_pc    <= 32'd0;       // bubble, PC invalid
        if_id_valid <= 1'b0;        // kill the instruction after branch
    end
    else begin
        if_id_pc    <= pc;          // pc[N-1], matches BRAM output timing
        if_id_valid <= 1'b1;
    end
end

// ID stage sees gated instruction (bubble → 0 → NOP)
assign inst = if_id_valid ? inst_sram_rdata : 32'd0;


assign op_31_26  = inst[31:26];
assign op_25_22  = inst[25:22];
assign op_21_20  = inst[21:20];
assign op_19_15  = inst[19:15];

assign rd   = inst[ 4: 0];
assign rj   = inst[ 9: 5];
assign rk   = inst[14:10];

assign i12  = inst[21:10];
assign i20  = inst[24: 5];
assign i16  = inst[25:10];
assign i26  = {inst[ 9: 0], inst[25:10]};

decoder_6_64 u_dec0(.in(op_31_26 ), .out(op_31_26_d ));
decoder_4_16 u_dec1(.in(op_25_22 ), .out(op_25_22_d ));
decoder_2_4  u_dec2(.in(op_21_20 ), .out(op_21_20_d ));
decoder_5_32 u_dec3(.in(op_19_15 ), .out(op_19_15_d ));

assign inst_add_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h00];
assign inst_sub_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h02];
assign inst_slt    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h04];
assign inst_sltu   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
assign inst_nor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h08];
assign inst_and    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h09];
assign inst_or     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0a];
assign inst_xor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0b];
assign inst_slli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
assign inst_srli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
assign inst_srai_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
assign inst_addi_w = op_31_26_d[6'h00] & op_25_22_d[4'ha];
assign inst_ld_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h2];
assign inst_st_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
assign inst_jirl   = op_31_26_d[6'h13];
assign inst_b      = op_31_26_d[6'h14];
assign inst_bl     = op_31_26_d[6'h15];
assign inst_beq    = op_31_26_d[6'h16];
assign inst_bne    = op_31_26_d[6'h17];
assign inst_lu12i_w= op_31_26_d[6'h05] & ~inst[25];

assign alu_op[ 0] = inst_add_w | inst_addi_w | inst_ld_w | inst_st_w
                    | inst_jirl | inst_bl;
assign alu_op[ 1] = inst_sub_w;
assign alu_op[ 2] = inst_slt;
assign alu_op[ 3] = inst_sltu;
assign alu_op[ 4] = inst_and;
assign alu_op[ 5] = inst_nor;
assign alu_op[ 6] = inst_or;
assign alu_op[ 7] = inst_xor;
assign alu_op[ 8] = inst_slli_w;
assign alu_op[ 9] = inst_srli_w;
assign alu_op[10] = inst_srai_w;
assign alu_op[11] = inst_lu12i_w;

assign need_ui5   =  inst_slli_w | inst_srli_w | inst_srai_w;
assign need_si12  =  inst_addi_w | inst_ld_w | inst_st_w;
assign need_si16  =  inst_jirl | inst_beq | inst_bne;
assign need_si20  =  inst_lu12i_w;
assign need_si26  =  inst_b | inst_bl;
assign src2_is_4  =  inst_jirl | inst_bl;

assign imm = src2_is_4 ? 32'h4                      :
             need_si20 ? {i20[19:0], 12'b0}         :
/*need_ui5 || need_si12*/{{20{i12[11]}}, i12[11:0]} ;

assign br_offs = need_si26 ? {{ 4{i26[25]}}, i26[25:0], 2'b0} :
                             {{14{i16[15]}}, i16[15:0], 2'b0} ;

assign jirl_offs = {{14{i16[15]}}, i16[15:0], 2'b0};

assign src_reg_is_rd = inst_beq | inst_bne | inst_st_w;

assign src1_is_pc    = inst_jirl | inst_bl;

assign src2_is_imm   = inst_slli_w |
                       inst_srli_w |
                       inst_srai_w |
                       inst_addi_w |
                       inst_ld_w   |
                       inst_st_w   |
                       inst_lu12i_w|
                       inst_jirl   |
                       inst_bl     ;

assign res_from_mem  = inst_ld_w;
assign dst_is_r1     = inst_bl;
assign gr_we         = ~inst_st_w & ~inst_beq & ~inst_bne & ~inst_b;
assign mem_we        = inst_st_w;
assign dest          = dst_is_r1 ? 5'd1 : rd;

assign rf_raddr1 = rj;
assign rf_raddr2 = src_reg_is_rd ? rd :rk;
regfile u_regfile(
    .clk    (clk      ),
    .raddr1 (rf_raddr1),
    .rdata1 (rf_rdata1),
    .raddr2 (rf_raddr2),
    .rdata2 (rf_rdata2),
    .we     (rf_we    ),
    .waddr  (rf_waddr ),
    .wdata  (rf_wdata )
    );

// --- ID stage forwarding ---
// Priority: EX(same-cycle) > EX/MEM > MEM/WB > regfile

// second source: rd (beq/st_w) or rk
wire [4:0] id_rkd_src;
assign id_rkd_src = src_reg_is_rd ? rd : rk;

// forwarded values (pick newest source)
assign rj_value = id_ex_gr_we      && (id_ex_dest == rj)
                  ? alu_result :
                  ex_mem_gr_we     && (ex_mem_dest == rj)
                  ? ex_mem_alu_result :
                  mem_wb_gr_we     && (mem_wb_dest == rj)
                  ? rf_wdata :
                  rf_rdata1;

assign rkd_value = id_ex_gr_we      && (id_ex_dest == id_rkd_src)
                   ? alu_result :
                   ex_mem_gr_we     && (ex_mem_dest == id_rkd_src)
                   ? ex_mem_alu_result :
                   mem_wb_gr_we     && (mem_wb_dest == id_rkd_src)
                   ? rf_wdata :
                   rf_rdata2;

assign rj_eq_rd = (rj_value == rkd_value);
assign br_taken = (   inst_beq  &&  rj_eq_rd
                   || inst_bne  && !rj_eq_rd
                   || inst_jirl
                   || inst_bl
                   || inst_b
                  ) && valid;
assign br_target = (inst_beq || inst_bne || inst_bl || inst_b) ? (if_id_pc + br_offs) :
                                                   /*inst_jirl*/ (rj_value + jirl_offs);

// Branch flush: when branch taken in ID, invalidate the instruction in IF/ID
wire id_flush;
assign id_flush = br_taken;

// =========================================================================
// ID/EX pipeline register (between ID and EX)
// =========================================================================
reg [11:0] id_ex_alu_op;
reg        id_ex_src1_is_pc;
reg        id_ex_src2_is_imm;
reg        id_ex_res_from_mem;
reg        id_ex_gr_we;
reg        id_ex_mem_we;
reg [4:0]  id_ex_dest;
reg [31:0] id_ex_pc;
reg [31:0] id_ex_rj_value;
reg [31:0] id_ex_rkd_value;
reg [31:0] id_ex_imm;
reg [4:0]  id_ex_rj;
reg [4:0]  id_ex_rkd_src;
reg        id_ex_valid;

always @(posedge clk) begin
    if (reset) begin
        id_ex_valid        <= 1'b0;
        id_ex_alu_op       <= 12'd0;
        id_ex_src1_is_pc   <= 1'b0;
        id_ex_src2_is_imm  <= 1'b0;
        id_ex_res_from_mem <= 1'b0;
        id_ex_gr_we        <= 1'b0;
        id_ex_mem_we       <= 1'b0;
        id_ex_dest         <= 5'd0;
        id_ex_pc           <= 32'd0;
        id_ex_rj_value     <= 32'd0;
        id_ex_rkd_value    <= 32'd0;
        id_ex_imm          <= 32'd0;
        id_ex_rj           <= 5'd0;
        id_ex_rkd_src      <= 5'd0;
    end else begin
        id_ex_valid        <= valid && if_id_valid;
        id_ex_alu_op       <= alu_op;
        id_ex_src1_is_pc   <= src1_is_pc;
        id_ex_src2_is_imm  <= src2_is_imm;
        id_ex_res_from_mem <= res_from_mem;
        id_ex_gr_we        <= gr_we;
        id_ex_mem_we       <= mem_we;
        id_ex_dest         <= dest;
        id_ex_pc           <= if_id_pc;
        id_ex_rj_value     <= rj_value;
        id_ex_rkd_value    <= rkd_value;
        id_ex_imm          <= imm;
        id_ex_rj           <= rj;
        id_ex_rkd_src      <= id_rkd_src;
    end
end

assign alu_src1 = id_ex_src1_is_pc  ? id_ex_pc[31:0] : id_ex_rj_value;
assign alu_src2 = id_ex_src2_is_imm ? id_ex_imm : id_ex_rkd_value;

alu u_alu(
    .alu_op     (id_ex_alu_op),
    .alu_src1   (alu_src1  ),
    .alu_src2   (alu_src2  ),
    .alu_result (alu_result)
    );

// =========================================================================
// EX/MEM pipeline register (between EX and MEM)
// =========================================================================
reg [31:0] ex_mem_alu_result;
reg [31:0] ex_mem_rkd_value;     // store data
reg [4:0]  ex_mem_dest;
reg        ex_mem_gr_we;
reg        ex_mem_mem_we;
reg        ex_mem_res_from_mem;
reg        ex_mem_valid;
reg [31:0] ex_mem_pc;

always @(posedge clk) begin
    if (reset) begin
        ex_mem_valid        <= 1'b0;
        ex_mem_gr_we        <= 1'b0;
        ex_mem_mem_we       <= 1'b0;
        ex_mem_res_from_mem <= 1'b0;
        ex_mem_alu_result   <= 32'd0;
        ex_mem_rkd_value    <= 32'd0;
        ex_mem_dest         <= 5'd0;
        ex_mem_pc           <= 32'd0;
    end else begin
        ex_mem_valid        <= id_ex_valid;
        ex_mem_gr_we        <= id_ex_gr_we;
        ex_mem_mem_we       <= id_ex_mem_we;
        ex_mem_res_from_mem <= id_ex_res_from_mem;
        ex_mem_alu_result   <= alu_result;
        ex_mem_rkd_value    <= id_ex_rkd_value;
        ex_mem_dest         <= id_ex_dest;
        ex_mem_pc           <= id_ex_pc;
    end
end

// --- MEM stage ---
assign data_sram_en    = (ex_mem_mem_we || ex_mem_res_from_mem) && ex_mem_valid;
assign data_sram_we    = {4{ex_mem_mem_we && ex_mem_valid}};
assign data_sram_addr  = ex_mem_alu_result;
assign data_sram_wdata = ex_mem_rkd_value;

// =========================================================================
// MEM/WB pipeline register (between MEM and WB)
//   Note: data_sram_rdata is NOT captured here — like inst_sram_rdata,
//   BRAM output is already registered. WB uses it directly.
// =========================================================================
reg [31:0] mem_wb_alu_result;
reg [4:0]  mem_wb_dest;
reg        mem_wb_gr_we;
reg        mem_wb_res_from_mem;
reg        mem_wb_valid;
reg [31:0] mem_wb_pc;

always @(posedge clk) begin
    if (reset) begin
        mem_wb_valid         <= 1'b0;
        mem_wb_gr_we         <= 1'b0;
        mem_wb_res_from_mem  <= 1'b0;
        mem_wb_alu_result    <= 32'd0;
        mem_wb_dest          <= 5'd0;
        mem_wb_pc            <= 32'd0;
    end else begin
        mem_wb_valid         <= ex_mem_valid;
        mem_wb_gr_we         <= ex_mem_gr_we;
        mem_wb_res_from_mem  <= ex_mem_res_from_mem;
        mem_wb_alu_result    <= ex_mem_alu_result;
        mem_wb_dest          <= ex_mem_dest;
        mem_wb_pc            <= ex_mem_pc;
    end
end

// =========================================================================
// WB stage — Register File Writeback
//   data_sram_rdata used directly: BRAM updated it at posedge MEM→WB,
//   so during WB it holds the data from MEM's address. No load_pending needed.
// =========================================================================
assign rf_we    = mem_wb_gr_we && mem_wb_valid;
assign rf_waddr = mem_wb_dest;
assign rf_wdata = mem_wb_res_from_mem ? data_sram_rdata : mem_wb_alu_result;

// debug info generate
assign debug_wb_pc       = mem_wb_pc;
assign debug_wb_rf_we    = {4{rf_we}};
assign debug_wb_rf_wnum  = rf_waddr;
assign debug_wb_rf_wdata = rf_wdata;

// extra debug
assign debug_ex_alu_src1     = alu_src1;
assign debug_ex_pc           = id_ex_pc;
assign debug_id_rj_value     = rj_value;
assign debug_ex_alu_src1_raw = id_ex_rj_value;

endmodule
