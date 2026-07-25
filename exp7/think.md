实践任务 7：不考虑相关冲突处理的简单流水线 CPU
本实践任务要求在实践任务 6 实现的单周期 CPU 基础上完成以下工作：
1. 调整 CPU 顶层接口，增加指令 RAM 的片选信号 inst_sram_en 和数据 RAM 的片选信号
data_sram_en。
2. 调整 CPU 顶层接口，将 inst_sram_we 和 data_sram_we 都从 1 比特的写使能调整为 4 比特的字节写使能。
加入这两个信号之后,查询得知inst_sram为指令存储器,使能为1,写使能为0.
data_sram为数据存储器,有读和写功能,指令中有st写指令,ld存指令,都是一个字,4个字节,
data_sram_en应该有st和ld其中一条并与上vaild数据有效信号
data_sram_we为4'b1111

五级流水线前,先看看前面写的cpu代码能不能通过仿真
开始仿真
第一个bug
reference: PC = 0x1c000000, wb_rf_wnum = 0x0c, wb_rf_wdata = 0xffffffff
mycpu    : PC = 0x1c000004, wb_rf_wnum = 0x0c, wb_rf_wdata = 0xffffffff
指令存储器是同步的,所以pc会延迟一拍,所以要加上一个pc寄存器,延长一个时钟周期

第2个bug
reference: PC = 0x1c010588, wb_rf_wnum = 0x0e, wb_rf_wdata = 0x0000aaaa
mycpu    : PC = 0x1c010588, wb_rf_wnum = 0x0e, wb_rf_wdata = 0x00000000

1c010588:	2880018e 	ld.w	$r14,$r12,0 将$r12+0地址的值写入到$r14中
bridge bridge_1x2.v 的作用是把 CPU 的一根数据总线分出两条支路：
                    ┌──────────┐
                    │   CPU    │
                    └────┬─────┘
                         │ 一条数据总线 (cpu_data)
                    ┌────┴─────┐
                    │  Bridge  │  ← 看地址决定路由到哪
                    └──┬───┬───┘
                       │   │
              ┌────────┘   └────────┐
              ↓                     ↓
        ┌──────────┐          ┌──────────┐
        │ Data RAM │          │ Confreg  │
        │ (普通内存)│          │ (外设寄存器)│
        └──────────┘          └──────────┘
因为路径上每个环节都是同步读（BRAM、Bridge 选通、Confreg 都是 posedge clk 才更新输出），数据需要 1 个时钟周期才能从 Confreg 返回到 CPU。单周期 CPU 在同一周期就写回了寄存器，此时数据还没到达——于是写入了 0x00000000（复位默认值或上一次读的旧值）。

开始五级流水线
时钟周期    T1      T2      T3      T4      T5      T6      T7
─────────────────────────────────────────────────────────────────
指令1      IF      ID      EX      MEM     WB
指令2              IF      ID      EX      MEM     WB
指令3                      IF      ID      EX      MEM     WB
指令4                              IF      ID      EX      MEM
指令5                                      IF      ID      EX
─────────────────────────────────────────────────────────────────

if阶段通过pc从指令存储器取相应的指令
id阶段根据指令分割并计算控制信号,寄存器号码,立即数,
ex阶段计算跳转地址和要写入的数据
mem阶段访存或写存
wb阶段将内存值或alu结果写入寄存器



