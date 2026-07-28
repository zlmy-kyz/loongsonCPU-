//
// div_unit.v — 32-bit 除法器（多周期，恢复余数法）
//
// 使用联合寄存器 S = {A[31:0], Q[31:0]}：
//   每周期: S[63:32] - M
//     够减(sub_ok=1) → S[63:32]=sub_result, S[0]=1, S << 1
//     不够减(sub_ok=0) → S << 1
//   最后一周期不移位
//   32 周期完成
//
// op[1:0]:
//   2'b00 = div.w   (有符号商)
//   2'b01 = mod.w   (有符号余)
//   2'b10 = div.wu  (无符号商)
//   2'b11 = mod.wu  (无符号余)

module div_unit(
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,       // 除法指令在 ID/EX 中（电平）
    input  wire [31:0] src1,        // rj (被除数)
    input  wire [31:0] src2,        // rk (除数)
    input  wire [ 1:0] op,          // 操作类型
    output reg  [31:0] result,
    output reg         busy
);

// ── 操作解码 ──
wire is_signed = (op[1] == 1'b0);   // div.w/mod.w = 有符号
wire want_rem  = op[0];             // mod.w/mod.wu = 取余数

// ── 检测 valid 上升沿，自动启动 ──
reg valid_r;
wire auto_start;
always @(posedge clk) begin
    if (rst) valid_r <= 1'b0;
    else     valid_r <= valid;
end
assign auto_start = valid && !valid_r && !busy;

// ── 绝对值 ──
wire [31:0] src1_abs = (is_signed && src1[31]) ? (~src1 + 1'b1) : src1;
wire [31:0] src2_abs = (is_signed && src2[31]) ? (~src2 + 1'b1) : src2;
wire        div_by_zero = (src2_abs == 32'd0);

// ── 内部寄存器 ──
reg [63:0] S;               // {A, Q}
reg [31:0] M;               // 除数绝对值
reg [ 4:0] cnt;             // 0~31
reg        div_sign_q;      // 商的符号: src1[31] ^ src2[31]
reg        rem_sign_q;      // 余的符号: src1[31]
reg        div_by_zero_q;   // 除零标志

// ── 试减: S[63:32] - M ──
wire [32:0] sub_result;
assign sub_result = {1'b0, S[63:32]} - {1'b0, M};

wire sub_ok;
assign sub_ok = ~sub_result[32];   // 无借位 → 够减

// ── S 更新 ──
wire [63:0] S_after_sub;
assign S_after_sub = sub_ok ? {sub_result[31:0], S[31:1], 1'b1} : S;

wire [63:0] S_shifted;
assign S_shifted = {S_after_sub[62:0], 1'b0};

always @(posedge clk) begin
    if (rst) begin
        busy          <= 1'b0;
        result        <= 32'd0;
        S             <= 64'd0;
        M             <= 32'd0;
        cnt           <= 5'd0;
        div_sign_q    <= 1'b0;
        rem_sign_q    <= 1'b0;
        div_by_zero_q <= 1'b0;
    end
    else if (auto_start) begin
        // 上升沿自动锁存操作数
        busy          <= 1'b1;
        S             <= {32'd0, src1_abs};
        M             <= src2_abs;
        cnt           <= 5'd0;
        div_sign_q    <= src1[31] ^ src2[31];
        rem_sign_q    <= src1[31];
        div_by_zero_q <= div_by_zero;
    end
    else if (busy) begin
        if (cnt == 5'd31) begin
            // 最后一周期：试减替换不移位，同时输出结果
            busy <= 1'b0;
            if (div_by_zero_q) begin
                result <= 32'd0;
            end
            else if (want_rem) begin
                result <= rem_sign_q ? (~S_after_sub[63:32] + 1'b1) : S_after_sub[63:32];
            end
            else begin
                result <= div_sign_q ? (~S_after_sub[31:0] + 1'b1) : S_after_sub[31:0];
            end
        end
        else begin
            S   <= S_shifted;
            cnt <= cnt + 5'd1;
        end
    end
end

endmodule
