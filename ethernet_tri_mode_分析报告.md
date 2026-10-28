# `ethernet_tri_mode_latest` 工程分析报告

> 分析对象：`D:\乾芯科技\TSN\ethernet_tri_mode_latest`
> 规模：258 个文件 / 约 24.97 MB；其中 RTL 37 个 `.v`（7 937 行），testbench 6 个 `.v`（约 35k 行，含 1.3 MB Altera 原语模型）
> 分析方式：逐文件阅读 + 版本间 diff + PDF 文字层提取（自写 zlib 解析，见 `_analysis/pdf_extract.py`）
> 结论日期：2026-10-23

---

## 1. 一句话结论

这是一份 **OpenCores「Tri-mode Ethernet MAC」（10/100/1000 Mbps，IEEE 802.3）项目的 SVN 导出快照**，作者 Jon Gao，LGPL 授权，纯 Verilog-2001。SVN 目录结构完整保留（`trunk` / `tags` / `branches` / `web_uploads`），**`trunk` 是最新代码（RTL 最后修改 2009-01-08）**，`tags/rel-1-0`（2006-06）与 `tags/release-1-0`（2006-01）为历史发布点。

代码功能完整度较高（MAC 收发、CRC、地址过滤、广播限流、PAUSE 流控、RMON 计数、MDIO、GMII/MII 速率切换、半双工 CSMA/CD 全部具备），但**存在若干实质性缺陷与"未完成"部分**，直接复用到产品前必须处理，详见第 12 节：

| 级别 | 问题 | 影响 |
|---|---|---|
| P1 | MDIO/MIIM 的 CPU 寄存器从未实现（`reg_int.v` 中 8 个输出悬空） | MDIO 功能实际不可用 |
| P1 | `trunk` 的 ncsim 编译清单缺 `afifo.v` | 该流程无法 elaborate |
| P1 | `MAC_tx_FF` 误用 `MAC_RX_FF_DEPTH` 宏 | FIFO 深度可配置特性失效 |
| P2 | RMON 计数器跨时钟域无同步（`Clk_reg` 采 MAC 时钟域单周期脉冲） | 统计可能漏计 |
| P2 | 通用/`altera` 版 `CLK_SWITCH` 是纯组合 MUX | 运行中切速可能产生短脉冲 |
| P2 | `Phy_int.v` 第 139 行判据疑似笔误 | MII 发送数据为 `0x00` 时半字节错位 |

---

## 2. 目录结构与版本关系

```
ethernet_tri_mode_latest/
└── ethernet_tri_mode/
    ├── branches/                 (空)
    ├── tags/
    │   ├── arelease/             仅 1 个 PDF（RGMII 数据手册），2005-11-28
    │   ├── release-1-0/          官方 1.0 完整快照，2006-01-19 ~ 2006-01-25
    │   └── rel-1-0/              修订快照，2006-04-06 ~ 2006-06-25
    ├── trunk/                    主开发线（最新），RTL 2009-01-08 / 归档 2009-03-10
    │   ├── doc/                  规格书 + 验证计划 PDF
    │   ├── rtl/verilog/          37 个 RTL 源文件
    │   ├── bench/verilog/        6 个仿真模型（含 altera_mf.v）
    │   ├── sim/rtl_sim/ncsim_sim/   Cadence NC-Sim 流程（Windows/Cygwin + bash）
    │   ├── sim/rtl_sim/modsim_sim/  ModelSim 流程（仅 trunk 有）
    │   ├── syn/                  Synplify 工程（含 Altera / Xilinx 两版）
    │   ├── EDK/                  Xilinx EDK pcore + Linux 驱动（仅 trunk 有）
    │   └── start.tcl             Tcl/Tk 配置 GUI（可选模块 + FIFO 深度 + 验证入口）
    └── web_uploads/
        └── ethernet_tri_mode.rel-1-0.tar.gz   官方发布包（690 KB）
```

### 2.1 三个代码版本的实际差异

以文件 MD5 比对，三个版本的**核心算法模块完全相同**（`MAC_rx_ctrl`、`MAC_tx_Ctrl`、`CRC_gen`、`CRC_chk`、`flow_ctrl`、`Broadcast_filter`、`Phy_int`、`Clk_ctrl`、`RMON*`、`miim/*`、通用 `TECH/*` 全部一致），差异集中在顶层与 FIFO：

| 文件 | trunk vs rel-1-0 | trunk vs release-1-0 | 说明 |
|---|---|---|---|
| `afifo.v` | trunk 有 | trunk 有 | trunk 在 `rtl/verilog/`，release-1-0 在 `TECH/`，rel-1-0 **缺失** |
| `MAC_top.v` | 63 行 | 63 行 | trunk 增加「接收包长 FIFO」(afifo) 与相关端口 |
| `MAC_rx_FF.v` | 54 行 | 133 行 | trunk 修掉写指针误用 `MAC_TX_FF_DEPTH` 的 bug，新增 `Addr_freshed_ptr` 读指针逻辑（2009-01-08） |
| `reg_int.v` | 5 行 | 94 行 | 寄存器表逐步扩充到 0x00–0x22 |
| `eth_miim.v` | 17 行 | 17 行 | **trunk 用 `Mdo/MdoEn/Mdi` 三线制**；`tags/*` 用 `inout Mdio` 双向制（两条线分叉） |
| `MAC_rx.v` / `MAC_tx.v` | 7 / 5 行 | 7 / 5 行 | trunk 把 `pause_quanta` 改为真实互联（流控从 RX 传到 TX） |
| `TECH/{altera,xilinx}/` | trunk 独有 | trunk 独有 | 真正可综合的厂商原语版本 |
| `syn/syn_xilinx.prj`、`EDK/` | trunk 独有 | trunk 独有 | Xilinx 集成支持（2008 年补充） |

> 注意：`tags/rel-1-0` 与 `trunk` 是**两条分叉**，不是简单的先后关系——rel-1-0 把 MDIO 改成双向 `Mdio`，trunk 又改回三线制并加了包长 FIFO。合并时不要假设 tag 一定是 trunk 的子集。

### 2.2 两个压缩包

- `web_uploads/ethernet_tri_mode.rel-1-0.tar.gz` — 官方 1.0 发布包，内容即 `tags/release-1-0` 的源码树（`start.tcl` + `rtl/` + `bench/` + `doc/`），无 `sim/`、`syn/`。
- `trunk/EDK/edk_user_repository.tar.gz` — Xilinx EDK（MicroBlaze/PowerPC）集成包：`pcores/opencore_tri_mac_v1_00_a`（MPD/PAO/BBD + BFM 仿真工程）与 `drivers/opencore_tri_mac_v1_00_a`（`opencore_tri_mac.c/.h`、selftest、Makefile）。

---

## 3. 顶层结构与模块层次

### 3.1 `MAC_top` 端口分组

| 分组 | 信号 | 说明 |
|---|---|---|
| 系统 | `Reset`, `Clk_125M`, `Clk_user`, `Clk_reg`, `Speed[2:0]` | `Reset` 高有效异步复位；`Speed` 由寄存器 0x22 输出 |
| 用户接收 | `Rx_mac_ra/rd`, `Rx_mac_data[31:0]`, `Rx_mac_BE[1:0]`, `Rx_mac_pa/sop/eop` | 32 位 FIFO 读接口 |
| 用户发送 | `Tx_mac_wa/wr`, `Tx_mac_data[31:0]`, `Tx_mac_BE[1:0]`, `Tx_mac_sop/eop` | 32 位 FIFO 写接口 |
| 包长 FIFO | `Pkg_lgth_fifo_rd/ra/data[15:0]` | **trunk 新增**，把每个接收包的字节数交给用户侧 |
| PHY | `Gtx_clk`, `Rx_clk`, `Tx_clk`, `Tx_er/en/Txd[7:0]`, `Rx_er/dv/Rxd[7:0]`, `Crs`, `Col` | GMII/MII 共用一组引脚 |
| 主机 | `CSB`, `WRB`, `CA[7:0]`, `CD_in/out[15:0]` | 类 SRAM 异步 CPU 接口，**非 Wishbone** |
| MDIO | `Mdo`, `MdoEn`, `Mdi`, `Mdc` | 三线制（trunk） |

### 3.2 层次树（trunk）

```
MAC_top
├── MAC_rx                     接收通路（MAC 时钟域）
│   ├── MAC_rx_ctrl            前导/SFD/帧状态机、长度检查、IFG、PAUSE 解析
│   ├── CRC_chk                CRC-32 校验（残差 0xc704dd7b）
│   ├── MAC_rx_add_chk         目的 MAC 过滤（8×8bit duram 双端口）
│   ├── Broadcast_filter       广播令牌桶限流
│   └── MAC_rx_FF              异步 FIFO：8bit→32bit，字节装配 + BE/EOP 标志
├── MAC_tx                     发送通路（MAC 时钟域）
│   ├── MAC_tx_Ctrl            TX 状态机（前导/SFD/数据/PAD/FCS/IFG/JAM/BackOff/PAUSE）
│   ├── CRC_gen                CRC-32 生成
│   ├── flow_ctrl              PAUSE 帧生成/量化值倒计时
│   ├── MAC_tx_addr_add        源 MAC 替换（8×8bit duram）
│   ├── Ramdon_gen             半双工随机退避计时
│   └── MAC_tx_FF              异步 FIFO：32bit→8bit，水位线握手
├── RMON                       统计（Clk_reg 域）
│   ├── RMON_addr_gen  ×2      RX/TX 计数器地址生成
│   ├── RMON_ctrl              读写时序仲裁（含 CPU 读握手）
│   └── RMON_dpram  ×2         64×32 双端口 RAM
├── Phy_int                    GMII/MII 转换：100/10M 下的 4bit↔8bit 半字节装配、线环回
├── Clk_ctrl                   Speed 驱动的时钟分频/选择
│   ├── CLK_DIV2 ×2
│   └── CLK_SWITCH ×3
├── eth_miim                   IEEE 802.3 Clause-22 MDIO 主控
│   ├── eth_clockgen / eth_shiftreg / eth_outputcontrol / timescale
├── Reg_int                    35 个 16bit 寄存器（0x00–0x22）
└── afifo (U_rx_pkg_lgth_fifo) 包长跨时钟 FIFO（trunk 新增）
```

### 3.3 数据通路

```
           ┌──────────── RMON (Clk_reg) ────────────┐
           │  Rx/Tx 类型·长度·错误 → 64×32 RAM       │
           ▲                                        ▲
 PHY ──► Phy_int ──► MAC_rx_ctrl ──► MAC_rx_FF ──► 用户 32bit
 (GMII/MII)  4→8bit   前导/SFD/过滤   异步FIFO      (ra/rd/sop/eop/BE)
    ▲                     │
    │                     └──► afifo ──► Pkg_lgth_fifo（包长，trunk）
    │
    └── Phy_int ◄── MAC_tx_Ctrl ◄── MAC_tx_FF ◄── 用户 32bit
         8→4bit   PAD/FCS/IFG/CSMA   异步FIFO
                       ▲
                  Reg_int ◄── CPU (CSB/WRB/CA/CD)
```

---

## 4. 时钟与复位

### 4.1 时钟

| 时钟 | 来源 | 频率 | 用途 |
|---|---|---|---|
| `Clk_125M` | 板级 | 125 MHz | GMII `Gtx_clk`；1000M 下 MAC 发送时钟 |
| `Rx_clk` | PHY | 125 / 25 / 2.5 MHz | GMII/MII 接收时钟 |
| `Tx_clk` | PHY | 25 / 2.5 MHz | MII 发送时钟（GMII 不用） |
| `Clk_user` | 用户 | ≤66 MHz | 32 位用户侧 FIFO 接口 |
| `Clk_reg` | 用户 | 50–80 MHz | CPU 寄存器接口 + RMON |

`Clk_ctrl` 用 `Speed[2]` 一位选择（`Clk_ctrl.v:88-123`）：

```
Speed=100 (3'b100) → MAC_rx_clk_div = Rx_clk(125M), MAC_tx_clk_div = Clk_125M, MAC_tx_clk = Clk_125M
Speed=010/001      → MAC_rx_clk_div = Rx_clk/2,  MAC_tx_clk_div = Tx_clk/2,  MAC_tx_clk = Tx_clk
```

即 MAC 内核恒以 8bit × 时钟 工作：125M×8 = 1 Gbps，12.5M×8 = 100 Mbps，1.25M×8 = 10 Mbps。`Gtx_clk` 始终直通 `Clk_125M`（不随速率门控）。

### 4.2 复位与时钟切换的风险

- `Reset` 直接作为所有触发器的**异步复位**（`always @(posedge Clk or posedge Reset)`），**没有复位同步器**，也没有复位释放去抖。异步释放会在不同触发器上落在不同时钟沿，属经典亚稳态风险。
- `CLK_SWITCH` 的通用版与 `altera/` 版都是纯组合 MUX（`assign OUT = SW ? IN_1 : IN_0`），只有 `xilinx/` 版用了 `BUFGMUX`。运行中改 `Speed` 会切换时钟源，在 Altera/通用实现上可能产生窄脉冲。
- 真正的多时钟域有 4~5 个（`MAC_rx_clk`、`MAC_tx_clk`、`Clk_user`、`Clk_reg`、`Clk_125M`），跨域靠两个异步 FIFO 加格雷码指针（`MAC_rx_FF` / `MAC_tx_FF`），但 **RMON 通路与 `Reset` 没有做同步**。

---

## 5. 寄存器映射（`reg_int.v:65-99`）

约定：CPU 字节地址 `CA[7:0]`，**只用 `CA[7:1]` 译码**，因此寄存器位于偶地址 `0x00,0x02,…`，数据宽度 16 位（`reg_int.v:101-142`）。下表"索引"即 `CA[7:1]` 的值，**实际字节地址 = 索引 × 2**（寄存器 0x22 → 字节地址 0x44）。

| 索引 `CA[7:1]` | 名称 | 属性 | 复位值 | 与规格书差异 |
|---|---|---|---|---|
| 0x00 | `Tx_Hwmark[4:0]` | R/W | 0x0009 | 规格书写 0x001e ⚠ |
| 0x01 | `Tx_Lwmark[4:0]` | R/W | 0x0008 | 规格书写 0x0019 ⚠ |
| 0x02 | `pause_frame_send_en` | R/W | 0x0000 | |
| 0x03 | `pause_quanta_set[15:0]` | R/W | 0x0000 | |
| 0x04 | `IFGset[5:0]` | R/W | 0x000c | 规格书写 0x0012 ⚠ |
| 0x05 | `FullDuplex` | R/W | 0x0001 | |
| 0x06 | `MaxRetry[3:0]` | R/W | 0x0002 | |
| 0x07 | `MAC_tx_add_en` | R/W | 0x0000 | |
| 0x08–0x0a | `MAC_tx_add_prom_data/add/wr` | R/W | 0 | 源 MAC 表写口 |
| 0x0b–0x0d | `tx_pause_en` / `xoff_cpu` / `xon_cpu` | R/W | 0 | |
| 0x0e–0x11 | `MAC_rx_add_chk_en` / `MAC_rx_add_prom_*` | R/W | 0 | 目的 MAC 表写口 |
| 0x12 | `broadcast_filter_en` | R/W | 0x0000 | |
| 0x13 | `broadcast_bucket_depth[15:0]` | R/W | 0 | |
| 0x14 | `broadcast_bucket_interval[15:0]` | R/W | 0 | |
| 0x15 | `RX_APPEND_CRC` | R/W | 0 | |
| 0x16 | `Rx_Hwmark[4:0]` | R/W | 0x001a | |
| 0x17 | `Rx_Lwmark[4:0]` | R/W | 0x0010 | |
| 0x18 | `CRC_chk_en` | R/W | 0 | 写 1 关闭校验（与常规"使能"语义相反，见规格书 §CRC_chk_en） |
| 0x19 | `RX_IFG_SET[5:0]` | R/W | 0x000c | 规格书写 0x0012 ⚠ |
| 0x1a | `RX_MAX_LENGTH[15:0]` | R/W | 0x2710 (10000) | 支持巨型帧 |
| 0x1b | `RX_MIN_LENGTH[6:0]` | R/W | 0x0040 (64) | |
| 0x1c | `CPU_rd_addr[5:0]` | R/W | 0 | RMON 读地址 |
| 0x1d | `CPU_rd_apply` | R/W | 0 | 读申请（脉冲） |
| 0x1e | `CPU_rd_grant` | RO | – | RMON 已就绪 |
| 0x1f/0x20 | `CPU_rd_dout[15:0]` / `[31:16]` | RO | – | 计数器低/高半字 |
| 0x21 | `Line_loop_en` | R/W | 0 | 线侧环回（自测用） |
| 0x22 | `Speed[2:0]` | R/W | 0x0004 (1000M) | 1000/100/10 = 100/010/001 |

**缺失**：MIIM（MDIO）本应有 `Divider`、`CtrlData`、`Rgad`、`Fiad`、`NoPre`、`WCtrlData`、`RStat`、`ScanStat` 等寄存器，`Reg_int` 把这些**声明为输出却从未赋值**（`reg_int.v:48-55`，全文只有端口声明，无任何 `RegCPUData` 实例或 `assign`），因此 `eth_miim` 的控制输入是悬空的 `z`，MDIO 事务无法从 CPU 发起。规格书的寄存器表也确实没有这几项——说明该功能**从未完成**。

---

## 6. 接收通路（RX）

### 6.1 状态机（`MAC_rx_ctrl.v:131-142`）

| 状态 | 值 | 作用 |
|---|---|---|
| `State_idle` | 0 | 等 `Crs_dv && RxD==8'h55`（前导） |
| `State_preamble` | 1 | 跳过 `0x55`，遇 `0xd5`(SFD) 进入数据；`RxErr`→drop |
| `State_SFD` | 2 | SFD 处理 |
| `State_data` | 3 | 逐字节写 FIFO，同时送 CRC 与地址检查 |
| `State_checkCRC` | 4 | 等待 CRC 结果 |
| `State_OkEnd` | 7 | 正常结束 |
| `State_drop` | 8 | 丢弃（地址/广播/长度不合法） |
| `State_ErrEnd` | 9 | PHY 错误结束 |
| `State_CRCErrEnd` | 10 | CRC 错 |
| `State_FFFullDrop` | 11 | FIFO 满丢弃 |
| `State_FFFullErrEnd` | 12 | FIFO 满错误结束 |
| `State_IFG` | 13 | 帧间隔检查，< `RX_IFG_SET` 则丢下一包 |

PAUSE 解析另有 5 状态小状态机：`Pause_idle / pre_syn / quanta_hi / quanta_lo / syn`（`MAC_rx_ctrl.v:144-148`），解析 0x0101 类型帧的 quanta 字段并交给 TX 侧。

### 6.2 功能点

- **CRC**：`CRC_chk.v:124` 用残差 `0xc704dd7b` 判错（标准 Ethernet CRC-32 全帧校验残差），初值 `0xFFFFFFFF`；`CRC_chk_en=0` 可关闭。
- **目的 MAC 过滤**（`MAC_rx_add_chk.v:144`）：8 深 × 8 位 `duram`，可存 6 字节合法目的地址 + 2 字节余量；`MAC_rx_add_chk_en` 使能。
- **广播限流**（`Broadcast_filter.v`）：令牌桶，`time_counter` 到 `broadcast_bucket_interval` 重置并回填 `broadcast_counter`，每字节扣 1，桶空则丢包——与规格书描述的「depth/interval 比值决定平均带宽」一致。
- **长度限制**：`< RX_MIN_LENGTH` 或 `> RX_MAX_LENGTH` 丢包；已在传输中的包用 EOP 错误标志通知用户。
- **FIFO 装配**（`MAC_rx_FF.v:391-399`）：36 位字 = `{EOP 标志, 有效字节数[2:0], data[31:0]}`，`4'b1000..1011` 编码 4/1/2/3 个有效字节，尾部不足 4 字节时用这些 tag 表达 BE。
- **水位线**：`Fifo_data_count` 到 `Rx_Hwmark` 即拉高 `Rx_mac_ra`，降到 `Rx_Lwmark` 撤销；整包收完也会拉高。

---

## 7. 发送通路（TX）

### 7.1 状态机（`MAC_tx_Ctrl.v:162-176`）

`StateIdle → Preamble → SFD → Data → (PAD) → FCS → IFG → SwitchNext`，另有 `Pause`、`Jam`、`BackOff`、`JamDrop`、`FFEmptyDrop`、`Defer`、`SendPauseFrame` 共 15 个状态。

### 7.2 功能点

- **前导/SFD**：`Preamble_counter` 生成 7×`0x55` + `0xD5`。
- **源 MAC 替换**（`MAC_tx_addr_add.v:114`，`MAC_SOURCE_REPLACE_EN` 可控）：8 深 × 8 位 `duram`，`MAC_tx_add_prom_wr` 上升沿把 `prom_data` 写入 `prom_add`，需写 6 次；`MAC_header_slot`/`Src_MAC_ptr` 在帧头对应槽位插入。
- **PAD**：`IPLengthCounter`/`PADCounter` 保证帧 ≥ 60 字节（不含 FCS）。
- **FCS**（`CRC_gen.v`）：先算数据 CRC，再补 `{CRC_reg[23:0],8'hff}` 取反输出 4 字节。
- **IFG**：`IFGset` 个时钟（默认 12 = 96 bit @125M/8bit）。
- **半双工 CSMA/CD**（10/100M，`FullDuplex=0`）：`Collision` 检测 → `Jam`（`JamCounter` 发 32 bit jam）→ `BackOff`（`Ramdon_gen` 随机退避）→ 重发；超过 `MaxRetry` 进入 `JamDrop` 丢帧并计数。
- **PAUSE 帧发送**（`flow_ctrl.v`）：CPU 置 `xoff_cpu` 发 quanta=0 的 XOFF，置 `xon_cpu` 发 `pause_quanta_set` 的 XON；受 `pause_frame_send_en` 与 `tx_pause_en` 控制；接收侧解析出的 `pause_quanta` 会在 TX 状态机里倒计时，实现"被暂停"。
- **水位线**：`Tx_mac_wa` 在 FIFO 达 `Tx_Hwmark` 时拉低（让用户停写），低于 `Tx_Lwmark` 恢复。

---

## 8. RMON 统计

- 存储：2 块 `duram #(32,6)` = **64 项 × 32 位**双端口 RAM（`RMON_dpram.v`，`assign #2 Clkb=Clk` 制造读延迟，综合时被忽略）。
- 地址表（规格书 §Statistic counters）：

| RX | 计数器 | TX | 计数器 |
|---|---|---|---|
| 0x00 | 总字节数 | 0x20 | 总字节数 |
| 0x01 | 总包数 | 0x21 | 总包数 |
| 0x02 | 广播 | 0x22 | 广播 |
| 0x03 | 组播 | 0x23 | 组播 |
| 0x04 | 单播 | 0x24 | 单播 |
| 0x05 | CRC 错 | 0x25 | Jam 丢包 |
| 0x06 | FIFO 满 | 0x26 | FIFO 下溢 |
| 0x07 | 过长/过短 | 0x27 | FIFO 上溢 |
| 0x08–0x0f | 各长度区间（<64, 64, 64-127, 128-255, 256-511, 512-1023, 1024-1517, >1518） | 0x28–0x2f | 同上 |
| 0x10 | PAUSE 帧 | 0x30 | PAUSE 帧 |

- CPU 读时序：写 `CPU_rd_addr` → 置 `CPU_rd_apply` → 等 `CPU_rd_grant=1` → 读 `CPU_rd_dout_l/h`（规格书第 17 页流程图）。
- 代码里 `RMON_addr_gen.v` 的地址序列与上表一致（0x02 广播、0x03 组播、0x10 PAUSE、0x04 单播…），RMON 的 `Rx_pkt_err_type_rmon==3'b100` 还被 `MAC_top.v:282` 用来触发包长 FIFO 写入。

---

## 9. 技术相关原语（`rtl/verilog/TECH/`）

| 原语 | 通用版 | `altera/` | `xilinx/` |
|---|---|---|---|
| `duram` | `altsyncram` 推断（`duram.v`） | 与通用版**完全相同** | `RAMB16_S36_S36`（1523 B） |
| `CLK_DIV2` | 触发器二分频 | 加 `syn_keep` 等属性 | 加属性 |
| `CLK_SWITCH` | **纯组合 MUX** | **纯组合 MUX**（未用 `altclkctrl`） | `BUFGMUX`（唯一真正无毛刺的实现） |
| `afifo` | trunk 的 `rtl/verilog/afifo.v`（格雷码异步 FIFO，参数化 `DATA_WIDTH`/`COUNT_DATA_WIDTH`） | — | — |

> 结论：**只有 Xilinx 版本的时钟切换是安全的**。Altera 用户若需要运行中切速，应自行替换为 `altclkctrl`/PLL 重配置；否则建议只在复位期间设定 `Speed`。

---

## 10. 文档（`doc/`）

| 文件 | 版本 | 内容 |
|---|---|---|
| `Tri-mode_Ethernet_MAC_Specifications.pdf` | Rev 0.1，2006-01-25，24 页 | 简介、框图、时钟分配、可选模块、验证流程、**寄存器描述（0x00–0x22 及全部功能位）**、RMON 地址表、时钟表、GMII/MII 引脚映射（以 88E1111 为例）、用户/主机接口时序图 |
| `Tri-mode_Ethernet_MAC_Verification_plan.pdf` | Rev 0.1，2006-01-19，9 页 | 7 个测试用例：1000M/100M/10M 全双工 46–1500 吞吐、流控、源 MAC 替换、目的 MAC 检查、广播过滤；含 CPU 写寄存器序列（`CPU.dec`）与预期打印 |
| `tags/arelease/doc/RGMII_DataSheet.pdf` | 2005-11-28 | RGMII 时序手册，**纯图片 PDF，无文字层**（提取 0 字节） |

规格书明确：目标是用 **< 2000 LC/LE** 实现完整功能，依赖推断 RAM 与 PAD 降低工艺耦合；**三个可选模块**（源 MAC 替换、目的 MAC 检查、广播过滤）可通过 `header.v` 的 `` `define `` 裁掉。

---

## 11. 验证与综合流程

### 11.1 仿真环境

```
sim/rtl_sim/{ncsim_sim,modsim_sim}/
├── bin/   com.nc|com.mod(编译)  sim.nc|sim.mod(仿真)  vlog*.list(文件清单)
│          config.ini  hdl.var  cds.lib  ip_32W_{gen,check}*.dll
├── data/  *.vec(波形激励)  *.ini(包长配置)  batch.dat(回归用例表)  CPU.vec
├── script/ run.tcl filesel.tcl set_stimulus.tcl set_reg_data.tcl
│           start_verify.tcl batch_mode.tcl run_proc.tcl user_lib.tcl
└── log/   ncsim.log
```

- **testbench 组成**：`tb_top`（时钟/复位、`$shm_open` 波形）、`Phy_sim`（行为级 PHY，GMII/MII 双侧）、`User_int_sim`（32 位用户侧收发）、`host_sim`（`CPU_wr`/`CPU_rd` task 驱动 `CA/WRB/CSB`）、`reg_int_sim`、`altera_mf.v`（Altera 原语仿真模型，1.3 MB）。
- **激励/检查靠外部 PLI**：`$ip_32W_gen`（按 `config.ini` 生成 IP 包）与 `$ip_32W_check`（CRC-32 自检），实现为 **Windows 32 位 DLL**（`ip_32W_gen.dll` / `ip_32W_check.dll`），ncsim 通过 `-pli` 加载。这是本环境**最难移植**的部分。
- **`config.ini` 格式**：`起始包长,结束包长,包数,是否广播,保留`，例如 `46,1500,1,0,0`、`46,50,1,0,0`。
- **`batch.dat`**：`{用例描述} ini文件 vec文件`，trl 逐行跑回归（trunk 里配了 1000M/100M/10M 三个 46–50 用例）。
- **Tcl/Tk GUI**（`start.tcl`）：读取 `header.v` 前 5 行 → 勾选三个可选模块、设置 `MAC_TX_FF_DEPTH`/`MAC_RX_FF_DEPTH` → `Save` 直接回写 `header.v`（注释/取消注释 + 改深度数字），`Verify` 进入仿真 GUI。

### 11.2 仿真结果证据

- `tags/rel-1-0/sim/rtl_sim/ncsim_sim/log/ncsim.log`（69 KB）：46 → 1500 字节连续递增，逐帧 `CRC-32check OK!`，最后 `the NO. ffff IP Length is:1500 CRC-32check OK!`，随后 `Simulation was Terminated because of received packet with SN=0xffff` 并生成 `sim_succeed` 文件。**这是一次完整通过的 1000M 全双工吞吐测试**。
- `trunk/sim/rtl_sim/ncsim_sim/log/ncsim.log`：`ncsim 05.00-p001`，跑到 `NO. 00e6 IP Length is:0275` 时 `Simulation interrupted at 367372 NS`，**日志停留在被中断状态**（不是通过记录）。
- `trunk/sim/rtl_sim/modsim_sim/log/ncsim.log` 与上面同尺寸同内容，应是复制过来的，并非 ModelSim 真实输出。

### 11.3 综合

- `syn/syn.prj`：Synplify 8.1，目标 **Altera Stratix EP1S10 / FC780 / -5**，`onehot` 状态编码、`vlog_std v2001`、输出 `MAC_top.vqm`。
- `syn/syn_altrea.prj`、`syn/syn_xilinx.prj`：分别指向 `TECH/altera`、`TECH/xilinx`（注意工程文件名把 altera 拼成了 `altrea`）。
- 无时序约束文件（.sdc/.xcf），无综合报告、无资源占用数据留档。

### 11.4 工具链现状

本机没有 `iverilog`/`verilator`/`vcs`/`vsim`/`ncsim`/`synplify`/`vivado`/`quartus`，**无法在此环境做语法检查或重跑仿真**。原始流程依赖：Windows 2000 + Cygwin（`bash` 脚本 `.nc`/`.mod`）+ Cadence LDV 5.0（`ncsim 05.00-p001`）+ Tcl/Tk 8.x + 32 位 PLI DLL + Synplify 8.1，全部是 2006 年前后的工具版本。

---

## 12. 问题清单（按严重度）

### P1 — 功能性缺陷，必须修

1. **MDIO/MIIM 未接入寄存器**
   `reg_int.v:48-62` 把 `Divider/CtrlData/Rgad/Fiad/NoPre/WCtrlData/RStat/ScanStat` 声明为 output，但**全文没有任何赋值**（无 `RegCPUData` 实例、无 `assign`），`eth_miim` 的输入因此悬空。即使 `eth_miim.v` 本身是完整可用的 Clause-22 主控（时钟分频、前导抑制、read/write/scan status 齐备），**整个 MDIO 功能也无法使用**。规格书的寄存器表同样没有这几项 → 属未完成功能，不是遗漏文档。

2. **`trunk` 的 ncsim 编译清单缺 `afifo.v`**
   `trunk/sim/rtl_sim/ncsim_sim/bin/vlog.list` 里没有 `afifo.v`，但 `trunk` 的 `MAC_top.v:301` 例化了 `afifo U_rx_pkg_lgth_fifo`。该流程会报未定义模块。`modsim_sim/bin/vlog-rtl.list` 里是有的。同一文件还把 `reg_int.v` 写成 `Reg_int.v`（Windows 下不敏感，Linux 下会找不到文件）。

3. **`MAC_tx_FF` FIFO 深度宏用错**
   `MAC_tx_FF.v:144-162` 的读写指针全部用 `` `MAC_RX_FF_DEPTH ``，而第 781 行 RAM 例化用的是 `` `MAC_TX_FF_DEPTH ``。默认两者都是 9，所以不暴露；一旦按 `start.tcl` 分别设置 TX/RX 深度，地址位宽与存储器深度不一致 → 功能错乱。`trunk` 已在 `MAC_rx_FF` 修掉同类 bug（2009-01-08），**TX 侧漏修**。

### P2 — 设计风险

4. **RMON 跨时钟域采样**
   `RMON` 用 `Clk_reg` 采样（`MAC_top.v:318-336`），而 `Tx_apply_rmon`、`Rx_apply_rmon` 是 MAC 时钟域的单周期脉冲，`Rx/Tx_pkt_length_rmon[15:0]` 是多位总线。无两级同步、无握手 → **统计会漏计，且多位总线采样可能撕裂**。若统计精度重要，需加同步器或把计数放到 MAC 时钟域。

5. **时钟切换不是无毛刺设计**
   通用版与 `altera/` 版 `CLK_SWITCH` 都是 `assign OUT = SW?IN_1:IN_0`（见 §9）。`Speed` 是 CPU 可写的普通寄存器，运行中改速会在 `Clk_ctrl` 输出产生窄脉冲，可能打乱状态机。建议只在复位期设定 `Speed`，或换成 `BUFGMUX`/`altclkctrl`/PLL 切换。

6. **`Phy_int.v:139` 判据疑似笔误**
   ```verilog
   always @ (posedge MAC_tx_clk or posedge Reset)
       if (Reset)            Tx_odd_data_ptr <= 0;
       else if (!MTxD_dl1)   Tx_odd_data_ptr <= 0;   // ← 用的是"数据"，应为"使能"
       else                  Tx_odd_data_ptr <= !Tx_odd_data_ptr;
   ```
   半字节指针应当由发送使能（`MTxEn_dl1`）复位，而不是由数据值复位。对照接收侧同一写法用的是 `!Rx_dv_dl1`（正确）。后果：**MII 模式下只要某字节数据为 `0x00`，半字节对齐就会错位**（该字节的高 4 位会与下一个字节的低 4 位拼错）。三个版本该文件完全一致，说明一直未修。

7. **`MRxD` 赋值缺 `else`**（`Phy_int.v:214-222`）：MII 接收的最后分支没有缺省赋值，会保持上一拍值。功能上勉强可用（下一拍就会被覆盖），但属易误读的 latch 风格。

8. **`Tx_er` 恒为 0**（`Phy_int.v:165`）：发送错误无法上报；`Rx_er` 只延迟后透传给 `MRxErr`，未用于统计细分。

9. **未使用的规格书参数冲突**：`RX_MAX_LENGTH` 默认 10000 支持巨型帧，但默认 FIFO 只有 512 字 × 4 B = 2 KB。**一个 9.6 KB 的 jumbo 帧根本放不下**，会被 FIFO 满逻辑丢弃。规格书宣称"支持 Jumbo 9.6K"，实际需要把 `MAC_RX_FF_DEPTH` 提到 ≥ 12（4096 字）才成立。

10. **无复位同步器**，且 `Reset` 高有效异步复位贯穿所有模块；跨域 FIFO 的 `ainit`/`Reset` 释放不同步，上电时序需在板级保证。

### P3 — 一致性 / 可维护性

11. **文档与 RTL 复位值不一致（4 处）**：`Tx_Hwmark` 0x1e vs 0x09、`Tx_Lwmark` 0x19 vs 0x08、`IFGset` 0x12 vs 0x0c、`RX_IFG_SET` 0x12 vs 0x0c。RTL 的 0x0c=12 拍（96 bit @125M/8bit）在算术上更自洽，文档应为旧版。另外 `Tx_Hwmark=9`/`Tx_Lwmark=8` 只有 **1 个字**的回差，在 512 字 FIFO 上几乎没有缓冲余量，实际系统必须按带宽时延积重算。
12. **命名笔误**：`Ramdon_gen.v`（Random）、`syn_altrea.prj`（altera）、`Reg_int` 与文件名 `reg_int.v` 大小写不一致、`MAC_rx_FF` 历史版本用 `MAC_TX_FF_DEPTH`。
13. **`afifo.v` 位置在三个版本间不一致**（`rtl/verilog/` vs `TECH/` vs 缺失），且两份内容不同（6425 B vs 9465 B），跨版本对比/合并容易拿错。
14. **`RMON_dpram.v` 用 `assign #2 Clkb=Clk;`** 制造 2 ns 读延迟，综合器忽略该延迟，仿真与综合时序不完全一致。
15. **`Mac_top` 里包长 FIFO 的 `din` 用组合减法**（`RX_APPEND_CRC? len : len-4`，`MAC_top.v:302`），位宽 16 位，极端长度下有回绕风险（`len<4` 时），实际不会出现但属脆弱写法。
16. **无回归脚本/无断言**：验证靠 GUI + 打印字符串比对，没有 scoreboard、覆盖率、随机约束；`batch.dat` 只列了 3 个短包用例。
17. **无约束文件、无综合/时序报告留档**，资源与时序结论无法复核。

---

## 13. 复用建议（若要用于本项目）

1. **基线选 `trunk`**（功能最全、bug 修得最多），但先做三件事：
   - 补 `afifo.v` 到 `ncsim` 清单，修正 `Reg_int.v` 大小写；
   - 把 `MAC_tx_FF` 的 5 处 `` `MAC_RX_FF_DEPTH `` 改成 `` `MAC_TX_FF_DEPTH ``；
   - 若只用 10/100M，可裁掉 `Speed[2]` 相关 MUX 以省资源。
2. **必须补齐的接口**：MDIO 寄存器组（0x23 起，按 `eth_miim` 端口定义实现 8 个寄存器）、复位同步器、RMON 脉冲两级同步。
3. **对接 SoC**：把 8 位 `CA`/16 位 `CD` 的 SRAM 接口换成 Wishbone/AXI-Lite 桥（只读寄存器 0x1e–0x20 需保留读握手语义）；用户侧 32 位 `sop/eop/BE` 接口可直接包成 AXI4-Stream（`BE` 映射到 `TKEEP`）。
4. **FIFO 深度**：按最大帧长选深度——1518 B 帧至少需 380 字，9.6 KB jumbo 需 ≥ 2400 字（`MAC_RX_FF_DEPTH` ≥ 12）；Xilinx 版 RAMB16_S36 每块 512×36，深度 9 就是 1 块。
5. **时钟**：`Clk_user` 与 MAC 时钟异步是设计前提，不要"省事"接同一时钟；`Clk_reg` 建议 ≥ 50 MHz 以保证 MDIO 分频精度。
6. **时序**：应约束 `Rx_clk`/`Tx_clk` 与 `Clk_125M` 的 GMII 输入输出（`set_input_delay`/`set_output_delay` 约 1–2 ns），并对 `Rx_dv`/`Rxd` 做 IO 寄存器（代码里 `Phy_int` 已有一级 `_dl1`，PHY 侧一般还需 IDDR）。
7. **验证**：原 PLI（`ip_32W_*.dll`）不可移植，建议用 Cocotb/SystemVerilog 重写激励与 CRC 检查，先跑通「环回 46–1500 全长度 + CRC OK」作为冒烟，再补流控/过滤/半双工退避用例。

---

## 14. 附：文件清单速查

| 类别 | 文件 | 行数/大小 |
|---|---|---|
| 顶层 | `MAC_top.v` | 484 行 |
| 子模块最大 | `MAC_tx_FF.v` / `MAC_rx_FF.v` | 790 / 734 行 |
| 状态机 | `MAC_tx_Ctrl.v` / `MAC_rx_ctrl.v` | 643 / 533 行 |
| 寄存器 | `reg_int.v` | 178 行 |
| MDIO | `eth_miim.v` + `miim/*.v` | 479 + 466 行 |
| RMON | `RMON.v` + `RMON/*.v` | 180 + 593 行 |
| 原语 | `TECH/*.v` | 9 个文件（generic/altera/xilinx） |
| 顶层配置 | `header.v` | 5 行（3 个 `define` 开关 + 2 个 FIFO 深度） |
| 测试平台 | `tb_top.v` / `User_int_sim.v` / `reg_int_sim.v` / `Phy_sim.v` / `host_sim.v` | 236 / 152 / 132 / 99 / 83 行 |
| 大文件 | `bench/verilog/altera_mf.v` | 1.34 MB / 34 538 行（Altera 原语仿真库） |

---

*本报告由静态分析生成：已逐文件阅读 RTL/脚本/文档，并提取两份规格 PDF 的文字层（`_analysis/*.txt`）。未做编译与仿真验证（本机无 HDL 工具链）。*
