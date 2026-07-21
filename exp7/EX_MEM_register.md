# EX/MEM 流水线寄存器

## 新增变量

| 变量 | 位宽 | 类型 | 作用 |
|------|------|------|------|
| `ex_mem_alu_result` | 32 | reg | ALU 结果（load/store 地址 或 运算结果） |
| `ex_mem_rkd_value` | 32 | reg | store 数据（st.w 写入内存的值） |
| `ex_mem_dest` | 5 | reg | 目标寄存器号 |
| `ex_mem_gr_we` | 1 | reg | 寄存器写使能 |
| `ex_mem_mem_we` | 1 | reg | 内存写使能 |
| `ex_mem_res_from_mem` | 1 | reg | 结果来自内存 (ld.w) |
| `ex_mem_valid` | 1 | reg | 有效标志 |
| `ex_mem_pc` | 32 | reg | 当前指令 PC（debug trace） |

## 流水线位置

```
IF → IF/ID → ID → ID/EX → EX → EX/MEM → MEM → (load_pending) → WB
```

## 涉及修改的原有代码

| 原代码 | 改为 | 原因 |
|--------|------|------|
| `data_sram_en = (id_ex_mem_we \|\| ...) && id_ex_valid` | `(ex_mem_mem_we \|\| ...) && ex_mem_valid` | MEM 阶段用 EX/MEM 输出 |
| `data_sram_we = {4{id_ex_mem_we && id_ex_valid}}` | `{4{ex_mem_mem_we && ex_mem_valid}}` | 同上 |
| `data_sram_addr = alu_result` | `ex_mem_alu_result` | 同上 |
| `data_sram_wdata = id_ex_rkd_value` | `ex_mem_rkd_value` | 同上 |
| `final_result = id_ex_res_from_mem ? ... : alu_result` | `ex_mem_res_from_mem ? ... : ex_mem_alu_result` | 同上 |
| `load_pending <= id_ex_res_from_mem && id_ex_valid` | `ex_mem_res_from_mem && ex_mem_valid` | 同上 |
| `load_dest_r <= id_ex_dest` | `ex_mem_dest` | 同上 |
| `load_pc_r <= id_ex_pc` | `ex_mem_pc` | 同上 |
| `rf_we = ... (id_ex_gr_we && id_ex_valid ...)` | `(ex_mem_gr_we && ex_mem_valid ...)` | 同上 |
| `rf_waddr = ... : id_ex_dest` | `ex_mem_dest` | 同上 |
| `rf_wdata = ... : alu_result` | `ex_mem_alu_result` | 同上 |
| `debug_wb_pc = ... : id_ex_pc` | `ex_mem_pc` | 同上 |

## 当前流水线状态

```
已完成:  IF → IF/ID → ID → ID/EX → EX → EX/MEM → MEM+WB(组合)
待添加: MEM/WB, 转发, 冒险处理
```

> `load_pending` 仍然保留。MEM/WB 添加后将移除此 hack，load 数据自然流到 WB 阶段。
