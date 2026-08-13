# Circe

[中文](README_zh.md)

Convert pre-built arm64 iOS binaries (static libraries `.a`, static/dynamic `.framework`, IPA) to arm64 iOS Simulator format.

Useful when third-party SDKs ship only device slices and cannot be compiled or linked for the simulator.

## How it works

Circe rewrites the `LC_BUILD_VERSION` load command in Mach-O files, changing the platform from `iOS (2)` to `iOS Simulator (7)` so the linker accepts the binary for simulator builds. For static archives (`.a`), it unpacks all `.o` members, converts each one, and repackages them.

## CLI usage

```bash
# Convert a static archive
Circe input.a output.a

# Convert an IPA directory (in-place)
Circe path/to/ipa_directory
```

## Bazel integration

Add via bzlmod:

```python
# MODULE.bazel
bazel_dep(name = "circe", version = "1.0.0")
```

### arm2sim_archive

Drop-in replacement for `cc_import`, converts a single `.a` file:

```python
load("@circe//:arm2sim.bzl", "arm2sim_archive")

arm2sim_archive(
    name = "some_lib",
    archive = "libfoo.a",
)
```

### arm2sim_static_framework_import

Drop-in replacement for `apple_static_framework_import`:

```python
load("@circe//:arm2sim.bzl", "arm2sim_static_framework_import")

arm2sim_static_framework_import(
    name = "SomeSDK",
    framework_imports = glob(["SomeSDK.framework/**"]),
    sdk_frameworks = ["UIKit", "CoreMedia"],
)
```

### arm2sim_dynamic_framework_import

Drop-in replacement for `apple_dynamic_framework_import`:

```python
load("@circe//:arm2sim.bzl", "arm2sim_dynamic_framework_import")

arm2sim_dynamic_framework_import(
    name = "SomeSDK",
    framework_imports = glob(["SomeSDK.framework/**"]),
)
```

### arm2sim_objc_import

Drop-in replacement for `objc_import`:

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

### Behavior

All rules/macros automatically detect the target platform:

- **arm64 simulator** — binary is converted through Circe
- **device or other** — passed through unchanged, zero overhead

Downstream targets just use `deps` — no `select()` needed.

## Implementation details

- Fat binaries are automatically thinned via `lipo -thin arm64`
- Large archives (thousands of `.o` members) are batched to avoid ARG_MAX overflow
- Duplicate `.o` member names (e.g. template instantiations across bit depths) are preserved via custom ar parsing
- APFS case-insensitive collision detection
- AppleDouble metadata files (`._*`) are automatically filtered
- Ad-hoc re-signing after conversion (individual `.o` inside archives skip signing to avoid fork storms)

## Why "Circe"?

In Greek mythology, Circe is the sorceress who transforms men into beasts. Rewriting Mach-O load commands to trick the linker into accepting device binaries on the simulator is the kind of dark magic that earns the name.

## Build

```bash
bazel build //Circe:Circe
```
