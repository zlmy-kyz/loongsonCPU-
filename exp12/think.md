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

