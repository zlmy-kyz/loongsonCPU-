# exp8 调试记录

exp8 在 exp7 五级流水线骨架上增加了**控制冒险**和**数据冒险**的处理。调试过程中遇到四个主要问题，逐一记录如下。

---

## Bug 1：分支冒险（控制冒险）—— 分支延迟槽指令未冲刷

**出错指令：**

```
1c000004:  02bffc0c  addi.w  $r12, $r0, -1(0xfff)
1c000008:  50fff800  b       65528(0xfff8)   # 1c010000 <locate>
```

**问题分析：**

```
         IF      ID      EX      MEM     WB
  1      add
  2      b       add
  3      sub     b       add       ← b 在 ID 阶段计算出跳转地址
  4      addi    sub     b         ← 但 sub（b 之后的指令）已经进入流水线
```

`b` 指令在 ID 阶段即可计算出跳转目标（`if_id_pc + br_offs`），但下一条指令 `sub` 已经取指并进入了 IF/ID 寄存器。如果不处理，`sub` 会继续执行，多出一条不该执行的指令。而 LoongArch32 的分支指令**没有延迟槽**，分支跳转之后紧接着的就是目标指令。

**解决方法：**

分支跳转成立时，将 IF/ID 寄存器清零（插入气泡/NOP），让 `sub` 变成空操作：

```
         IF      ID      EX      MEM     WB
  1      add
  2      b       add
  3      sub     b       add
  4      addi    nop     b       add      ← IF/ID 被清掉
```

对应代码：`id_flush` 信号在 `br_taken` 时拉高，IF/ID 寄存器的 `valid` 清零、`pc` 清零，`inst` 变为 0（即 NOP），使分支后误取的那条指令被冲刷。

---

## Bug 2：RAW 数据冒险 —— ADD/LU12I 写后读冲突

**出错指令：**

```
1c010000:  157f5fe4  lu12i.w  $r4, -263425(0xbfaff)
1c010004:  02810084  addi.w   $r4, $r4, 64(0x40)
```

**问题分析：**

```
         IF      ID      EX      MEM     WB
  1                        lu12i
  2              addi              lu12i
```

`lu12i.w` 在 EX 阶段通过组合逻辑计算出立即数，但下一个时钟周期 `addi.w` 需要用它作为源操作数时，`lu12i.w` 还没写回寄存器（要等到 WB 阶段）。`addi.w` 从寄存器堆读到的仍是 `$r4` 的旧值。

**解决方法：数据前递（Forwarding）**

`addi.w` 一到 ID 阶段就开始检测数据冒险：将自身的源寄存器（`rj`, `rkd_src`）与流水线中各级寄存器（ID/EX → EX/MEM → MEM/WB）的 `dest` 逐一比对。匹配且对应阶段有写使能（`gr_we`）时，取对应阶段的 ALU 结果前递到 ID 阶段的 `rj_value` / `rkd_value`，取代寄存器堆读出的旧值。

前递优先级由近到远：ID/EX > EX/MEM > MEM/WB。

对应代码：`rj_value` 和 `rkd_value` 的三路 MUX，分别检测 `id_ex_dest`、`ex_mem_dest`、`mem_wb_dest` 是否与源寄存器匹配。

---

## Bug 3：Load-Use 冒险 —— LD 后紧跟 XOR

**出错指令：**

```
1c010168:  2880018e  ld.w  $r14, $r12, 0
1c01016c:  0015b5ce  xor   $r14, $r14, $r13
```

**问题分析：**

```
         IF      ID      EX      MEM     WB
  1              xor
  2                      ld
```

`ld.w` 的数据要到 MEM 阶段结束时（`data_sram_rdata`）才从数据存储器读出，而 `xor` 在 EX 阶段就需要用它计算。**普通的数据前递无法解决**，因为 `ld.w` 在 EX 阶段还没有数据可用。

**解决方法：停顿一周期 + WB→EX 转发**

```
         IF      ID      EX      MEM     WB
  1              xor
  2                      ld
  3              xor     nop     ld              ← stall: ID 保持 xor, EX 插入气泡
  4                      xor     nop     ld      ← ld 到 WB, data_sram_rdata 就绪
  5                              xor     nop     ← WB→EX 转发: data_sram_rdata → ALU
```

**两个检测信号：**

| 信号 | 检测条件 | 动作 |
|------|---------|------|
| `load_use_stall` | `id_ex_res_from_mem && id_ex_dest == 任一源寄存器` | **停顿** + 转发 |
| `load_use_fwd` | `ex_mem_res_from_mem && ex_mem_dest == 任一源寄存器` | **只转发**，不停顿 |

- **相邻**（ld 在 EX, 依赖指令在 ID）：`load_use_stall` 触发 → 停顿一个周期，ld 推进到 MEM/WB 时数据刚好出来，转发到 ALU
- **隔一条**（ld 在 MEM, 依赖指令在 EX）：`load_use_fwd` 触发 → 不需要停顿，WB 阶段的数据直接转发到 ALU 即可

**停顿控制：**

- `id_stall = load_use_stall`：拉高时 PC 保持不变、IF/ID 保持不变、ID/EX 清零（插入气泡）
- `id_ex_load_use`：流水线寄存器记录 `load_use` 信号，传递到 EX 阶段用于控制 WB→EX 转发 MUX

**ID 阶段前递保护：**

普通数据前递中，`id_ex_res_from_mem` 为 1 时**不参与转发**——ld 在 EX 阶段还没有数据，转发的是地址而非内存值。

---

## Bug 4：Stall 期间指令被覆盖 —— BRAM 时序问题

**出错现象：**

```
期望: PC=1c01016c, inst=0015b5ce (xor)
实际: PC=1c01016c, inst=0040a5cf (下一条 slli.w)
```

**问题分析：**

BRAM 是同步读（registered read），`inst_sram_rdata` 对应的是**上一拍**的 `inst_sram_addr`。

时序如下：

```
周期  |  pc          |  inst_sram_rdata  |  id_stall  |  id_stall_r
T0    |  1c01016c    |  0015b5ce (xor)   |  0         |  0
T1    |  1c010170 ←  |  0040a5cf (slli)  |  1 ←       |  0         ← stall 上升沿
T2    |  1c010170    |  0050... (下下条)  |  1         |  1
```

T1 时 stall 拉高，PC 保持不变，但 BRAM 输出 `inst_sram_rdata` 在 T0→T1 已经更新为 `1c010170` 的指令（因为 T0 时 `addr = 1c010170`）。原来的 `assign inst = inst_sram_rdata` 直接取到了错误指令，导致 ID 阶段译码出错误的 `dest`。

**解决方法：stall 上升沿捕获**

```verilog
reg [31:0] stall_inst;    // stall 期间保持的正确指令
reg        id_stall_r;    // id_stall 延迟一拍的寄存器

always @(posedge clk) begin
    id_stall_r <= id_stall;
    if (id_stall && !id_stall_r)
        stall_inst <= inst_sram_rdata;   // 仅在 stall 第一拍捕获
end

assign inst = if_id_valid ? (id_stall_r ? stall_inst : inst_sram_rdata) : 32'd0;
```

`id_stall && !id_stall_r` 是 stall 上升沿检测——只在 stall 的**第一个**时钟上升沿成立。此时 `inst_sram_rdata` 还是被 stall 的那条指令（`0015b5ce`），将其捕获进 `stall_inst`。后续 stall 周期 `id_stall_r=1`，条件不成立，`stall_inst` 保持不动。

`inst` 的 MUX：当 `id_stall_r=1` 时（stall 期间）选择 `stall_inst`，否则正常使用 `inst_sram_rdata`。

---

## 小结

仿真通过，执行时间比 exp7（NOP 填充）快了 **3 倍多**。四个 bug 分别对应了流水线冒险处理的几个核心要点：

1. 分支跳转后冲刷 IF/ID —— 消除控制冒险
2. ALU 指令间的数据前递 —— 解决普通 RAW 冒险
3. Load-Use 停顿 + WB→EX 转发 —— 解决访存导致的 RAW 冒险
4. Stall 期间指令保持 —— 处理 BRAM 同步读的时序特性

exp8用的是阻塞,exp9用的是前递,我在exp8全部做完了