"""Rules to convert arm64 iOS binaries to arm64 iOS Simulator using Circe."""

load("@build_bazel_rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_static_framework_import")

def _is_arm64_simulator(ctx):
    """True iff the current configuration targets arm64 iOS Simulator."""
    apple_fragment = ctx.fragments.apple
    platform = apple_fragment.single_arch_platform
    cpu = apple_fragment.single_arch_cpu
    return cpu == "arm64" and not platform.is_device

_FRAMEWORK_ACTION_COMMAND = """
set -eu

circe="$1"
shift

# Root files are copied in this same action as the binary conversion. If a
# copy is produced by a separate action, Bazel mounts that output as an input
# symlink in this action's sandbox and Xcode 27's codesign rejects Info.plist
# with ELOOP.
root_count="$1"
shift
i=0
while [ "$i" -lt "$root_count" ]; do
    src="$1"
    dst="$2"
    shift 2
    /bin/mkdir -p "${dst%/*}"
    /bin/cp -f "$src" "$dst"
    i=$((i + 1))
done

binary_count="$1"
shift
i=0
while [ "$i" -lt "$binary_count" ]; do
    src="$1"
    dst="$2"
    shift 2
    /bin/mkdir -p "${dst%/*}"
    "$circe" "$src" "$dst"
    i=$((i + 1))
done
"""

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
    parts = f.short_path.split("/")
    for i, part in enumerate(parts):
        if part.endswith(".framework"):
            fw_name = part[:-len(".framework")]
            remaining = parts[i + 1:]
            if len(remaining) == 1 and remaining[0] == fw_name:
                return True
    return False

def _framework_key(f):
    """Return the outermost framework path containing a file, or empty string."""
    parts = f.short_path.split("/")
    for i, part in enumerate(parts):
        if part.endswith(".framework"):
            return "/".join(parts[:i + 1])
    return ""

def _framework_depth(f):
    """Return the number of nested `.framework` components in a file path."""
    return len([part for part in f.short_path.split("/") if part.endswith(".framework")])

def _is_code_signature_file(f):
    """Return true for files in a framework's imported `_CodeSignature` directory.

    The imported seal belongs to the device binary. It is invalid after Circe
    rewrites that binary, and Circe's ad-hoc signing pass creates a new seal.
    """
    parts = f.short_path.split("/")
    for i, part in enumerate(parts):
        if part.endswith(".framework") and "_CodeSignature" in parts[i + 1:]:
            return True
    return False

def _is_framework_root_file(f):
    """Return true for a file directly inside the innermost `.framework` root.

    Xcode 27's `codesign` opens a framework's sibling `Info.plist` without
    following symlinks. Root files are therefore materialized as real copies;
    nested headers and modules can remain symlinks.
    """
    parts = f.short_path.split("/")
    framework_index = -1
    for i, part in enumerate(parts):
        if part.endswith(".framework"):
            framework_index = i
    return framework_index >= 0 and len(parts) == framework_index + 2

def _ordered_binary_entries(entries):
    """Return binaries deepest-first so nested frameworks are signed first."""
    ordered = []
    for entry in entries:
        insert_at = len(ordered)
        for i, current in enumerate(ordered):
            if entry.framework_depth > current.framework_depth:
                insert_at = i
                break
        ordered.insert(insert_at, entry)
    return ordered

def _arm2sim_framework_impl(ctx):
    if not _is_arm64_simulator(ctx):
        # Device/non-simulator builds are true pass-throughs, so retain the
        # imported signature and only remove AppleDouble metadata.
        return [DefaultInfo(files = depset([
            f
            for f in ctx.files.framework_imports
            if not f.basename.startswith("._")
        ]))]

    circe = ctx.executable._circe
    outputs = []
    framework_groups = {}
    framework_group_order = []

    for src in ctx.files.framework_imports:
        # Skip macOS AppleDouble metadata files (`._*`) that get injected into
        # framework directories by extended-attribute-aware filesystems. These
        # are not real framework content; if propagated, they masquerade as
        # `._module.modulemap`, `._Headers/*`, etc. and confuse clang.
        if src.basename.startswith("._"):
            continue

        # The device seal describes the pre-conversion binary and must not be
        # copied into the simulator framework. Circe creates a fresh seal when
        # it signs a converted Mach-O binary.
        if _is_code_signature_file(src):
            continue

        # Preserve directory structure relative to the outermost `.framework`.
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
        framework_key = _framework_key(src)
        is_binary = _is_framework_binary(src)
        entry = struct(
            src = src,
            out = out,
            framework_depth = _framework_depth(src),
            is_binary = is_binary,
            is_root = _is_framework_root_file(src) and not is_binary,
        )

        # Files outside a framework are not expected, but retain the old
        # pass-through behavior rather than putting them in a signing action.
        if not framework_key:
            ctx.actions.symlink(output = out, target_file = src)
        else:
            if not entry.is_binary and not entry.is_root:
                ctx.actions.symlink(output = out, target_file = src)
            if framework_key not in framework_groups:
                framework_groups[framework_key] = []
                framework_group_order.append(framework_key)
            framework_groups[framework_key].append(entry)

        outputs.append(out)

    # Each outermost framework gets one action that materializes its root files
    # and converts all binaries. Nested binaries run deepest-first so an outer
    # framework's bundle signature sees already-converted nested frameworks.
    for framework_key in framework_group_order:
        entries = framework_groups[framework_key]
        binary_entries = [entry for entry in entries if entry.is_binary]
        root_entries = [entry for entry in entries if entry.is_root]

        if not binary_entries:
            # There is nothing to sign. Keep the old lightweight behavior for
            # root files in a directory that does not contain a recognizable
            # framework binary.
            for entry in root_entries:
                ctx.actions.run_shell(
                    command = "/bin/mkdir -p \"${2%/*}\" && /bin/cp -f \"$1\" \"$2\"",
                    arguments = [entry.src.path, entry.out.path],
                    inputs = [entry.src],
                    outputs = [entry.out],
                    mnemonic = "Arm2SimFrameworkCopy",
                    progress_message = "Copying %s (required by codesign)" % entry.src.short_path,
                )
            continue

        ordered_binaries = _ordered_binary_entries(binary_entries)
        nested_inputs = [
            entry.out
            for entry in entries
            if not entry.is_binary and not entry.is_root
        ]
        action_inputs = [entry.src for entry in root_entries + ordered_binaries] + nested_inputs
        action_outputs = [entry.out for entry in root_entries + ordered_binaries]
        action_arguments = [circe.path, str(len(root_entries))]
        for entry in root_entries:
            action_arguments += [entry.src.path, entry.out.path]
        action_arguments.append(str(len(ordered_binaries)))
        for entry in ordered_binaries:
            action_arguments += [entry.src.path, entry.out.path]

        # codesign may create `_CodeSignature/CodeResources` while converting a
        # dynamic framework. It is intentionally not declared here: the seal
        # contains paths for the symlinked non-root inputs and is not valid once
        # the framework is materialized. The downstream Apple framework
        # processor re-signs the copied framework and creates its final seal.
        ctx.actions.run_shell(
            command = _FRAMEWORK_ACTION_COMMAND,
            arguments = action_arguments,
            inputs = action_inputs,
            outputs = action_outputs,
            tools = [circe],
            mnemonic = "Arm2SimFramework",
            progress_message = "Converting %s to arm64-simulator" % framework_key,
        )

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
