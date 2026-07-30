# exp10 新增指令实现计划

## 新增指令清单 (16条)

| 类别 | 指令 | 格式 | 编码特征 | 立即数 |
|------|------|------|----------|--------|
| 比较 | slti | 2RI | op_31_26=0x00, op_25_22=0x8 | si12 符号扩展 |
| 比较 | sltui | 2RI | op_31_26=0x00, op_25_22=0x9 | si12 符号扩展 |
| 逻辑 | andi | 2RI | op_31_26=0x00, op_25_22=0xd | **ui12 零扩展** |
| 逻辑 | ori | 2RI | op_31_26=0x00, op_25_22=0xe | **ui12 零扩展** |
| 逻辑 | xori | 2RI | op_31_26=0x00, op_25_22=0xf | **ui12 零扩展** |
| 运算 | pcaddu12i | 1RI | op_31_26=0x07, bit25=0 | si20 << 12 |
| 移位 | sll.w | 3R | op_31_26=0x00, op_25_22=0x0, op_21_20=0x1, op_19_15=0x0e | — |
| 移位 | srl.w | 3R | op_31_26=0x00, op_25_22=0x0, op_21_20=0x1, op_19_15=0x0f | — |
| 移位 | sra.w | 3R | op_31_26=0x00, op_25_22=0x0, op_21_20=0x1, op_19_15=0x10 | — |
| 乘法 | mul.w | 3R | op_21_20=0x1, op_19_15=0x18 | — |
| 乘法 | mulh.w | 3R | op_21_20=0x1, op_19_15=0x19 | — |
| 乘法 | mulh.wu | 3R | op_21_20=0x1, op_19_15=0x1a | — |
| 除法 | div.w | 3R | op_21_20=0x2, op_19_15=0x00 | — |
| 除法 | mod.w | 3R | op_21_20=0x2, op_19_15=0x01 | — |
| 除法 | div.wu | 3R | op_21_20=0x2, op_19_15=0x02 | — |
| 除法 | mod.wu | 3R | op_21_20=0x2, op_19_15=0x03 | — |

---

## 修改文件

### 1. alu.v — 扩展 ALU 操作

#### 1.1 端口位宽变更
- `alu_op`: `[11:0]` → `[18:0]`（增加 7 位用于乘除）

#### 1.2 新增操作信号 (bit [18:12])
```
[12] → op_mul    有符号乘法，取低 32 位
[13] → op_mulh   有符号乘法，取高 32 位
[14] → op_mulhu  无符号乘法，取高 32 位
[15] → op_div    有符号除法
[16] → op_mod    有符号取模
[17] → op_divu   无符号除法
[18] → op_modu   无符号取模
```

注：sll.w / srl.w / sra.w 复用已有的 `op_sll`(bit[8]) / `op_srl`(bit[9]) / `op_sra`(bit[10])，不新增 ALU op 位。

#### 1.3 新增运算逻辑

乘法采用**方案B：显式符号扩展到 64-bit**，确保跨工具链一致性。

```verilog
// 有符号 64 位乘积（显式符号扩展）
wire [63:0] mul_signed_64;
assign mul_signed_64 = {{32{alu_src1[31]}}, alu_src1} * {{32{alu_src2[31]}}, alu_src2};

// 无符号 64 位乘积（显式零扩展）
wire [63:0] mul_unsigned_64;
assign mul_unsigned_64 = {32'b0, alu_src1} * {32'b0, alu_src2};

// 各乘法结果
wire [31:0] mul_w_result;
wire [31:0] mulh_w_result;
wire [31:0] mulh_wu_result;

assign mul_w_result   = mul_signed_64[31:0];
assign mulh_w_result  = mul_signed_64[63:32];
assign mulh_wu_result = mul_unsigned_64[63:32];
```

#### 1.4 除法/取模（除0 返回任意值，不触发例外）

```verilog
wire        div_by_zero;
assign div_by_zero = (alu_src2 == 32'd0);

wire [31:0] div_w_result;
wire [31:0] mod_w_result;
wire [31:0] div_wu_result;
wire [31:0] mod_wu_result;

assign div_w_result  = div_by_zero ? 32'd0 : $signed(alu_src1) / $signed(alu_src2);
assign mod_w_result  = div_by_zero ? 32'd0 : $signed(alu_src1) % $signed(alu_src2);
assign div_wu_result = div_by_zero ? 32'd0 : alu_src1 / alu_src2;
assign mod_wu_result = div_by_zero ? 32'd0 : alu_src1 % alu_src2;
```

#### 1.5 最终 MUX 追加
```verilog
| ({32{op_mul   }} & mul_w_result)
| ({32{op_mulh  }} & mulh_w_result)
| ({32{op_mulhu }} & mulh_wu_result)
| ({32{op_div   }} & div_w_result)
| ({32{op_mod   }} & mod_w_result)
| ({32{op_divu  }} & div_wu_result)
| ({32{op_modu  }} & mod_wu_result)
```

---

### 2. mycpu_top.v — 指令解码与控制

#### 2.1 新增指令解码信号 (wire)

```verilog
// 2RI 立即数指令
wire id_inst_slti;       // op_31_26=0x00, op_25_22=0x8
wire id_inst_sltui;      // op_31_26=0x00, op_25_22=0x9
wire id_inst_andi;       // op_31_26=0x00, op_25_22=0xd
wire id_inst_ori;        // op_31_26=0x00, op_25_22=0xe
wire id_inst_xori;       // op_31_26=0x00, op_25_22=0xf

// 1RI
wire id_inst_pcaddu12i;  // op_31_26=0x07, bit25=0

// 3R 移位（寄存器版本）
wire id_inst_sll_w;      // op_31_26=0x00, op_25_22=0x0, op_21_20=0x1, op_19_15=0x0e
wire id_inst_srl_w;      // op_31_26=0x00, op_25_22=0x0, op_21_20=0x1, op_19_15=0x0f
wire id_inst_sra_w;      // op_31_26=0x00, op_25_22=0x0, op_21_20=0x1, op_19_15=0x10

// 3R 乘除
wire id_inst_mul_w;      // op_21_20=0x1, op_19_15=0x18
wire id_inst_mulh_w;     // op_21_20=0x1, op_19_15=0x19
wire id_inst_mulh_wu;    // op_21_20=0x1, op_19_15=0x1a
wire id_inst_div_w;      // op_21_20=0x2, op_19_15=0x00
wire id_inst_mod_w;      // op_21_20=0x2, op_19_15=0x01
wire id_inst_div_wu;     // op_21_20=0x2, op_19_15=0x02
wire id_inst_mod_wu;     // op_21_20=0x2, op_19_15=0x03
```

#### 2.2 指令解码赋值

```verilog
// 2RI 立即数指令（op_31_26 + op_25_22 即可唯一确定）
assign id_inst_slti  = op_31_26_d[6'h00] & op_25_22_d[4'h8];
assign id_inst_sltui = op_31_26_d[6'h00] & op_25_22_d[4'h9];
assign id_inst_andi  = op_31_26_d[6'h00] & op_25_22_d[4'hd];
assign id_inst_ori   = op_31_26_d[6'h00] & op_25_22_d[4'he];
assign id_inst_xori  = op_31_26_d[6'h00] & op_25_22_d[4'hf];

// 1RI
assign id_inst_pcaddu12i = op_31_26_d[6'h07] & ~inst[25];

// 3R 移位
assign id_inst_sll_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0e];
assign id_inst_srl_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0f];
assign id_inst_sra_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h10];

// 3R 乘除
assign id_inst_mul_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h18];
assign id_inst_mulh_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h19];
assign id_inst_mulh_wu = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h1a];
assign id_inst_div_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h00];
assign id_inst_mod_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h01];
assign id_inst_div_wu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h02];
assign id_inst_mod_wu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h03];
```

#### 2.3 ALU op 信号位宽变更

```
wire [11:0] id_alu_op  →  wire [18:0] id_alu_op
reg  [11:0] id_ex_alu_op  →  reg  [18:0] id_ex_alu_op
wire [11:0] ex_alu_op  →  wire [18:0] ex_alu_op
alu.v 例化端口自动跟随
```

#### 2.4 ALU op 信号赋值

```verilog
// 已有 ALU op（保持不变）
assign id_alu_op[ 0] = id_inst_add_w | id_inst_addi_w | id_inst_ld_w | id_inst_st_w
                       | id_inst_jirl | id_inst_bl | id_inst_pcaddu12i;  // pcaddu12i: PC+imm
assign id_alu_op[ 1] = id_inst_sub_w;
assign id_alu_op[ 2] = id_inst_slt | id_inst_slti;
assign id_alu_op[ 3] = id_inst_sltu | id_inst_sltui;
assign id_alu_op[ 4] = id_inst_and | id_inst_andi;
assign id_alu_op[ 5] = id_inst_nor;
assign id_alu_op[ 6] = id_inst_or | id_inst_ori;
assign id_alu_op[ 7] = id_inst_xor | id_inst_xori;
assign id_alu_op[ 8] = id_inst_slli_w | id_inst_sll_w;
assign id_alu_op[ 9] = id_inst_srli_w | id_inst_srl_w;
assign id_alu_op[10] = id_inst_srai_w | id_inst_sra_w;
assign id_alu_op[11] = id_inst_lu12i_w;

// 新增乘除 ALU op
assign id_alu_op[12] = id_inst_mul_w;
assign id_alu_op[13] = id_inst_mulh_w;
assign id_alu_op[14] = id_inst_mulh_wu;
assign id_alu_op[15] = id_inst_div_w;
assign id_alu_op[16] = id_inst_mod_w;
assign id_alu_op[17] = id_inst_div_wu;
assign id_alu_op[18] = id_inst_mod_wu;
```

#### 2.5 立即数生成

新增 `id_need_ui12`（零扩展）和扩展 `id_need_si20`：

```verilog
// id_need_ui12: zero-extend for andi/ori/xori
wire id_need_ui12;
assign id_need_ui12 = id_inst_andi | id_inst_ori | id_inst_xori;

// id_need_si20: 扩展到 pcaddu12i
assign id_need_si20 = id_inst_lu12i_w | id_inst_pcaddu12i;

// id_imm 生成（新增 id_need_ui12 分支）
assign id_imm = id_src2_is_4 ? 32'h4                      :
                id_need_si20 ? {id_i20[19:0], 12'b0}      :
                id_need_ui12 ? {20'b0, id_i12[11:0]}      :  // ← 新增
               /*need_si12*/ {{20{id_i12[11]}}, id_i12[11:0]};
```

#### 2.6 控制信号更新

```verilog
// src1_is_pc: 新增 pcaddu12i
assign id_src1_is_pc = id_inst_jirl | id_inst_bl | id_inst_pcaddu12i;

// src2_is_imm: 新增 2RI 立即数指令 + pcaddu12i
// 注意：sll.w / srl.w / sra.w 是 3R 指令，src2 来自 rk，不加入
assign id_src2_is_imm = id_inst_slli_w |
                        id_inst_srli_w |
                        id_inst_srai_w |
                        id_inst_addi_w |
                        id_inst_ld_w   |
                        id_inst_st_w   |
                        id_inst_lu12i_w|
                        id_inst_jirl   |
                        id_inst_bl     |
                        id_inst_slti   |
                        id_inst_sltui  |
                        id_inst_andi   |
                        id_inst_ori    |
                        id_inst_xori   |
                        id_inst_pcaddu12i;

// gr_we: 所有新指令均回写，无需特殊处理（默认排除的只有 st_w/beq/bne/b）
```

---

## 不变部分确认

以下逻辑无需修改：
- **寄存器文件**：读写端口不变
- **转发逻辑**：新指令的 ALU 结果通过现有的 forwarding path 自动转发，无需修改
- **Load-use 检测**：新指令都不是 load，不会触发 stall
- **分支决议**：分支相关逻辑不变
- **EX/MEM/MEM/WB 流水线寄存器**：数据路径不变（ALU result, dest, gr_we 等字段通用）
- **sll.w / srl.w / sra.w**：复用 alu.v 已有的移位硬件（`op_sll/op_srl/op_sra`），ALU 输入 `alu_src1 << alu_src2[4:0]` 对立即数和寄存器移位均适用
- **pcaddu12i 与 lu12i.w 对比**：两者都使用 `{si20, 12'b0}` 立即数；lu12i.w 把立即数直通到输出（src2 pass-through），pcaddu12i 执行 `PC + {si20, 12'b0}`（ADD 操作），通过 ALU op 区分

---

## 仿真验证计划

1. `cd exp10/soc_verify/soc_bram/testbench && make iverilog` 编译
2. 运行测试 n21~n36（共 16 条），对比 `golden_trace.txt`：
   - n21: pcaddu12i
   - n22: slti
   - n23: sltui
   - n24: andi
   - n25: ori
   - n26: xori
   - n27: sll.w
   - n28: sra.w
   - n29: srl.w
   - n30: div.w
   - n31: div.wu
   - n32: mul.w
   - n33: mulh.w
   - n34: mulh.wu
   - n35: mod.w
   - n36: mod.wu
3. 回归运行已通过的测试（n1~n20）确保没有退步
