# ID/EX 流水线寄存器

## 新增变量

| 变量 | 位宽 | 类型 | 作用 |
|------|------|------|------|
| `id_rkd_src` | 5 | wire | 第二源寄存器号，beq/st_w 时 = rd，否则 = rk |
| `id_ex_alu_op` | 12 | reg | ALU 操作码（one-hot） |
| `id_ex_src1_is_pc` | 1 | reg | ALU src1 = PC (jirl/bl) |
| `id_ex_src2_is_imm` | 1 | reg | ALU src2 = 立即数 |
| `id_ex_res_from_mem` | 1 | reg | 结果来自内存 (ld.w) |
| `id_ex_gr_we` | 1 | reg | 寄存器写使能 |
| `id_ex_mem_we` | 1 | reg | 内存写使能 (st.w) |
| `id_ex_dest` | 5 | reg | 目标寄存器号 |
| `id_ex_pc` | 32 | reg | 当前指令 PC（jirl/bl 链接地址 + debug trace） |
| `id_ex_rj_value` | 32 | reg | ALU 源操作数 1 |
| `id_ex_rkd_value` | 32 | reg | ALU 源操作数 2 / store 数据 |
| `id_ex_imm` | 32 | reg | 立即数 |
| `id_ex_rj` | 5 | reg | rj 编号（用于后续转发比较） |
| `id_ex_rkd_src` | 5 | reg | 第二源寄存器号（用于后续转发比较） |
| `id_ex_valid` | 1 | reg | 有效标志，=0 时 EX 阶段为气泡 |

## 流水线位置

```
IF → IF/ID → ID → ID/EX → EX (+ MEM + WB 暂为组合逻辑)
```

## 涉及修改的原有代码

| 原代码 | 改为 | 原因 |
|--------|------|------|
| `assign alu_src1 = src1_is_pc ? if_id_pc : rj_value` | `id_ex_src1_is_pc ? id_ex_pc : id_ex_rj_value` | 使用寄存器输出 |
| `assign alu_src2 = src2_is_imm ? imm : rkd_value` | `id_ex_src2_is_imm ? id_ex_imm : id_ex_rkd_value` | 同上 |
| `.alu_op(alu_op)` | `.alu_op(id_ex_alu_op)` | 同上 |
| `(mem_we \|\| res_from_mem) && valid` | `(id_ex_mem_we \|\| id_ex_res_from_mem) && id_ex_valid` | 同上 |
| `{4{mem_we && valid}}` | `{4{id_ex_mem_we && id_ex_valid}}` | 同上 |
| `data_sram_wdata = rkd_value` | `id_ex_rkd_value` | 同上 |
| `final_result = res_from_mem ? ...` | `id_ex_res_from_mem ? ...` | 同上 |
| `load_pending <= res_from_mem && valid` | `id_ex_res_from_mem && id_ex_valid` | 同上 |
| `load_dest_r <= dest` | `id_ex_dest` | 同上 |
| `load_pc_r <= if_id_pc` | `id_ex_pc` | 同上 |
| `rf_we = load_pending \|\| (gr_we && valid && !res_from_mem)` | `(id_ex_gr_we && id_ex_valid && !id_ex_res_from_mem)` | 同上 |
| `rf_waddr = load_pending ? load_dest_r : dest` | `id_ex_dest` | 同上 |
| `debug_wb_pc = load_pending ? load_pc_r : if_id_pc` | `id_ex_pc` | 同上 |

## 当前流水线状态

```
已完成:  IF → IF/ID → ID → ID/EX → EX+MEM+WB(组合逻辑)
待添加: EX/MEM, MEM/WB, 转发, 冒险处理
```

> 注意: `load_pending` 机制仍然保留，因为数据存储器 BRAM 的 1 周期延迟尚未通过流水线寄存器处理。后续添加 EX/MEM → MEM/WB 后将移除此 hack。
