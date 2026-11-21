# Releasing zig-routing

The release flow builds the full engine. It checks the tagged main
commit's CI, including the binary size and regional performance jobs,
and requires all open `type:gate` issues to be resolved before publishing.

## Prepare the version

Use the `bump` and `changelog` commands from the sibling Zig tools.
They generate the version and conventional-commit notes. Build zig-routing
with the Zig version pinned in `deps.yaml`.

Use a changelog build that includes the Git log delimiter fix so the notes
include the entire release range. [zig-changelog fix](https://github.com/zig-utils/zig-changelog/commit/0423c75)

```sh
python3 scripts/release.py prepare patch --dry-run
python3 scripts/release.py prepare patch
git diff -- build.zig.zon package.json CHANGELOG.md
```

The preparation writes the Zig and Pantry manifests and the changelog.
Review and commit those files to main. The release script checks that
both manifests have the same version and that their Zig pins agree.
The build embeds the manifest version in `zr --version` and the JSON
`/status` response. Release binaries also embed the full source commit.

Preparing 1.0.0 requires `--approve-1.0` after explicit maintainer approval.

## Stage a dry run

Run from a clean checkout of the version commit. The output directory
will be created after all selected binaries have passed verification.

```sh
python3 scripts/release.py build --output zig-out/release-dry-run
python3 scripts/release.py verify --output zig-out/release-dry-run
pantry publish . --dry-run --ignore-scripts
```

This cross-compiles Linux x86-64 baseline, Linux x86-64-v3, Linux aarch64,
and macOS aarch64 in ReleaseFast. Each archive contains `zr`, the license,
and the notice. Its other files contain the SHA-256 checksum and JSON
provenance, including the commit, toolchain, target and CPU profile.
The verifier checks both digests, the executable format, and the
embedded commit. The build runs version and status smoke checks when the
binary matches the host architecture.

For a hosted dry run, dispatch the Release workflow with the default
inputs. Its four native jobs run the same packaging command and upload
the archives and metadata as workflow artifacts.

## Publish a version

Wait for the version commit's main CI run, then push the matching
annotated tag to origin. The Release workflow verifies the tag, runs
the four native builds, verifies their assets, and rechecks the gates.
It stages the GitHub release as a draft, publishes the source package
to Pantry, and makes the draft public after Pantry succeeds. The
`PANTRY_TOKEN` repository secret supplies registry authorization.
Reruns verify existing release assets and the Pantry payload.

For 1.0.0, a repository maintainer or admin must dispatch the workflow
from the tag with both publication and 1.0.0 approval enabled.

```sh
gh workflow run release.yml --ref v1.0.0 -f publish=true -f approve_1_0=true
```

[GitHub CLI workflow dispatch](https://cli.github.com/manual/gh_workflow_run)
