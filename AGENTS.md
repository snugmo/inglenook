# AGENTS.md — Inglenook Bootc Image Agent Configuration

> **Status: pre-build.** Only `images/Containerfile` exists so far. The remaining
> structure and conventions below are the plan for building the image — update
> this file as the plan becomes reality.

## Project Overview

**inglenook** — a Fedora-based bootable OS image built with [bootc](https://github.com/containers/bootc) (bootable containers), from the [Snugmo](https://github.com/snugmo) GitHub org. The image is defined by a `Containerfile` that FROMs the official Fedora bootc base, built into an OCI image with `podman`/`buildah` (the base's bootc stage is inherited), and is installed on a host with `bootc install` from a running container; deployed hosts update transactionally via `bootc upgrade`.

## Structure

Layout:

```
images/
  Containerfile  # The OS image: Fedora base + packages + host configuration
  build.sh       # buildah wrapper with registry/tag config (planned)
docs/            # On-demand reference docs — read when relevant (see below)
```

## Essential Commands

| Task                     | Command                                                                          |
| ------------------------ | -------------------------------------------------------------------------------- |
| Build bootc OCI image    | `buildah bud -f images/Containerfile -t ghcr.io/snugmo/inglenook:<tag> .` (or `podman build`) |
| Build + push to ghcr     | `./images/build.sh push` (once `build.sh` exists)                                 |
| Install image to disk    | `bootc install` (from inside a running container)                                 |
| Inspect a deployed host  | `bootc status` (on the host)                                                      |
| Update a deployed host   | `bootc upgrade` (alias `bootc update`, on the host)                               |
| Switch image reference   | `bootc switch <ref>` (on the host)                                                |
| Roll back a deployment   | `bootc rollback` (on the host)                                                    |

> **VM/ISO media**: the ostree-rs-era `bootc image-prepare` verb is *not* part of the
> current (1.16) CLI. If/when we need to distribute VM or ISO images, that will be an
> osbuild-based (or equivalent) flow — TBD, and it would live in `images/build.sh`.

## Key Conventions

### Commit Conventions

- Make small, logically contained commits; one per meaningful change, committed as you go.
- Prefix every commit subject with a single emoji representing the change, followed by the conventional type prefix used in this repo (`feat:`, `chore:`, `docs:`, `fix:`, `refactor:`, …); keep subjects under 72 characters. Use `feat:` when the change adds a new capability to the image (a new package, tool, or service), and `chore:` for maintenance such as version bumps and internal adjustments. Examples: `✨ feat: add Rust toolchain to OS image`, `📦 chore: update Fedora base from 44 to 45`, `✏️ docs: …`, `🐛 fix: …`.
- End commit messages with an `Assisted-by: <agent>:<model>` trailer, where `<agent>` is the coding agent doing the committing (no "generated with" line).

### OS Image (`Containerfile`)

- Based on **Fedora 45** via `registry.fedoraproject.org/fedora-bootc:45` (a single `FEDORA_VERSION` build arg drives the `FROM` and the base.name label; we stay off Rawhide/46 on purpose, so upstream pre-release bugs don't mask our own tooling issues) — the earliest bootc-capable layer of the Fedora image cake (bootc-ified `fedora-minimal`, no desktop/GUI), not UBI; runs as non-root user `user` (UID 1000).
- The final stage must be a bootc stage — our base already is, and the stage is inherited through added layers. Never base a stage on a *non*-bootc image without adding a `switch-to-bootc-container` step.
- All binary downloads are verified as far as possible (SHA-256 `ADD --checksum=…`, cosign signatures, or SLSA provenance).
- Order instructions least-to-most frequently changing; package installs before configuration, to maximize layer reuse.

### Build Script (`images/build.sh`)

- Uses `buildah` (not `docker`) — rootless, works in CI without a Docker daemon (the bootc base image needs no special build tooling; the bootc stage is inherited through the build).
- The tag is the git-describe version (`git describe --tags --always --dirty`, leading `v` stripped, falls back to `latest`), so the image ref is `ghcr.io/snugmo/inglenook:<tag>` — e.g. `0.1.0`.
- Registry defaults to `ghcr.io/snugmo`; `./images/build.sh push` publishes to GitHub Container Registry. For local dev / CI use `DEV_REGISTRY=localhost:5000`.
- Passes `--build-arg VERSION=<tag>` and `--build-arg REVISION=$(git rev-parse HEAD)` for the `org.opencontainers.image.*` labels in the Containerfile (same convention as cote).

## Gotchas

1. **The bootc stage is mandatory**: `bootc install` only works on images with a bootc stage (the `containers.bootc` label + bootc tooling, i.e. an ostree commit as the base layer). Our base is bootc-ified and the stage persists through added layers — but don't base a stage on a non-bootc image without a `switch-to-bootc-container` step, and never override the bootc labels.
2. **Image pull access**: `bootc install` — and host-side `bootc upgrade`/`switch` — pull the image from a registry; the machine running them must have credentials for the registry.
3. **UID 1000**: the default user is `user` (UID 1000), shared with Snugmo's cote workspace images. Host volume mounts must be writable by UID 1000.
4. **Update, don't reinstall**: deployed hosts are updated with `bootc upgrade` (or `bootc switch` to change image). Re-running `bootc install` on an already-installed host is not the update path.
5. **Layer caching**: the bootc stage must stay last; do not reorder instructions above it without understanding the stage architecture.

## Adding New Components

- **New package/tool**: add it to `images/Containerfile` (respecting layer-cache ordering), rebuild, and verify the bootc labels survived (e.g. `skopeo inspect --config ghcr.io/snugmo/inglenook:<tag> | jq .config.Labels`).
- **New media** (e.g. VM image, ISO): not part of the current bootc CLI — work out an osbuild-based flow first, then add it to `images/build.sh` rather than a second `Containerfile`.

## On-Demand Reference Docs

This file holds only the context useful for *any* work in this repo. As the image matures, detailed task-specific playbooks live in `docs/` — read the matching one when doing that kind of work. Planned (to be created when needed):

- **docs/bootc.md** — the build/deploy/update flow: image build, `bootc install`, `upgrade`/`switch`/`rollback`, and the `Containerfile` stage architecture.
- **docs/adding-a-package.md** — how to add a package or binary tool to the image, including checksum verification and layer ordering.
