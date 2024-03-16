# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Original implementation by Kevin Kiningham (@kkiningh) in kkiningh/rules_verilator.
# Ported to bazel_rules_hdl by Stephen Tridgell (@stridge-cruxml)

"""Functions for verilator."""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("//verilog:providers.bzl", "VerilogInfo")

def cc_compile_and_link_static_library(ctx, srcs, hdrs, deps, runfiles, includes = [], defines = []):
    """Compile and link C++ source into a static library

    Args:
        ctx: Context for rule
        srcs: The cpp sources generated by verilator.
        hdrs: The headers generated by verilator.
        deps: Library dependencies to build with.
        runfiles: Data dependencies that are read at runtime.
        includes: The includes for the verilator module to build.
        defines: Cpp defines to build with.

    Returns:
        CCInfo with the compiled library.
    """
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    compilation_contexts = [dep[CcInfo].compilation_context for dep in deps]
    compilation_context, compilation_outputs = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = ctx.attr.copts,
        srcs = srcs,
        includes = includes,
        defines = defines,
        public_hdrs = hdrs,
        compilation_contexts = compilation_contexts,
    )

    linking_contexts = [dep[CcInfo].linking_context for dep in deps]
    linking_context, linking_output = cc_common.create_linking_context_from_compilation_outputs(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        linking_contexts = linking_contexts,
        name = ctx.label.name,
        disallow_dynamic_library = True,
    )

    output_files = []
    if linking_output.library_to_link.static_library != None:
        output_files.append(linking_output.library_to_link.static_library)
    if linking_output.library_to_link.dynamic_library != None:
        output_files.append(linking_output.library_to_link.dynamic_library)

    return [
        DefaultInfo(files = depset(output_files), runfiles = ctx.runfiles(files = runfiles)),
        CcInfo(
            compilation_context = compilation_context,
            linking_context = linking_context,
        ),
    ]

_CPP_SRC = ["cc", "cpp", "cxx", "c++"]
_HPP_SRC = ["h", "hh", "hpp"]
_RUNFILES = ["dat", "mem"]

def _only_cpp(f):
    """Filter for just C++ source/headers"""
    if f.extension in _CPP_SRC + _HPP_SRC:
        return f.path
    return None

def _only_hpp(f):
    """Filter for just C++ headers"""
    if f.extension in _HPP_SRC:
        return f.path
    return None

def _verilator_cc_library(ctx):
    transitive_srcs = depset([], transitive = [ctx.attr.module[VerilogInfo].dag])
    all_srcs = [verilog_info_struct.srcs for verilog_info_struct in transitive_srcs.to_list()]
    all_files = [src for sub_tuple in all_srcs for src in sub_tuple]

    # Filter out .dat files.
    runfiles = []
    verilog_files = []
    for file in all_files:
        if file.extension in _RUNFILES:
            runfiles.append(file)
        else:
            verilog_files.append(file)

    verilator_output = ctx.actions.declare_directory(ctx.label.name + "-gen")

    prefix = "V" + ctx.attr.module_top

    args = ctx.actions.args()
    args.add("--no-std")
    args.add("--cc")
    args.add("--Mdir", verilator_output.path)
    args.add("--top-module", ctx.attr.module_top)
    args.add("--prefix", prefix)
    if ctx.attr.trace:
        args.add("--trace")
    for verilog_file in verilog_files:
        args.add(verilog_file.path)
    args.add_all(ctx.attr.vopts, expand_directories = False)

    ctx.actions.run(
        arguments = [args],
        mnemonic = "VerilatorCompile",
        executable = ctx.executable._verilator,
        inputs = verilog_files,
        outputs = [verilator_output],
        progress_message = "[Verilator] Compiling {}".format(ctx.label),
    )

    verilator_output_cpp = ctx.actions.declare_directory(ctx.label.name + "_cpp")
    verilator_output_hpp = ctx.actions.declare_directory(ctx.label.name + "_h")

    cp_args = ctx.actions.args()
    cp_args.add("--src_output", verilator_output_cpp.path)
    cp_args.add("--hdr_output", verilator_output_hpp.path)
    cp_args.add_all([verilator_output], map_each = _only_cpp, format_each = "--src=%s")
    cp_args.add_all([verilator_output], map_each = _only_hpp, format_each = "--hdr=%s")

    ctx.actions.run(
        mnemonic = "VerilatorCopyTree",
        arguments = [cp_args],
        inputs = [verilator_output],
        outputs = [verilator_output_cpp, verilator_output_hpp],
        executable = ctx.executable._copy_tree,
    )

    # Do actual compile
    defines = ["VM_TRACE"] if ctx.attr.trace else []
    deps = [ctx.attr._verilator_lib, ctx.attr._zlib, ctx.attr._verilator_svdpi]

    return cc_compile_and_link_static_library(
        ctx,
        srcs = [verilator_output_cpp],
        hdrs = [verilator_output_hpp],
        defines = defines,
        runfiles = runfiles,
        includes = [verilator_output_hpp.path],
        deps = deps,
    )

verilator_cc_library = rule(
    implementation = _verilator_cc_library,
    attrs = {
        "copts": attr.string_list(
            doc = "List of additional compilation flags",
            default = [],
        ),
        "module": attr.label(
            doc = "The top level module target to verilate.",
            providers = [VerilogInfo],
            mandatory = True,
        ),
        "module_top": attr.string(
            doc = "The name of the verilog module to verilate.",
            mandatory = True,
        ),
        "trace": attr.bool(
            doc = "Enable tracing for Verilator",
            default = False,
        ),
        "vopts": attr.string_list(
            doc = "Additional command line options to pass to Verilator",
            default = ["-Wall"],
        ),
        "_cc_toolchain": attr.label(
            doc = "CC compiler.",
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
        "_copy_tree": attr.label(
            doc = "A tool for copying a tree of files",
            cfg = "exec",
            executable = True,
            default = Label("//verilator/private:verilator_copy_tree"),
        ),
        "_verilator": attr.label(
            doc = "Verilator binary.",
            executable = True,
            cfg = "exec",
            default = Label("@verilator//:verilator_executable"),
        ),
        "_verilator_lib": attr.label(
            doc = "Verilator library",
            default = Label("@verilator//:libverilator"),
        ),
        "_verilator_svdpi": attr.label(
            doc = "Verilator svdpi lib",
            default = Label("@verilator//:svdpi"),
        ),
        "_zlib": attr.label(
            doc = "zlib dependency",
            default = Label("@net_zlib//:zlib"),
        ),
    },
    provides = [
        CcInfo,
        DefaultInfo,
    ],
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    fragments = ["cpp"],
)
