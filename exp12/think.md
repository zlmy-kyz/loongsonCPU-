# exp12 调试记录

## bug1: ld 与分支的 load-use 冒险(历史遗留)

**出错指令(处理器 GET_EXIMM):**
```
ld.w  $r13, $r13, 0
ori   $r12, $r0, 0x1
beq   $r13, $r12, syscall_ex
```

**问题:** 同步 BRAM 数据 WB 才就绪,分支在 ID 就决议。
(1) ld 隔一条 beq:beq 在 ID 时 ld 在 MEM,数据未出
(2) ld 相邻 beq:beq 在 ID 时 ld 在 EX,要两周期才出

ALU 指令不受影响(EX 才用数据,旁路来得及);分支 ID 决议,只能等 ld 到 WB 从 mem_wb 转发(rf_wdata)。

**解决:** 阻塞 + mem_wb 转发

| 信号 | 条件 | 动作 |
|------|------|------|
| load_use_stall | ld 在 EX + ID 依赖 | 阻塞 |
| load_use_fwd | ld 在 MEM + ID 依赖 | 不阻塞,EX 旁路(仅 ALU) |
| load_use_stall_branch | ld 在 MEM + ID 是分支且依赖 | 阻塞(新增) |

```
id_stall = load_use_stall || load_use_stall_branch
```

(1) 阻塞 1 拍:
```
IF  ID  EX  MEM  WB
ld
xxx ld
beq xxx ld
xxx beq nop xxx ld   ← stall(load_use_stall_branch)
xxx beq nop xxx ld   ← ld 到 WB,转发 ✓
```

(2) 阻塞 2 拍(两信号接力):
```
IF  ID  EX  MEM  WB
ld
beq ld
xxx beq ld
xxx beq nop ld       ← stall(load_use_stall)
xxx beq nop nop ld   ← stall(load_use_stall_branch)
xxx beq nop nop ld   ← ld 到 WB,转发 ✓
```

**关键:** 分支决议在 ID,不能像 ALU 一样等 EX 旁路,必须阻塞到 ld 到 WB。

## bug2: CRMD 复位值错误

**现象:** n47 第一条 `csrxchg t0, t1, csr_crmd` 写回 GR[t0] 的值与 golden_trace 不符——仿真读到 CRMD 旧值 = 0,而 golden_trace 显示 0x8。

**根因:** csr.v 里所有 CSR 复位写成了全 0,但规范规定 CRMD 复位时 **DA=1**:

> CSR.CRMD 的 PLV=0, IE=0, **DA=1**, PG=0, DATF=0, DATM=0

即复位后 CRMD = 0x8。DA(直接地址翻译)必须为 1 的原因:复位撤销时 MMU/TLB 尚未初始化,取指必须走直接映射,否则第一条指令都取不到(复位后 PC = 0x1C000000,物理地址也是它,前提就是直接映射)。

**证据:**
- 龙芯架构32位手册 P57 6.3复位 CRMD 复位值 PLV=0/IE=0/DA=1/PG=0 → 0x8
                  p61 7.4.1当前模式信息 CRMD 相关位及名字
- golden_trace:`1c058234 0c 00000008`(第一条 csrxchg 写回 8);n47 末尾 `1c058354 0c 00000008`(异常/ertn 全程没动 DA,DA 从复位保留到最后)

**解决:** csr.v 中 crmd 复位值改 `32'h8`。

```verilog
always @(posedge clk) begin
    if (reset) crmd <= 32'h8;   // 复位值: DA=1(直接地址映射), PLV=0, IE=0
    ...
```

## bug3: ertn 跳转目标用旧 ERA(CSR 版本的数据冒险)

**出错指令(处理器 ex_finish 返回路径):**

```
csrrd  r13, 0x6      ; r13 ← 旧 ERA(0x1c05825c, 即 syscall 的地址)
addi.w r13, r13, 4   ; r13 ← 0x1c058260(+4 跳过 syscall)
csrwr  r13, 0x6      ; ERA ← r13(0x1c058260); r13 ← 旧 ERA(交换)
ertn                 ; PC ← ERA(必须跳到 0x1c058260)
```

**现象:** ertn 在 ID 决议时,csrwr(写 ERA)还在流水线里,era 寄存器仍是旧值 0x1c05825c——ertn 会跳回 syscall 本身,死循环。

```
         IF      ID      EX      MEM     WB
  1      csrrd
  2      addi    csrrd
  3      csrwr   addi    csrrd
  4      ertn    csrwr   addi    csrrd    ← ertn 读 era = 旧值,csrwr 的写在 WB 才落账
  5      xxx     ertn    csrwr   addi    csrrd
```

**根因:** 程序顺序上 csrwr 先写 ERA、ertn 后读 ERA,但 csrwr 的写在 WB 才落账,ertn 在 ID 读到旧值。这是 CSR 版的 RAW 冒险——之前只给通用寄存器做了前递,没给 CSR 做。

**解决:** ertn 的跳转目标检查流水线中写 ERA(0x6)的指令,优先用它的写数据:

```verilog
// CSR 写移到 EX 后,只需前递 EX 一级;更早的写已落账
assign ertn_target = (id_ex_csr_we && id_ex_valid && id_ex_csr_waddr == 14'h6) ? id_ex_csr_wdata :
                     csr_rdata2;
assign br_target = inst_ertn ? ertn_target : ...;
```

**关键:** 只要"写目标"是寄存器(GR 或 CSR),紧邻的"读"就需要前递。CSR 是全局状态,同样适用——之前只给 GR 做了前递,漏了 CSR。