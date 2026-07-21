# IF/ID 流水线寄存器

## 新增变量

| 变量 | 位宽 | 类型 | 作用 |
|------|------|------|------|
| `if_id_pc` | 32 | reg | 延迟 1 拍的 PC，与 `inst_sram_rdata`（BRAM 输出）对齐 |
| `if_id_valid` | 1 | reg | 有效标志，=0 时 ID 阶段收到气泡（NOP） |

## 时序

```
周期 N:   pc = X  → inst_sram_addr = X
          inst_sram_rdata = inst@(X-4)    (BRAM 还在读上一个地址)

posedge:  pc <= nextpc = X+4
          if_id_pc <= pc = X
          if_id_valid <= 1
          BRAM: rdata <= inst@X           (BRAM 完成读)

周期 N+1: pc = X+4  → inst_sram_addr = X+4
          if_id_pc = X                    (匹配)
          inst_sram_rdata = inst@X        (匹配)
          → ID 阶段执行 PC=X 的指令 ✓
```

## 涉及修改的原有代码

| 原变量/代码 | 改为 | 原因 |
|-------------|------|------|
| `fetch_pc` (reg) | `if_id_pc` (reg) | 改名，明确是流水线寄存器 |
| `assign inst = inst_sram_rdata` | `assign inst = if_id_valid ? inst_sram_rdata : 32'd0` | 气泡时插入 NOP |
| `br_target = fetch_pc + br_offs` | `br_target = if_id_pc + br_offs` | 使用流水线寄存器输出 |
| `alu_src1 = fetch_pc` | `alu_src1 = if_id_pc` | 同上 |
| `debug_wb_pc = fetch_pc` | `debug_wb_pc = if_id_pc` | 同上 |
| `load_pc_r <= fetch_pc` | `load_pc_r <= if_id_pc` | 同上 |
