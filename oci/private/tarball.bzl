"""Create a tarball from oci_image that can be loaded by runtimes such as podman and docker.

For example, given an `:image` target, you could write

```
oci_tarball(
    name = "tarball",
    image = ":image",
    repotags = ["my-repository:latest"],
)
```

and then run it in a container like so:

```
bazel build //path/to:image
docker load --input $(bazel cquery --output=files //path/to:image)
docker run --rm my-repository:latest
```
"""

# buildifier: disable=bzl-visibility
load(
    "@rules_pkg//pkg/private:pkg_files.bzl",
    "add_single_file",
    "add_tree_artifact",
    "write_manifest",
)

doc = """Creates tarball from OCI layouts that can be loaded into docker daemon without needing to publish the image first.

Passing anything other than oci_image to the image attribute will lead to build time errors.
"""

attrs = {
    "image": attr.label(mandatory = True, allow_single_file = True, doc = "Label of a directory containing an OCI layout, typically `oci_image`"),
    "repotags": attr.label(
        doc = """\
            a file containing repotags, one per line.
            """,
        allow_single_file = [".txt"],
    ),
    "_tarball_sh": attr.label(allow_single_file = True, default = "//oci/private:tarball.sh.tpl"),
    "_build_tar": attr.label(
        default = Label("@rules_pkg//pkg/private/tar:build_tar"),
        cfg = "exec",
        executable = True,
        allow_files = True,
    ),
}

# TODO: find a way to call pkg_tar without depending on the private stuff. See: https://github.com/bazelbuild/rules_pkg/issues/629
def _tar_tarball(ctx, blobs, manifest):
    tarball = ctx.actions.declare_file("{}/tarball.tar".format(ctx.label.name))

    tar_manifest = ctx.actions.declare_file("{}/tar.manifest".format(ctx.label.name))
    content_map = {}
    add_tree_artifact(content_map, "blobs", blobs, blobs.owner, mode = "0644")
    add_single_file(content_map, "manifest.json", manifest, ctx.label)
    write_manifest(ctx, tar_manifest, content_map)

    args = ctx.actions.args()
    args.add("--directory", "/")
    args.add("--output", tarball.path)
    args.add("--manifest", tar_manifest.path)

    ctx.actions.run(
        inputs = [blobs, manifest, tar_manifest],
        outputs = [tarball],
        executable = ctx.executable._build_tar,
        arguments = [args],
    )

    return tarball

def _tarball_impl(ctx):
    image = ctx.file.image
    manifest = ctx.actions.declare_file("{}/manifest.json".format(ctx.label.name))
    blobs = ctx.actions.declare_directory("{}/blobs".format(ctx.label.name))

    yq_bin = ctx.toolchains["@aspect_bazel_lib//lib:yq_toolchain_type"].yqinfo.bin
    executable = ctx.actions.declare_file("{}/tarball.sh".format(ctx.label.name))

    substitutions = {
        "{{yq}}": yq_bin.path,
        "{{image_dir}}": image.path,
        "{{blobs_dir}}": blobs.path,
        "{{manifest_path}}": manifest.path,
    }

    if ctx.attr.repotags:
        substitutions["{{tags}}"] = ctx.file.repotags.path

    ctx.actions.expand_template(
        template = ctx.file._tarball_sh,
        output = executable,
        is_executable = True,
        substitutions = substitutions,
    )

    ctx.actions.run(
        executable = executable,
        inputs = [image, ctx.file.repotags],
        outputs = [manifest, blobs],
        tools = [yq_bin],
        mnemonic = "OCITarball",
        progress_message = "OCI Tarball %{label}",
    )

    tarball = _tar_tarball(ctx, blobs, manifest)

    return [
        DefaultInfo(files = depset([tarball])),
    ]

oci_tarball = rule(
    implementation = _tarball_impl,
    attrs = attrs,
    doc = doc,
    toolchains = [
        "@aspect_bazel_lib//lib:yq_toolchain_type",
    ],
)
