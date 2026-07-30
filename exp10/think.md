## exp10 乘除指令实现思路

### 1. 整体策略

乘法指令（mul.w / mulh.w / mulh.wu）使用单周期组合逻辑，FPGA 上综合为 DSP48E1 硬核乘法器，3-5ns 完成，100MHz 下时序满足。

除法指令（div.w / mod.w / div.wu / mod.wu）分两条路径：

| | 仿真 (iverilog) | 上板 (Vivado) |
|---|---|---|
| 方案 | 组合逻辑 `/` `%` 运算符 | 多周期时序除法器 |
| 周期数 | 1 | 32 |
| 原因 | 虚拟时钟无物理延迟 | 组合除法器 20-35ns，100MHz(10ns) 不满足时序 |

仿真用组合逻辑是为了快速验证功能，上板时替换为多周期除法器。

---

### 2. 多周期除法器设计

#### 2.1 算法：恢复余数法（Restoring Division）

使用联合寄存器 `S = {A, Q}`，其中 A 初始为 0（余数），Q 初始为被除数：

```
初始化: S = {32'b0, src1_abs}
        M = src2_abs（除数）

每周期:
  1. S[63:32] - M 试减
  2. 够减 (sub_ok=1) → S[63:32] = 减法结果, S[0] = 1
     不够减 (sub_ok=0) → S 不变
  3. S << 1（最后一周期不移位）

32 周期后: S[63:32] = 余数, S[31:0] = 商
```

#### 2.2 符号处理

算法本身是无符号除法。有符号指令在外面包一层：

```
1. src1_abs = |src1|, src2_abs = |src2|
2. 商符号 = src1[31] ^ src2[31]，余符号 = src1[31]
3. 用绝对值跑无符号算法
4. 商 = 商符号 ? -Q : Q, 余 = 余符号 ? -A : A
```

#### 2.3 除零处理

`src2_abs == 0` 时直接返回 0，不跑 32 周期，不触发例外。

#### 2.4 模块接口

```verilog
module div_unit(
    input  wire        clk, rst,
    input  wire        valid,       // 除法指令在 ID/EX 中（电平）
    input  wire [31:0] src1, src2,
    input  wire [ 1:0] op,          // 00=div.w, 01=mod.w, 10=div.wu, 11=mod.wu
    output reg  [31:0] result,
    output reg         busy
);
```

- `valid`：来自 mycpu_top 的 `id_ex_valid && is_div_op`，电平信号
- 内部用上升沿检测 `auto_start = valid && !valid_r && !busy` 自动启动
- `busy`：高电平表示正在计算，控制流水线停顿

---

### 3. 流水线停顿机制

#### 3.1 时序

```
周期 N:   div 写入 ID/EX，valid 上升沿 → auto_start=1
周期 N+1: busy=1，PC 和 IF/ID 开始 hold
周期 N+1 ~ N+32: 除法器逐位迭代
周期 N+32: cnt=31，最后一周期试减，busy→0，result 输出
周期 N+33: busy=0 → id_stall=0 → 流水线恢复运行
```

#### 3.2 停顿控制

```
id_stall = load_use_stall || div_busy

id_stall=1 时:
  PC      → hold（不递增）
  IF/ID   → hold（后续指令不前进）

EX 阶段特殊处理:
  load_use_stall → ID/EX = NOP（气泡）
  div_busy       → ID/EX = hold（除法指令保留在 EX 中）
                  → EX/MEM = NOP（中间值不进 MEM）
```

#### 3.3 转发门控

除法器计算期间，`ex_result` 不是有效值。ID 阶段转发需加 `!div_busy` 门控：

```verilog
assign rj_value = id_ex_gr_we && !id_ex_res_from_mem && !div_busy && (id_ex_dest == rj)
                  ? ex_result : ...
```

除法完成、busy→0 的同一拍 result 生效，转发路径自动打开。

---

### 4. 乘法器设计

纯组合逻辑，显式符号扩展避免跨工具链差异：

```verilog
// 有符号 64-bit 积：显式符号扩展
assign signed_product   = {{32{src1[31]}}, src1} * {{32{src2[31]}}, src2};
// 无符号 64-bit 积：显式零扩展
assign unsigned_product = {32'b0, src1} * {32'b0, src2};
```

| op | 指令 | 输出 |
|----|------|------|
| 3'b000 | mul.w | signed_product[31:0] |
| 3'b001 | mulh.w | signed_product[63:32] |
| 3'b010 | mulh.wu | unsigned_product[63:32] |

---

写于26/7/30,目前借不到板子,无法验证相关时序是否正确
