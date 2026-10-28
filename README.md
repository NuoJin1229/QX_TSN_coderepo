# QX_TSN_coderepo

## 帧抢占原型（2026-10-28）

- [协议审查与实现规划](帧抢占_802.1Qbu_协议详解与实现规划.md)：原方案问题、协议依据、实现范围与生产工作包。
- [RTL 设计、修改与验证说明](帧抢占_代码修改与设计说明.md)：端口、状态机、缓存、时钟复位、异常、实际验证矩阵。
- [RTL 接入说明](ethernet_tri_mode_latest/ethernet_tri_mode/trunk/rtl/verilog/frame_preemption/README.md)：增强顶层 `MAC_top_fp`、源清单及回归命令。
- [本轮验证摘要](ethernet_tri_mode_latest/ethernet_tri_mode/trunk/bench/verilog/frame_preemption/results/20261028/SUMMARY.md)：实际报告、源码哈希、已测/未测范围。

当前为 **1G 全双工、静态配置、手工强制模式** 数据通路原型，支持 e/p 分类、合法切分/续发、累计 mCRC、接收重组及错误回滚。原 `MAC_top` 保留可选。自动 Verify/Respond 和动态管理尚未实现；未完成综合、STA、CDC/RDC 与真实对端互通，不能当作已认证或可直接流片的完整 TSN 实现。
