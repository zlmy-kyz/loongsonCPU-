//
// mul_unit.v — 乘除单元（单周期组合逻辑）
//
// op[2:0]:
//   3'b000 = mul.w   : 有符号乘，低 32 位
//   3'b001 = mulh.w  : 有符号乘，高 32 位
//   3'b010 = mulh.wu : 无符号乘，高 32 位
//   3'b011 = div.w   : 有符号商
//   3'b100 = mod.w   : 有符号余
//   3'b101 = div.wu  : 无符号商
//   3'b110 = mod.wu  : 无符号余
//
// 乘法：显式符号扩展到 64-bit，DSP48E1 硬核
// 除法：Verilog 内置 / % 运算符，除零返回 0

module mul_unit(
    input  wire [31:0] src1,
    input  wire [31:0] src2,
    input  wire [ 2:0] op,
    output wire [31:0] result
);

wire op_mul   = (op == 3'b000);
wire op_mulh  = (op == 3'b001);
wire op_mulhu = (op == 3'b010);
wire op_div   = (op == 3'b011);
wire op_mod   = (op == 3'b100);
wire op_divu  = (op == 3'b101);
wire op_modu  = (op == 3'b110);

// ── 乘法 ──
wire [63:0] signed_product;
wire [63:0] unsigned_product;

assign signed_product   = {{32{src1[31]}}, src1} * {{32{src2[31]}}, src2};
assign unsigned_product = {32'b0, src1} * {32'b0, src2};

wire [31:0] mul_w_result   = signed_product[31:0];
wire [31:0] mulh_w_result  = signed_product[63:32];
wire [31:0] mulh_wu_result = unsigned_product[63:32];

// ── 除法（组合逻辑，除零返回 0）──
wire div_by_zero;
assign div_by_zero = (src2 == 32'd0);

// 有符号除法：手动取绝对值做无符号除，再恢复符号
wire [31:0] div_src1_abs;
wire [31:0] div_src2_abs;
wire        div_sign;
wire        mod_sign;

assign div_src1_abs = src1[31] ? (~src1 + 1'b1) : src1;
assign div_src2_abs = src2[31] ? (~src2 + 1'b1) : src2;
assign div_sign     = src1[31] ^ src2[31];
assign mod_sign     = src1[31];

wire [31:0] div_abs_result;
wire [31:0] mod_abs_result;
assign div_abs_result = div_by_zero ? 32'd0 : div_src1_abs / div_src2_abs;
assign mod_abs_result = div_by_zero ? 32'd0 : div_src1_abs % div_src2_abs;

wire [31:0] div_w_result;
wire [31:0] mod_w_result;
wire [31:0] div_wu_result;
wire [31:0] mod_wu_result;

assign div_w_result  = div_sign ? (~div_abs_result + 1'b1) : div_abs_result;
assign mod_w_result  = mod_sign ? (~mod_abs_result + 1'b1) : mod_abs_result;
assign div_wu_result = div_by_zero ? 32'd0 : src1 / src2;
assign mod_wu_result = div_by_zero ? 32'd0 : src1 % src2;

// ── 结果 mux ──
assign result = ({32{op_mul       }} & mul_w_result  )
              | ({32{op_mulh      }} & mulh_w_result )
              | ({32{op_mulhu     }} & mulh_wu_result)
              | ({32{op_div       }} & div_w_result  )
              | ({32{op_mod       }} & mod_w_result  )
              | ({32{op_divu      }} & div_wu_result )
              | ({32{op_modu      }} & mod_wu_result );

endmodule
