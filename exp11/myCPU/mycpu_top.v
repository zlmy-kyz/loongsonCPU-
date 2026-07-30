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

wire [18:0] alu_op;
wire        load_op;
wire        src1_is_pc;
wire        src2_is_imm;
wire        res_from_mem;
wire        dst_is_r1;
wire        gr_we;
wire        mem_we;
wire        src_reg_is_rd;
wire [1: 0] mem_size;       // 00=word, 01=byte, 10=half
wire        mem_sign;       // 1=signed (ld.b/ld.h), 0=unsigned (ld.bu/ld.hu)
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
wire        inst_ld_b;
wire        inst_ld_h;
wire        inst_ld_bu;
wire        inst_ld_hu;
wire        inst_st_w;
wire        inst_jirl;
wire        inst_b;
wire        inst_bl;
wire        inst_beq;
wire        inst_bne;
wire        inst_blt;
wire        inst_bge;
wire        inst_bltu;
wire        inst_bgeu;
wire        inst_lu12i_w;
wire        inst_pcaddu12i;
wire        inst_slti;
wire        inst_sltui;
wire        inst_andi;
wire        inst_ori;
wire        inst_xori;
wire        inst_sll_w;
wire        inst_sra_w;
wire        inst_srl_w;
wire        inst_mul_w;
wire        inst_mulh_w;
wire        inst_mulh_wu;
wire        inst_div_w;
wire        inst_mod_w;
wire        inst_div_wu;
wire        inst_mod_wu;

wire        need_ui5;
wire        need_si12;
wire        need_si16;
wire        need_si20;
wire        need_si26;
wire        src2_is_4;
wire        need_ui12;

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
wire [31:0] mul_div_result;
wire        rj_eq_rd   ;


assign seq_pc       = pc + 32'h4;
assign nextpc       = br_taken ? br_target : seq_pc;

always @(posedge clk) begin
    if (reset) begin
        pc       <= 32'h1bfffffc;     //trick: to make nextpc be 0x1c000000 during reset
    end
    else if (id_stall) begin
        pc       <= pc;               // hold PC during load-use stall
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
    else if (id_stall) begin
        // hold current values
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

// Stall instruction hold: inst_sram_rdata is naturally aligned with if_id_pc
// during the cycle, but shifts to the next instruction during stall. Capture
// it on the first stall posedge and hold for subsequent stall cycles.
reg [31:0] stall_inst;
reg        id_stall_r;     // id_stall delayed by 1 cycle

always @(posedge clk) begin
    id_stall_r <= id_stall;
    if (id_stall && !id_stall_r)
        stall_inst <= inst_sram_rdata;  // first stall posedge: capture aligned value
    // else: hold during ongoing stall; normal cycles don't use stall_inst
end

// ID stage sees captured instruction
//   Normal: inst_sram_rdata (wire, naturally aligned with if_id_pc)
//   Stall:  stall_inst (holds the instruction from before the stall)
assign inst = if_id_valid ? (id_stall_r ? stall_inst : inst_sram_rdata) : 32'd0;


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
assign inst_ld_b   = op_31_26_d[6'h0a] & op_25_22_d[4'h0];
assign inst_ld_h   = op_31_26_d[6'h0a] & op_25_22_d[4'h1];
assign inst_ld_bu  = op_31_26_d[6'h0a] & op_25_22_d[4'h8];
assign inst_ld_hu  = op_31_26_d[6'h0a] & op_25_22_d[4'h9];
assign inst_st_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
assign inst_jirl   = op_31_26_d[6'h13];
assign inst_b      = op_31_26_d[6'h14];
assign inst_bl     = op_31_26_d[6'h15];
assign inst_beq    = op_31_26_d[6'h16];
assign inst_bne    = op_31_26_d[6'h17];
assign inst_blt    = op_31_26_d[6'h18];
assign inst_bge    = op_31_26_d[6'h19];
assign inst_bltu   = op_31_26_d[6'h1a];
assign inst_bgeu   = op_31_26_d[6'h1b];
assign inst_lu12i_w = op_31_26_d[6'h05] & ~inst[25];
assign inst_pcaddu12i = op_31_26_d[6'h07] & ~inst[25];
assign inst_slti   = op_31_26_d[6'h00] & op_25_22_d[4'h8];
assign inst_sltui  = op_31_26_d[6'h00] & op_25_22_d[4'h9];
assign inst_andi   = op_31_26_d[6'h00] & op_25_22_d[4'hd];
assign inst_ori    = op_31_26_d[6'h00] & op_25_22_d[4'he];
assign inst_xori   = op_31_26_d[6'h00] & op_25_22_d[4'hf];
assign inst_sll_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0e];
assign inst_sra_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h10];
assign inst_srl_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0f];
assign inst_mul_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h18];
assign inst_mulh_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h19];
assign inst_mulh_wu = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h1a];
assign inst_div_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h00];
assign inst_mod_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h01];
assign inst_div_wu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h02];
assign inst_mod_wu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h03];

assign alu_op[ 0] = inst_add_w | inst_addi_w | inst_ld_w | inst_st_w
                    | inst_jirl | inst_bl | inst_pcaddu12i
                    | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu;
assign alu_op[ 1] = inst_sub_w;
assign alu_op[ 2] = inst_slt | inst_slti;
assign alu_op[ 3] = inst_sltu | inst_sltui;
assign alu_op[ 4] = inst_and | inst_andi;
assign alu_op[ 5] = inst_nor;
assign alu_op[ 6] = inst_or | inst_ori;
assign alu_op[ 7] = inst_xor | inst_xori;
assign alu_op[ 8] = inst_slli_w | inst_sll_w;
assign alu_op[ 9] = inst_srli_w | inst_srl_w;
assign alu_op[10] = inst_srai_w | inst_sra_w;
assign alu_op[11] = inst_lu12i_w;
assign alu_op[12] = inst_mul_w;
assign alu_op[13] = inst_mulh_w;
assign alu_op[14] = inst_mulh_wu;
assign alu_op[15] = inst_div_w;
assign alu_op[16] = inst_mod_w;
assign alu_op[17] = inst_div_wu;
assign alu_op[18] = inst_mod_wu;

assign need_ui5   =  inst_slli_w | inst_srli_w | inst_srai_w;
assign need_si12  =  inst_addi_w | inst_ld_w | inst_st_w
                     | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu;
assign need_si16  =  inst_jirl | inst_beq | inst_bne | inst_blt | inst_bge | inst_bltu | inst_bgeu;
assign need_si20  =  inst_lu12i_w | inst_pcaddu12i;
assign need_ui12  =  inst_andi | inst_ori | inst_xori;
assign need_si26  =  inst_b | inst_bl;
assign src2_is_4  =  inst_jirl | inst_bl;

assign imm = src2_is_4 ? 32'h4                      :
             need_si20 ? {i20[19:0], 12'b0}         :
             need_ui12 ? {20'b0, i12[11:0]}         :
/*need_ui5 || need_si12*/{{20{i12[11]}}, i12[11:0]} ;

assign br_offs = need_si26 ? {{ 4{i26[25]}}, i26[25:0], 2'b0} :
                             {{14{i16[15]}}, i16[15:0], 2'b0} ;

assign jirl_offs = {{14{i16[15]}}, i16[15:0], 2'b0};

assign src_reg_is_rd = inst_beq | inst_bne | inst_blt | inst_bge | inst_bltu | inst_bgeu | inst_st_w;

assign src1_is_pc    = inst_jirl | inst_bl | inst_pcaddu12i;

assign src2_is_imm   = inst_slli_w |
                       inst_srli_w |
                       inst_srai_w |
                       inst_addi_w |
                       inst_ld_w   |
                       inst_st_w   |
                       inst_lu12i_w|
                       inst_jirl   |
                       inst_bl     |
                       inst_pcaddu12i|
                       inst_slti   |
                       inst_sltui  |
                       inst_andi   |
                       inst_ori    |
                       inst_xori   |
                       inst_ld_b   |
                       inst_ld_h   |
                       inst_ld_bu  |
                       inst_ld_hu  ;

assign res_from_mem  = inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu;
assign dst_is_r1     = inst_bl;
assign mem_size      = (inst_ld_b | inst_ld_bu) ? 2'b01 :
                       (inst_ld_h | inst_ld_hu) ? 2'b10 :
                       2'b00;
assign mem_sign      = (inst_ld_b | inst_ld_h) ? 1'b1 : 1'b0;
assign gr_we         = ~inst_st_w & ~inst_beq & ~inst_bne & ~inst_b & ~inst_blt & ~inst_bge & ~inst_bltu & ~inst_bgeu;
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
// ID forwarding: skip loads in EX/MEM (alu_result = address, not data)
//   mem_wb is safe: rf_wdata already selects between alu_result and data_sram_rdata
/*assign rj_value = id_ex_gr_we  && !id_ex_res_from_mem && !div_busy && (id_ex_dest == rj)
                  ? ex_result :
                  ex_mem_gr_we && !ex_mem_res_from_mem && (ex_mem_dest == rj)
                  ? ex_mem_alu_result :
                  mem_wb_gr_we && (mem_wb_dest == rj)
                  ? rf_wdata :
                  rf_rdata1;

assign rkd_value = id_ex_gr_we  && !id_ex_res_from_mem && !div_busy && (id_ex_dest == id_rkd_src)
                   ? ex_result :
                   ex_mem_gr_we && !ex_mem_res_from_mem && (ex_mem_dest == id_rkd_src)
                   ? ex_mem_alu_result :
                   mem_wb_gr_we && (mem_wb_dest == id_rkd_src)
                   ? rf_wdata :
                   rf_rdata2;*/

assign rj_value = id_ex_gr_we  && !id_ex_res_from_mem && (id_ex_dest == rj)
                  ? ex_result :
                  ex_mem_gr_we && !ex_mem_res_from_mem && (ex_mem_dest == rj)
                  ? ex_mem_alu_result :
                  mem_wb_gr_we && (mem_wb_dest == rj)
                  ? rf_wdata :
                  rf_rdata1;

assign rkd_value = id_ex_gr_we  && !id_ex_res_from_mem && (id_ex_dest == id_rkd_src)
                   ? ex_result :
                   ex_mem_gr_we && !ex_mem_res_from_mem && (ex_mem_dest == id_rkd_src)
                   ? ex_mem_alu_result :
                   mem_wb_gr_we && (mem_wb_dest == id_rkd_src)
                   ? rf_wdata :
                   rf_rdata2;

// signed less-than for blt/bge
wire [31:0] rj_minus_rkd;
wire        rj_lt_rkd_signed;
assign rj_minus_rkd      = rj_value - rkd_value;
assign rj_lt_rkd_signed  = (rj_value[31] & ~rkd_value[31])
                         | ((rj_value[31] ~^ rkd_value[31]) & rj_minus_rkd[31]);

// unsigned less-than for bltu/bgeu: borrow of 33-bit subtract
wire [32:0] rj_minus_rkd_33;
wire        rj_lt_rkd_unsigned;
assign rj_minus_rkd_33   = {1'b0, rj_value} - {1'b0, rkd_value};
assign rj_lt_rkd_unsigned = rj_minus_rkd_33[32];

assign rj_eq_rd = (rj_value == rkd_value);
assign br_taken = (   inst_beq  &&  rj_eq_rd
                   || inst_bne  && !rj_eq_rd
                   || inst_blt  &&  rj_lt_rkd_signed
                   || inst_bge  && !rj_lt_rkd_signed
                   || inst_bltu &&  rj_lt_rkd_unsigned
                   || inst_bgeu && !rj_lt_rkd_unsigned
                   || inst_jirl
                   || inst_bl
                   || inst_b
                  ) && valid;
assign br_target = (inst_beq || inst_bne || inst_blt || inst_bge || inst_bltu || inst_bgeu || inst_bl || inst_b) ? (if_id_pc + br_offs) :
                                                   /*inst_jirl*/ (rj_value + jirl_offs);

// Branch flush: when branch taken in ID, invalidate the instruction in IF/ID
wire id_flush;
assign id_flush = br_taken;

// Load-use hazard detection: two separate signals
//   load_use_stall : load in EX, dependent in ID → stall pipeline
//   load_use_fwd   : load in MEM, dependent in ID → no stall, forwarding instead
wire load_use_stall;
assign load_use_stall = id_ex_res_from_mem && id_ex_valid &&
                        (id_ex_dest == rj || id_ex_dest == id_rkd_src);

wire load_use_fwd;
assign load_use_fwd = ex_mem_res_from_mem && ex_mem_valid &&
                      (ex_mem_dest == rj || ex_mem_dest == id_rkd_src);

// combined: either case triggers WB→EX forwarding in the next cycle
wire load_use;
assign load_use = load_use_stall || load_use_fwd;

//wire div_busy;

wire id_stall;
//assign id_stall = load_use_stall || div_busy;
assign id_stall = load_use_stall;

// =========================================================================
// ID/EX pipeline register (between ID and EX)
// =========================================================================
reg [18:0] id_ex_alu_op;
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
reg        id_ex_load_use;   // WB→EX forwarding enable
reg        id_ex_valid;
reg [1:0]  id_ex_mem_size;
reg        id_ex_mem_sign;

always @(posedge clk) begin
    if (reset) begin
        id_ex_valid        <= 1'b0;
        id_ex_alu_op       <= 19'd0;
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
        id_ex_load_use     <= 1'b0;
        id_ex_mem_size     <= 2'd0;
        id_ex_mem_sign     <= 1'b0;
    end else if (id_stall) begin
        id_ex_valid        <= 1'b0;
        id_ex_alu_op       <= 19'd0;
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
        id_ex_load_use     <= 1'b0;
        id_ex_mem_size     <= 2'd0;
        id_ex_mem_sign     <= 1'b0;
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
        id_ex_load_use     <= load_use;
        id_ex_mem_size     <= mem_size;
        id_ex_mem_sign     <= mem_sign;
    end
end

// mul/div control in EX stage
/*wire        ex_is_mul;
wire        ex_is_div;
wire [1:0]  ex_mul_op;
wire [1:0]  ex_div_op;

assign ex_is_mul = |id_ex_alu_op[14:12];
assign ex_is_div = |id_ex_alu_op[18:15];

assign ex_mul_op = id_ex_alu_op[14] ? 2'b10 :      // mulh.wu
                   id_ex_alu_op[13] ? 2'b01 :       // mulh.w
                   2'b00;                            // mul.w

assign ex_div_op = id_ex_alu_op[18] ? 2'b11 :       // mod.wu
                   id_ex_alu_op[17] ? 2'b10 :        // div.wu
                   id_ex_alu_op[16] ? 2'b01 :        // mod.w
                   2'b00;                             // div.w

wire div_valid;
assign div_valid = id_ex_valid && ex_is_div;*/

wire [2:0] ex_mul_div_op;
assign ex_mul_div_op = id_ex_alu_op[12] ? 3'b000 :      // mul.w
                       id_ex_alu_op[13] ? 3'b001 :       // mulh.w
                       id_ex_alu_op[14] ? 3'b010 :       // mulh.wu
                       id_ex_alu_op[15] ? 3'b011 :       // div.w
                       id_ex_alu_op[16] ? 3'b100 :       // mod.w
                       id_ex_alu_op[17] ? 3'b101 :       // div.wu
                       id_ex_alu_op[18] ? 3'b110 :       // mod.wu
                       3'b000;                            // default
wire ex_is_mul_div;
assign ex_is_mul_div = |id_ex_alu_op[18:12];

// WB→EX forwarding: load-use detected in ID, load now in WB → bypass data_sram_rdata
assign alu_src1 = id_ex_src1_is_pc  ? id_ex_pc[31:0] :
                  (id_ex_load_use && mem_wb_res_from_mem && mem_wb_valid && mem_wb_dest == id_ex_rj)
                  ? data_sram_rdata :
                  id_ex_rj_value;

assign alu_src2 = id_ex_src2_is_imm ? id_ex_imm :
                  (id_ex_load_use && mem_wb_res_from_mem && mem_wb_valid && mem_wb_dest == id_ex_rkd_src)
                  ? data_sram_rdata :
                  id_ex_rkd_value;

alu u_alu(
    .alu_op     (id_ex_alu_op[11:0]),
    .alu_src1   (alu_src1  ),
    .alu_src2   (alu_src2  ),
    .alu_result (alu_result)
    );

wire [31:0] mul_result;
mul_unit u_mul(
    .src1   (alu_src1),
    .src2   (alu_src2),
    .op     (ex_mul_div_op),
    .result (mul_div_result)
);

/*wire [31:0] div_result;
div_unit u_div(
    .clk    (clk),
    .rst    (reset),
    .valid  (div_valid),
    .src1   (alu_src1),
    .src2   (alu_src2),
    .op     (ex_div_op),
    .result (div_result),
    .busy   (div_busy)
);*/

// EX result mux: mul/div bypass ALU
wire [31:0] ex_result;
assign ex_result = ex_is_mul_div ? mul_div_result :
                   alu_result;

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
reg [1:0]  ex_mem_mem_size;
reg        ex_mem_mem_sign;

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
        ex_mem_mem_size     <= 2'd0;
        ex_mem_mem_sign     <= 1'b0;
    end else begin
        ex_mem_valid        <= id_ex_valid;
        ex_mem_gr_we        <= id_ex_gr_we;
        ex_mem_mem_we       <= id_ex_mem_we;
        ex_mem_res_from_mem <= id_ex_res_from_mem;
        ex_mem_alu_result   <= ex_result;
        ex_mem_rkd_value    <= id_ex_rkd_value;
        ex_mem_dest         <= id_ex_dest;
        ex_mem_pc           <= id_ex_pc;
        ex_mem_mem_size     <= id_ex_mem_size;
        ex_mem_mem_sign     <= id_ex_mem_sign;
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
reg [1:0]  mem_wb_mem_size;
reg        mem_wb_mem_sign;

always @(posedge clk) begin
    if (reset) begin
        mem_wb_valid         <= 1'b0;
        mem_wb_gr_we         <= 1'b0;
        mem_wb_res_from_mem  <= 1'b0;
        mem_wb_alu_result    <= 32'd0;
        mem_wb_dest          <= 5'd0;
        mem_wb_pc            <= 32'd0;
        mem_wb_mem_size      <= 2'd0;
        mem_wb_mem_sign      <= 1'b0;
    end else begin
        mem_wb_valid         <= ex_mem_valid;
        mem_wb_gr_we         <= ex_mem_gr_we;
        mem_wb_res_from_mem  <= ex_mem_res_from_mem;
        mem_wb_alu_result    <= ex_mem_alu_result;
        mem_wb_dest          <= ex_mem_dest;
        mem_wb_pc            <= ex_mem_pc;
        mem_wb_mem_size      <= ex_mem_mem_size;
        mem_wb_mem_sign      <= ex_mem_mem_sign;
    end
end

// =========================================================================
// WB stage — Register File Writeback
//   data_sram_rdata used directly: BRAM updated it at posedge MEM→WB,
//   so during WB it holds the data from MEM's address. No load_pending needed.
// =========================================================================
assign rf_we    = mem_wb_gr_we && mem_wb_valid;
assign rf_waddr = mem_wb_dest;

// sub-word load: byte/halfword extraction & sign extension
wire [7:0]  load_byte;
wire [15:0] load_half;
wire [31:0] load_data;
assign load_byte = (mem_wb_alu_result[1:0] == 2'b00) ? data_sram_rdata[ 7: 0] :
                   (mem_wb_alu_result[1:0] == 2'b01) ? data_sram_rdata[15: 8] :
                   (mem_wb_alu_result[1:0] == 2'b10) ? data_sram_rdata[23:16] :
                                                        data_sram_rdata[31:24];
assign load_half = mem_wb_alu_result[1] ? data_sram_rdata[31:16]
                                        : data_sram_rdata[15: 0];
wire [31:0] load_byte_ext;
wire [31:0] load_half_ext;
assign load_byte_ext = mem_wb_mem_sign ? {{24{load_byte[7]}}, load_byte}
                                       : {24'b0, load_byte};
assign load_half_ext = mem_wb_mem_sign ? {{16{load_half[15]}}, load_half}
                                       : {16'b0, load_half};
assign load_data = (mem_wb_mem_size == 2'b01) ? load_byte_ext :
                   (mem_wb_mem_size == 2'b10) ? load_half_ext :
                                                data_sram_rdata;

assign rf_wdata = mem_wb_res_from_mem ? load_data : mem_wb_alu_result;

// debug info generate
assign debug_wb_pc       = mem_wb_pc;
assign debug_wb_rf_we    = {4{rf_we}};
assign debug_wb_rf_wnum  = rf_waddr;
assign debug_wb_rf_wdata = rf_wdata;

// extra debug
assign debug_ex_alu_src1     = if_id_pc;
assign debug_ex_pc           = alu_src1;
assign debug_id_rj_value     = alu_src2;
assign debug_ex_alu_src1_raw = res_from_mem;

endmodule
