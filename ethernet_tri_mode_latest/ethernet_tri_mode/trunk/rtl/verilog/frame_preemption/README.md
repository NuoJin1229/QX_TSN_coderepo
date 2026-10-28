# 帧抢占 RTL 原型

当前版本：2026-10-28。增强顶层是 `../MAC_top_fp.v`，保留原 `../MAC_top.v`。

本版本支持 **1G 全双工、静态配置、手工强制模式** 的帧抢占数据通路：

- 用户首字优先级锁存，mask 位 1 为 preemptable，0 为 express。
- 两个旧 TX MAC 生成 PAD/FCS，capture 去除前导并交给两类完整帧缓存。
- TX Merge 在合法边界切分 p，插入累计 mCRC，优先发送 e，随后继续 p。
- RX Merge 校验 SMD/FC、累计 CRC、长度与顺序，完整帧提交后重放给旧 RX MAC。
- HOLD 同步、各新增时钟域的复位释放同步、错误回滚和本地域统计。

**它尚不是完整的 IEEE 合规产品。** 自动 Verify/Respond、动态 CSR、多位配置热更新、物理实现与真实对端互通尚未完成。增强顶层禁用 PAUSE 控制与原 TX RMON 事件；仅选择原顶层才能保留原三速/半双工功能路径。默认每帧容量 2048B，单位 DA 到 FCS；新增数据缓存声明合计 12KiB，未证明能直接映射到目标工艺 RAM。

## 文件与接口

| 文件 | 用途 |
|---|---|
| fp_merge_tx.v | e/p 单槽缓存、仲裁、分片、续发、HOLD、IFG |
| fp_merge_rx.v | 每类双槽、p 重组、校验、完整帧 commit/rollback |
| fp_crc.vh | 反射 CRC32 与固定 SMD 编码函数 |
| fp_mac_capture.v | 从旧 TX MAC 输出中剥离前导、生成 LAST/abort |
| fp_rx_replay.v | 完整帧转回连续普通 GMII，保留至少 12B IFG |
| fp_reset_sync.v | 异步置位、两本地时钟周期释放的复位同步器 |
| fp_core.f | 核心 RTL 清单，**不包含技术适配实现** |
| fp_sim.f | 核心加一套仿真时钟/RAM 模型，只用于仿真 |

单元字节流包含 DA..FCS；顶层用户 32bit 流默认不带 FCS。用户侧接受条件是 `Tx_mac_wr && Tx_mac_wa`；priority 仅在帧首个接受字采样，直到 EOP 路由固定。配置必须在 Reset 期间准备好并在整个链路会话保持不变。

## 编译清单

相对路径以 `ethernet_tri_mode_latest/ethernet_tri_mode/trunk` 为工作目录：

```text
iverilog -g2012 -s MAC_top_fp -o <ASCII-output>/MAC_top_fp.vvp -f rtl/verilog/frame_preemption/fp_sim.f
```

旧 MinGW Icarus 不能处理中文工程绝对路径时，使用下面回归脚本自动暂存源文件。不要递归编译 TECH、TECH/altera、TECH/xilinx：它们定义同名模块。

`fp_core.f` 将原 `header.v` 放在使用 FIFO 深度宏的源文件之前。原 RTL 依赖该编译顺序；采用各文件独立编译单元的工具时，应将同样的宏作为全局编译定义或预包含配置，不能忽略它。

综合只参考 `fp_core.f`，另行选择**一套**适用于目标工艺的 `duram`、`CLK_SWITCH`、`CLK_DIV2` 和库。`fp_sim_duram.v` 与 root TECH 时钟模型都是仿真替代物，不构成可综合生产方案。默认综合工程和约束未替换。

## 回归

从项目根目录执行，Python 3.10+，Icarus Verilog 与配套 vvp：

```powershell
$fpTools = Join-Path $env:TEMP 'tsn_fp_tools_20261028'
$fpOutput = Join-Path $env:TEMP 'tsn_fp_regression_repeat'
python 'ethernet_tri_mode_latest/ethernet_tri_mode/trunk/bench/verilog/frame_preemption/run.py' --iverilog (Join-Path $fpTools 'bin/iverilog.exe') --output $fpOutput
```

脚本按 `fp_sim.f` 加载明确源集，复制到输出目录，不递归猜测技术实现；逐字节参考使用独立 Python zlib。成功产生 `report.json`、`commands.log`、`source_manifest.json`，并保留 vectors/trace。任一编译/运行/断言失败返回非零退出码。输出目录要选择 ASCII 路径。

本轮固化证据在 `../../../bench/verilog/frame_preemption/results/20261028/`，含详细范围和未覆盖项。不要把 elaboration、本地仿真、综合或板级互通混为一谈。

完整中文设计规格在项目根目录：

- `帧抢占_802.1Qbu_协议详解与实现规划.md`：协议纠错、依据和生产工作包。
- `帧抢占_代码修改与设计说明.md`：实际端口、状态机、时序、缓存、异常、验证矩阵。
