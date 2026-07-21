# MEM/WB 流水线寄存器

## 新增变量

| 变量 | 位宽 | 类型 | 作用 |
|------|------|------|------|
| `mem_wb_alu_result` | 32 | reg | ALU 结果 |
| `mem_wb_dest` | 5 | reg | 目标寄存器号 |
| `mem_wb_gr_we` | 1 | reg | 寄存器写使能 |
| `mem_wb_res_from_mem` | 1 | reg | 结果来自内存 |
| `mem_wb_valid` | 1 | reg | 有效标志 |
| `mem_wb_pc` | 32 | reg | 指令 PC（debug trace） |

## 删除的变量

| 变量 | 原因 |
|------|------|
| `load_pending` | 不再需要。load 数据经 MEM→BRAM→WB 自然到达 |
| `load_dest_r` | 同上 |
| `load_pc_r` | 同上 |
| `mem_result` | 不再需要。WB 直接读 data_sram_rdata |
| `final_result` | 不再需要。WB 直接 MUX 选数据 |

## 为什么 MEM/WB 不存 data_sram_rdata

和 `inst_sram_rdata` 一样，BRAM 已经是寄存输出：

```
MEM:   data_sram_addr = X → BRAM 开始读
posedge: BRAM rdata <= ram[X]
WB:    data_sram_rdata = ram[X] ✓ 直接可用
```

如果 MEM/WB 再存一次，会多延迟 1 周期（NB 赋值捕获旧值）。

## 流水线位置

```
IF → IF/ID → ID → ID/EX → EX → EX/MEM → MEM → MEM/WB → WB
```

## 涉及修改的原有代码

| 原代码 | 改为 |
|--------|------|
| `load_pending` + `rf_we = load_pending \|\| ...` | `rf_we = mem_wb_gr_we && mem_wb_valid` |
| `rf_waddr = load_pending ? load_dest_r : ex_mem_dest` | `mem_wb_dest` |
| `rf_wdata = load_pending ? data_sram_rdata : ex_mem_alu_result` | `mem_wb_res_from_mem ? data_sram_rdata : mem_wb_alu_result` |
| `debug_wb_pc = load_pending ? load_pc_r : ex_mem_pc` | `mem_wb_pc` |

## 完整流水线已建立

```
IF ─→ IF/ID ─→ ID ─→ ID/EX ─→ EX ─→ EX/MEM ─→ MEM ─→ MEM/WB ─→ WB
```

五级流水线骨架完成。后续添加转发和冒险处理。
