"""Rules to convert arm64 iOS binaries to arm64 iOS Simulator using Circe."""

load("@build_bazel_rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_static_framework_import")

def _is_arm64_simulator(ctx):
    """True iff the current configuration targets arm64 iOS Simulator."""
    apple_fragment = ctx.fragments.apple
    platform = apple_fragment.single_arch_platform
    cpu = apple_fragment.single_arch_cpu
    return cpu == "arm64" and not platform.is_device

# --- arm2sim_archive ---

def _arm2sim_archive_impl(ctx):
    input_archive = ctx.file.archive

    if _is_arm64_simulator(ctx):
        output = ctx.actions.declare_file(ctx.label.name + ".a")
        circe = ctx.executable._circe
        ctx.actions.run(
            executable = circe,
            arguments = [input_archive.path, output.path],
            inputs = [input_archive],
            outputs = [output],
            tools = [circe],
            mnemonic = "Arm2Sim",
            progress_message = "Converting %s to arm64-simulator" % input_archive.short_path,
        )
        return [DefaultInfo(files = depset([output]))]
    else:
        return [DefaultInfo(files = depset([input_archive]))]

arm2sim_archive = rule(
    implementation = _arm2sim_archive_impl,
    fragments = ["apple"],
    attrs = {
        "archive": attr.label(
            allow_single_file = [".a"],
            mandatory = True,
            doc = "The input arm64 iOS static archive to convert.",
        ),
        "_circe": attr.label(
            default = "//Circe:_binary",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Converts an arm64 iOS static archive to arm64 iOS Simulator using Circe. Pass-through on device.",
)

# --- arm2sim_framework (internal) ---

def _is_framework_binary(f):
    """Determine if a file is the main binary inside a .framework directory.

    The main binary is `<Foo>.framework/<Foo>` where the file basename
    matches the framework name (without `.framework`). This avoids treating
    sibling root files like `JOB_ID` or `COMMIT_SHA` as binaries.
    """
    parts = f.path.split("/")
    for i, part in enumerate(parts):
        if part.endswith(".framework"):
            fw_name = part[:-len(".framework")]
            remaining = parts[i + 1:]
            if len(remaining) == 1 and remaining[0] == fw_name:
                return True
    return False

def _arm2sim_framework_impl(ctx):
    if not _is_arm64_simulator(ctx):
        return [DefaultInfo(files = depset([
            f for f in ctx.files.framework_imports if not f.basename.startswith("._")
        ]))]

    circe = ctx.executable._circe
    outputs = []

    for src in ctx.files.framework_imports:
        # Skip macOS AppleDouble metadata files (`._*`) that get injected into
        # framework directories by extended-attribute-aware filesystems. These
        # are not real framework content; if propagated, they masquerade as
        # `._module.modulemap`, `._Headers/*`, etc. and confuse clang.
        if src.basename.startswith("._"):
            continue
        # Preserve directory structure relative to the .framework
        parts = src.short_path.split("/")
        fw_index = -1
        for i, part in enumerate(parts):
            if part.endswith(".framework"):
                fw_index = i
                break
        if fw_index >= 0:
            rel_path = "/".join(parts[fw_index:])
        else:
            rel_path = src.basename

        out = ctx.actions.declare_file(ctx.label.name + "_sim/" + rel_path)

        if _is_framework_binary(src):
            ctx.actions.run(
                executable = circe,
                arguments = [src.path, out.path],
                inputs = [src],
                outputs = [out],
                tools = [circe],
                mnemonic = "Arm2SimFramework",
                progress_message = "Converting %s to arm64-simulator" % src.short_path,
            )
        else:
            ctx.actions.symlink(output = out, target_file = src)

        outputs.append(out)

    return [DefaultInfo(files = depset(outputs))]

_arm2sim_framework = rule(
    implementation = _arm2sim_framework_impl,
    fragments = ["apple"],
    attrs = {
        "framework_imports": attr.label_list(allow_files = True, mandatory = True),
        "_circe": attr.label(
            default = "//Circe:_binary",
            executable = True,
            cfg = "exec",
        ),
    },
)

# --- Public macros ---

def arm2sim_static_framework_import(name, framework_imports, visibility = None, **kwargs):
    """Drop-in replacement for apple_static_framework_import with arm2sim conversion on simulator."""
    _arm2sim_framework(
        name = name + "_arm2sim",
        framework_imports = framework_imports,
    )
    apple_static_framework_import(
        name = name,
        framework_imports = [":" + name + "_arm2sim"],
        visibility = visibility,
        **kwargs
    )

def arm2sim_dynamic_framework_import(name, framework_imports, visibility = None, **kwargs):
    """Drop-in replacement for apple_dynamic_framework_import with arm2sim conversion on simulator."""
    _arm2sim_framework(
        name = name + "_arm2sim",
        framework_imports = framework_imports,
    )
    apple_dynamic_framework_import(
        name = name,
        framework_imports = [":" + name + "_arm2sim"],
        visibility = visibility,
        **kwargs
    )

# --- arm2sim_objc_import ---

def _arm2sim_objc_import_impl(ctx):
    """Converts all input archives through Circe on simulator, pass-through on device."""
    if not _is_arm64_simulator(ctx):
        return [DefaultInfo(files = depset(ctx.files.archives))]

    circe = ctx.executable._circe
    outputs = []
    for src in ctx.files.archives:
        out = ctx.actions.declare_file(ctx.label.name + "_sim/" + src.basename)
        ctx.actions.run(
            executable = circe,
            arguments = [src.path, out.path],
            inputs = [src],
            outputs = [out],
            tools = [circe],
            mnemonic = "Arm2SimArchive",
            progress_message = "Converting %s to arm64-simulator" % src.short_path,
        )
        outputs.append(out)
    return [DefaultInfo(files = depset(outputs))]

_arm2sim_objc_import_archives = rule(
    implementation = _arm2sim_objc_import_impl,
    fragments = ["apple"],
    attrs = {
        "archives": attr.label_list(allow_files = [".a"], mandatory = True),
        "_circe": attr.label(
            default = "//Circe:_binary",
            executable = True,
            cfg = "exec",
        ),
    },
)

def arm2sim_objc_import(name, archives, visibility = None, **kwargs):
    """Drop-in replacement for objc_import with arm2sim conversion on simulator.

    Accepts both explicit file paths and glob() expressions for archives.
    Each .a archive is individually converted through Circe when building
    for arm64 simulator; device builds pass through unchanged.
    """
    _arm2sim_objc_import_archives(
        name = name + "_arm2sim",
        archives = archives,
    )
    native.objc_import(
        name = name,
        archives = [":" + name + "_arm2sim"],
        visibility = visibility,
        **kwargs
    )
