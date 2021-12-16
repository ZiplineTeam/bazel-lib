"Setup jq toolchain repositories and rules"

JQ_PLATFORMS = {
    "linux32": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_32",
        ],
    ),
    "linux64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    ),
    "osx-amd64": struct(
        compatible_with = [
            "@platforms//os:macos",
        ],
    ),
    "win32": struct(
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_32",
        ],
    ),
    "win64": struct(
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
    ),
}

# https://github.com/stedolan/jq/releases
#
# The integrity hashes can be computed with
# shasum -b -a 384 [downloaded file] | awk '{ print $1 }' | xxd -r -p | base64
JQ_VERSIONS = {
    "1.6": {
        "linux32": "sha384-hBGwNC3R0WyEbDQnrabzvcURSSV9BGxVrUVXLCH1C+Ilo7YDlzfTJSr4gadVssVI",
        "linux64": "sha384-+K6tuwxrC/P4WBYRJ7YXcpeLS7GesbbnUhq4r9w7k0lCUC1KlhyXXf0sFQgOg0dI",
        "osx-amd64": "sha384-ZLZljM9OyKCJbJbv7s1SRYSeMbVxfRc6kFNUlk9U/IL10Xm2xr4cxx3SZKv93QFO",
        "win32": "sha384-PO+MMFELa0agwy35NuKhrxn8C6GjNq8gnzL3NvYSWNx/pwClCl7yzCONGhLFknMc",
        "win64": "sha384-O4qdyhb+0zU1XAuUKc1Mil5hlbSbCUcPQOGRtkJUqryv7X0IeKcMCIuZw97q9WGr",
    },
    "1.5": {
        "linux32": "sha-384MPO/DYgSPNRkrGEOCvZBZ8UvTdP4YVzXJoSYnWz9/IuywSRVqqyO6se9S72sue56",
        "linux64": "sha384-/Su0ihtb867nCQTzQlTHjve+KpwfzsPws5ILj6hl7k33Qw+FwnyxAVITDh/pOOYw",
        "osx-amd64": "sha384-X3VGwLkqaLafis82SySkqFPGIiJMdWdzcHPWLJ0q87XF+MGVc/e2n65a1yMBW6Nf",
        "win32": "sha384-zZoz1F0nrhl5yvnGm37TxDw7dMWUQtJeDVmHfdAhLYMRGynIxefJgmB4Ty8gjNeu",
        "win64": "sha384-NtaejeSFoKaXxxT1nPqxdOWRmIZAFF8wFTKjqs/4W0qYMYLohmO73AGKKR2XIg84",
    },
}

JqInfo = provider(
    doc = "Provide info for executing jq",
    fields = {
        "bin": "Executable jq binary",
    },
)

def _jq_toolchain_impl(ctx):
    binary = ctx.attr.bin.files.to_list()[0]

    # Make the $(JQ_BIN) variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        "JQ_BIN": binary.path,
    })
    default_info = DefaultInfo(
        files = depset([binary]),
        runfiles = ctx.runfiles(files = [binary]),
    )
    jq_info = JqInfo(
        bin = binary,
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        jqinfo = jq_info,
        template_variables = template_variables,
        default = default_info,
    )

    return [default_info, toolchain_info, template_variables]

jq_toolchain = rule(
    implementation = _jq_toolchain_impl,
    attrs = {
        "bin": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
    },
)

def _jq_toolchains_repo_impl(repository_ctx):
    # Expose a concrete toolchain which is the result of Bazel resolving the toolchain
    # for the execution or target platform.
    # Workaround for https://github.com/bazelbuild/bazel/issues/14009
    starlark_content = """# Generated by lib/private/toolchain.bzl

# Forward all the providers
def _resolved_toolchain_impl(ctx):
    toolchain_info = ctx.toolchains["@aspect_bazel_lib//lib:jq_toolchain_type"]
    return [
        toolchain_info,
        toolchain_info.default,
        toolchain_info.jqinfo,
        toolchain_info.template_variables,
    ]

# Copied from java_toolchain_alias
# https://cs.opensource.google/bazel/bazel/+/master:tools/jdk/java_toolchain_alias.bzl
resolved_toolchain = rule(
    implementation = _resolved_toolchain_impl,
    toolchains = ["@aspect_bazel_lib//lib:jq_toolchain_type"],
    incompatible_use_toolchain_transition = True,
)
"""
    repository_ctx.file("defs.bzl", starlark_content)

    build_content = """# Generated by lib/private/toolchain.bzl
#
# These can be registered in the workspace file or passed to --extra_toolchains flag.
# By default all these toolchains are registered by the jq_register_toolchains macro
# so you don't normally need to interact with these targets.

load(":defs.bzl", "resolved_toolchain")

resolved_toolchain(name = "resolved_toolchain", visibility = ["//visibility:public"])

"""

    for [platform, meta] in JQ_PLATFORMS.items():
        build_content += """
toolchain(
    name = "{platform}_toolchain",
    exec_compatible_with = {compatible_with},
    target_compatible_with = {compatible_with},
    toolchain = "@{name}_{platform}//:jq_toolchain",
    toolchain_type = "@aspect_bazel_lib//lib:jq_toolchain_type",
)
""".format(
            platform = platform,
            name = repository_ctx.attr.name,
            user_repository_name = repository_ctx.attr.user_repository_name,
            compatible_with = meta.compatible_with,
        )

    # Base BUILD file for this repository
    repository_ctx.file("BUILD.bazel", build_content)

jq_toolchains_repo = repository_rule(
    _jq_toolchains_repo_impl,
    doc = """Creates a repository with toolchain definitions for all known platforms
     which can be registered or selected.""",
    attrs = {
        "user_repository_name": attr.string(doc = "Base name for toolchains repository"),
    },
)

def _jq_platform_repo_impl(repository_ctx):
    is_windows = repository_ctx.attr.platform == "win32" or repository_ctx.attr.platform == "win64"
    url = "https://github.com/stedolan/jq/releases/download/jq-{0}/jq-{1}{2}".format(
        repository_ctx.attr.jq_version,
        repository_ctx.attr.platform,
        ".exe" if is_windows else "",
    )

    repository_ctx.download(
        url = url,
        output = "jq.exe" if is_windows else "jq",
        executable = True,
        integrity = JQ_VERSIONS[repository_ctx.attr.jq_version][repository_ctx.attr.platform],
    )
    build_content = """#Generated by lib/repositories.bzl
load("@aspect_bazel_lib//lib/private:jq_toolchain.bzl", "jq_toolchain")
jq_toolchain(name = "jq_toolchain", bin = select({
    "@bazel_tools//src/conditions:host_windows": ":jq.exe",
    "//conditions:default": ":jq",
}), visibility = ["//visibility:public"])
"""

    # Base BUILD file for this repository
    repository_ctx.file("BUILD.bazel", build_content)

jq_platform_repo = repository_rule(
    implementation = _jq_platform_repo_impl,
    doc = "Fetch external tools needed for jq toolchain",
    attrs = {
        "jq_version": attr.string(mandatory = True, values = JQ_VERSIONS.keys()),
        "platform": attr.string(mandatory = True, values = JQ_PLATFORMS.keys()),
    },
)