# ams-native · 预留模块（当前为空）

## 状态

本目录目前只有 `include/`、`src/`、`test/` 三个空目录，**没有任何源码**，
也未被 `scripts/build.sh` 的 `TOP_ORDER` 纳入构建拓扑。

## 为什么保留

设计文档 `docs/02` 曾预留一条 C / C++ FFI 通道，用于在出现以下场景时把热点下沉：

- 大文件的流式加解密与哈希（当前附件下载响应仍需 base64 编码，见 `docs/10` 已知局限）
- 图像编解码 / OCR / 缩略图（当前 SDK 无图像库，这几项能力已降级交付）
- 未来若上游提供可用的 SM2 / SM4-GCM 实现，需要接入非仓颉密码学库时的桥接层

实测结论：当前纯仓颉实现的性能不构成瓶颈，因此**本轮 A 方向（生产就绪收口）
不落地该模块**，也不为凑「模块完整度」而加入空编译单元。

## 启用条件（若要开工，须先满足）

1. 有明确的性能画像证据（基准脚本 `scripts/ci/bench_latency.py` 可作为起点）；
2. 确认 FFI 边界与内存所有权规则，并写入 `docs/08` 变更记录；
3. 在 `scripts/build.sh` 与 `scripts/build-linux.sh` 的 `TOP_ORDER` 中插入该包，
   同时补齐 Windows / Linux 两套链接参数（当前两个脚本都没有 C++ 工具链探测）；
4. 补对应单元测试，并把 `ams-native` 加入 `scripts/test.sh` 的 `PKGS`；
5. 保持分层单向：`ams-native` 只能被 `ams-crypto` / `ams-storage` 依赖，
   不得反向 import 任何上层包（`scripts/ci/check-consistency.py` 会检查分层方向）。

> 维护提示：如果确认不再需要该通道，可整体删除本目录，并从 `README.md`
> 的目录结构中移除对应行；不要留一个「看似有实现、实际为空」的包声明。
