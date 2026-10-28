# 帧抢占本地验证记录 — 2026-10-28

本目录记录 **1G 全双工、静态配置、手工强制模式** 原型的一轮本地验证。它是功能仿真与编译证据，不是 IEEE 合规认证、公司全系统回归或物理签核报告。

## 1. 工具、源集与方法

- Python 3.12.14，Icarus Verilog / vvp 10.1 stable。
- 主回归完成时间：2026-10-28 08:07:50 UTC，即北京时间 16:07:50；精确时间见 source_manifest.json。
- 主回归输出目录：临时目录下 tsn_fp_regression_20261028i。完整命令和 stdout/stderr 保存在 commands.log。
- 核心清单 fp_core.f，仿真清单 fp_sim.f；source_manifest.json 绑定了 45 个实际源码、头文件、测试文件、脚本和清单的 SHA-256。
- 独立参考：Python zlib 计算 FCS/mCRC，逐字节解析 GMII trace。参考不调用 RTL CRC 函数；仍需最终标准和第三方对端消除共同理解偏差。
- RX 随机 ready 种子 0x8023；帧数据按 run.py 中各帧 identity 固定种子生成。
- 仿真 RAM：fp_sim_duram.v，同步一拍读，仅用于验证。不能作为目标工艺 RAM 实现或综合结果。
- 集成时钟：TX/RX 各 125MHz，RX 相差 2ns；user 100MHz，reg 约 71.4MHz。不同频率仿真不等于 CDC/RDC 签核。

## 2. 实际结果

| 层级 | 实际结果 | 主要检查 |
|---|---|---|
| TX Merge | 26 个完整帧，37 个线包，11 个非末片；错误计数 3 | e/p 内容、SMD、FC、累计 mCRC、原 FCS、帧/片序号回绕、12 次 express 超越 |
| TX 边界 | 10 帧，14 线包，4 个非末片；错误计数 3 | 123/124、187/188、251/252、315/316；非末片 DATA 60/124/188/252；HOLD 保持与释放 |
| TX 故障 | 对应 testbench 断言通过 | 2048 接受、2049 拒绝、双 abort 同拍计两次、半输入掉线和 DATA 中复位恢复 |
| RX Merge | 提交 73 帧 = 67e + 6p；37 个非末片；15 个错误事件、1 个 overrun | 独立构造的合法/损坏流，随机背压稳定性、顺序/CRC/RX_ER/溢出恢复、双槽保护 |
| RX 连续流 | 32 个最短 e 帧、12B IFG 通过 | 仅 Merge 层证据；不代表旧用户 FIFO 任意拥塞无损 |
| 顶层集成 | 5 帧 = 3e + 2p，6 线包、1 个非末片；312 个用户字、5 个长度条目 | 旧 TX PAD/FCS → Merge → GMII 回环 → Merge → 旧 RX CRC 检查 → 实际用户口 |
| 用户接口 | 长度按交付次序为 61/996/62/63/60B | 覆盖尾字 BE；每帧首字后改变 priority，仍按首字锁路由；线侧和用户侧均检查 express 超越 |
| 原/增强顶层编译 | MAC_top、MAC_top_fp elaboration 通过 | 包括使用原样嵌套 .f 清单的独立编译；不是原 MAC 全功能仿真 |

测得最小空闲间隔：主 TX 和顶层线侧各 12 个 GMII 字节周期；边界测试因激励刻意留空，测得 198 周期。198 是该测试的实测值，不是实现强制的 IFG。

```text
PASS TX e=12 p=14 fragments=11 input_errors=3
PASS EDGES frames=10 fragments=4 errors=3 boundaries=8 link_reset=2
PASS RX e=67 p=6 fragments=37 errors=15 overruns=1
LENGTH 61
LENGTH 996
LENGTH 62
LENGTH 63
LENGTH 60
PASS TOP frames=5 tx_fragments=1 rx_fragments=1 words=312 lengths=5
```

测试中的 errors / overruns 包含故意注入的异常，均有预期计数断言，不能解释为未解决的测试失败。

## 3. 直接清单编译及警告

回归脚本为兼容旧 MinGW 工具，将明确源集暂存为 ASCII 文件名。另在 native_tree 保留 trunk 相对目录，从相同哈希源码直接运行：

```text
iverilog -g2012 -s MAC_top    -o <ASCII-output>/native_MAC_top.vvp    -f rtl/verilog/frame_preemption/fp_sim.f
iverilog -g2012 -s MAC_top_fp -o <ASCII-output>/native_MAC_top_fp.vvp -f rtl/verilog/frame_preemption/fp_sim.f
```

两次退出码均为 0，详见 native_filelist_check.json / native_filelist_compile.txt。工作目录为 trunk 的 ASCII 副本；-f 内嵌清单按所在清单的目录定位，源文件和 +incdir+ 仍以 trunk 工作目录定位。原 header.v 必须先于使用 FIFO 宏的编译单元。

**不是零警告构建。** 日志保留了旧 reg/长度 FIFO 位宽转换、MDIO/RMON 隐式网络、timescale 缺失/继承，以及 Icarus 10.1 对新 Merge 标量 ANSI 端口的 “inherits dimensions” 提示。未执行专业 lint，不将编译成功描述为 lint 清零或生产签核。本次未扩大范围改写旧模块。

## 4. 证据文件

- report.json：机器可读统计与覆盖摘要。
- commands.log：工具版本、实际命令、编译警告、运行输出。
- source_manifest.json：实际参与验证的 45 文件 SHA-256、工具版本、种子及范围。
- native_filelist_check.json / native_filelist_compile.txt：不经脚本重写源清单的直接编译记录。
- tx/edge/rx/top.mem：已使用的测试向量。
- tx/edge/rx/top/top_wire.trace：实际仿真输出，供逐字节复算。
- artifacts_sha256.json：本目录交付文件的 SHA-256，清单本身不自哈希。

未保存模拟器程序、可执行仿真二进制和整份暂存源代码；可从源集哈希验证当前工作树对应关系。

## 5. 复现与哈希检查

在项目根目录执行。需自行提供 Python 3.10+、Icarus Verilog 和配套 vvp；脚本不自动下载工具。旧 Windows 工具的输出路径应选 ASCII。

```powershell
$fpTools = Join-Path $env:TEMP 'tsn_fp_tools_20261028'
$fpOutput = Join-Path $env:TEMP 'tsn_fp_regression_repeat'
python 'ethernet_tri_mode_latest/ethernet_tri_mode/trunk/bench/verilog/frame_preemption/run.py' --iverilog (Join-Path $fpTools 'bin/iverilog.exe') --output $fpOutput
```

从项目根目录使用 Python 复查本轮源码和证据绑定：

```python
from pathlib import Path
import hashlib, json
trunk = Path('ethernet_tri_mode_latest/ethernet_tri_mode/trunk')
result = trunk / 'bench/verilog/frame_preemption/results/20261028'
sources = json.loads((result / 'source_manifest.json').read_text(encoding='utf-8'))['sha256']
artifacts = json.loads((result / 'artifacts_sha256.json').read_text(encoding='utf-8'))['sha256']
for base, entries in ((trunk, sources), (result, artifacts)):
    for relative, expected in entries.items():
        assert hashlib.sha256((base / relative).read_bytes()).hexdigest() == expected, relative
print('PASS: source and evidence SHA-256 match')
```

SHA-256 证明内容对应，不证明技术规则符合最终标准。后续源码变化应重新回归并生成新证据；当前源码与本轮哈希不一致时，不能继续引用本目录声称新源码已通过。

## 6. 尚未完成/验证

自动 Verify/Respond、动态 CSR/多位配置原子 CDC、CPU 计数快照、中断、Qbv/CBS 联动尚未实现。缺少最终 802.3br Clause 99 正文逐条核对，强制模式不能冒充协商成功。

未执行原 MAC 全功能/PLI 回归、增强顶层完整在途掉线/复位矩阵、专业 lint、覆盖率或形式证明、工艺 RAM 推断、综合/STA/CDC/RDC、实板 PHY 和真实对端互通。默认新增数据存储为 12KiB 声明容量，无法据此承诺面积、满线速、任意拥塞无损或最坏时延。

完整的接口、状态机、差异和生产工作包见项目根目录的《帧抢占_代码修改与设计说明.md》与《帧抢占_802.1Qbu_协议详解与实现规划.md》。
