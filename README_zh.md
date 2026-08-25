# Circe

[English](README.md)

将 arm64 iOS 预编译二进制（静态库 `.a`、静态/动态 `.framework`、IPA）转换为 arm64 iOS Simulator 可用格式。

适用于第三方 SDK 只提供真机 slice、无法在模拟器上编译/链接的场景。

## 原理

Circe 修改 Mach-O 文件中的 `LC_BUILD_VERSION` load command，将 platform 从 `iOS (2)` 改为 `iOS Simulator (7)`，使链接器接受该二进制用于模拟器构建。对于静态库（`.a`），会解包所有 `.o` 成员逐一转换后重新打包。

## 命令行用法

```bash
# 转换静态库
Circe input.a output.a

# 转换 IPA 目录（in-place）
Circe path/to/ipa_directory
```

## Bazel 集成

通过 bzlmod 引入：

```python
# MODULE.bazel
bazel_dep(name = "circe", version = "1.0.0")
```

### arm2sim_archive

替代 `cc_import`，转换单个 `.a` 文件：

```python
load("@circe//:arm2sim.bzl", "arm2sim_archive")

arm2sim_archive(
    name = "some_lib",
    archive = "libfoo.a",
)
```

### arm2sim_static_framework_import

替代 `apple_static_framework_import`：

```python
load("@circe//:arm2sim.bzl", "arm2sim_static_framework_import")

arm2sim_static_framework_import(
    name = "SomeSDK",
    framework_imports = glob(["SomeSDK.framework/**"]),
    sdk_frameworks = ["UIKit", "CoreMedia"],
)
```

### arm2sim_dynamic_framework_import

替代 `apple_dynamic_framework_import`：

```python
load("@circe//:arm2sim.bzl", "arm2sim_dynamic_framework_import")

arm2sim_dynamic_framework_import(
    name = "SomeSDK",
    framework_imports = glob(["SomeSDK.framework/**"]),
)
```

### arm2sim_objc_import

替代 `objc_import`：

```python
load("@circe//:arm2sim.bzl", "arm2sim_objc_import")

arm2sim_objc_import(
    name = "some_lib",
    hdrs = glob(["include/**/*.h"]),
    archives = glob(["lib/**/*.a"]),
    includes = ["include"],
    deps = ["@other_dep//:lib"],
)
```

### 行为

所有 rule/macro 自动检测目标平台：

- **arm64 模拟器** — 通过 Circe 转换二进制
- **真机或其他** — 直接透传，零开销

下游使用方不需要写 `select()`，直接 `deps` 即可。

## 处理细节

- Fat binary 自动 `lipo -thin arm64`
- 大型静态库（数千 .o）分批调用 `ar` 避免 ARG_MAX 溢出
- 重名 `.o` 成员（如模板库的多 bit-depth 实例化）通过自定义 ar 解析保留
- APFS case-insensitive 冲突检测
- AppleDouble 元数据文件 (`._*`) 自动过滤
- 转换后 ad-hoc 重签名（archive 内部 `.o` 跳过签名以避免 fork 风暴）

## 为什么叫 "Circe"？

Circe（喀耳刻）是希腊神话中擅长变形术的女巫。篡改 Mach-O load command、骗过链接器让真机二进制在模拟器上跑——这种事在 iOS 圈子里一般被称为黑魔法，用女巫的名字恰如其分。

## 致谢

核心的 Mach-O 篡改思路参考自 [arm64-to-sim](https://bogo.wtf/arm64-to-sim.html)。Circe 在此基础上做了 Bazel 化集成，提供在 build graph 中转换预编译真机二进制的 rule。

## 构建

```bash
bazel build //Circe:Circe
```
