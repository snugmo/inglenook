# AGENTS.md — Inglenook Bootc Image Agent Configuration

> **Status: pre-build.** This repo currently holds only `LICENSE`. The structure
> and conventions below are the plan for building the image — update this file
> as the plan becomes reality (remove this note once `Containerfile` exists).

## Project Overview

**inglenook** — a Fedora-based bootable OS image built with [bootc](https://github.com/containers/ostree-rs-ext) (bootable containers), from the [Snugmo](https://github.com/snugmo) GitHub org. The image is defined by a `Containerfile` based on Fedora, built into an OCI image with `bootc build`, and is either installed directly on a host (`bootc init` → `bootc install`) or prepared as VM/ISO media (`bootc image-prepare`).

## Structure

Planted layout, to be created as work begins:

```
Containerfile    # The OS image: Fedora base + packages + host configuration
build.sh         # buildah/bootc wrapper with registry/tag config
docs/            # On-demand reference docs — read when relevant (see below)
```

## Essential Commands

| Task                                | Command                                                             |
| ----------------------------------- | ------------------------------------------------------------------- |
| Build bootc OCI image               | `bootc build`                                                       |
| Build + push to ghcr                | `./build.sh push` (once `build.sh` exists)                          |
| Prepare QEMU VM image               | `bootc image-prepare --type qemu --image ghcr.io/snugmo/inglenook:<tag>` |
| Prepare bootable ISO                | `bootc image-prepare --type iso --image ghcr.io/snugmo/inglenook:<tag>` |
| Inspect a deployed host             | `bootc status` (on the host)                                        |
| Update a deployed host              | `bootc upgrade` (on the host)                                       |

## Key Conventions

### Commit Conventions

- Make small, logically contained commits; one per meaningful change, committed as you go.
- Prefix every commit subject with a single emoji representing the change, followed by the conventional type prefix used in this repo (`feat:`, `chore:`, `docs:`, `fix:`, `refactor:`, …); keep subjects under 72 characters. Use `feat:` when the change adds a new capability to the image (a new package, tool, or service), and `chore:` for maintenance such as version bumps and internal adjustments. Examples: `✨ feat: add Rust toolchain to OS image`, `📦 chore: update Fedora base from 44 to 45`, `✏️ docs: …`, `🐛 fix: …`.
- End commit messages with an `Assisted-by: <agent>:<model>` trailer, where `<agent>` is the coding agent doing the committing (no "generated with" line).

### OS Image (`Containerfile`)

- Based on **Fedora** (`registry.fedoraproject.org/fedora:44`, matching cote's base; confirm at build time), not UBI; runs as non-root user `user` (UID 1000).
- **Must contain a bootc stage** (via `switch-to-bootc-container`) as the final stage — without it the result is an ordinary container, not an installable OS image.
- All binary downloads are verified as far as possible (SHA-256 `ADD --checksum=…`, cosign signatures, or SLSA provenance).
- Order instructions least-to-most frequently changing; package installs before configuration, to maximize layer reuse.

### Build Script (`build.sh`)

- Uses `bootc`/`buildah` (not `docker`) — rootless, works in CI without a Docker daemon.
- The tag is the git-describe version (`git describe --tags --always --dirty`, leading `v` stripped, falls back to `latest`), so the image ref is `ghcr.io/snugmo/inglenook:<tag>` — e.g. `0.1.0`.
- Registry defaults to `ghcr.io/snugmo`; `./build.sh push` publishes to GitHub Container Registry. For local dev / CI use `DEV_REGISTRY=localhost:5000`.

## Gotchas

1. **The bootc stage is mandatory**: `bootc install` and `bootc image-prepare` only work on images with a bootc stage (final `FROM` + `switch-to-bootc-container`). A plain `podman build` of this `Containerfile` will *not* produce an installable image.
2. **Image pull access**: `bootc image-prepare` and `bootc install` pull the image from a registry; the machine running them must have credentials for the registry.
3. **UID 1000**: the default user is `user` (UID 1000), shared with Snugmo's cote workspace images. Host volume mounts must be writable by UID 1000.
4. **Update, don't reinstall**: deployed hosts are updated with `bootc upgrade` (or `bootc switch` to change image). Re-running `bootc install` on an already-installed host is not the update path.
5. **Layer caching**: the bootc stage must stay last; do not reorder instructions above it without understanding the stage architecture.

## Adding New Components

- **New package/tool**: add it to the `Containerfile` above the bootc stage (respecting layer-cache ordering), rebuild, and verify the image still passes `bootc image-prepare`.
- **New media type** (e.g. raw disk, different arch): add a `bootc image-prepare --type …` invocation to `build.sh` rather than a second `Containerfile`.

## On-Demand Reference Docs

This file holds only the context useful for *any* work in this repo. As the image matures, detailed task-specific playbooks live in `docs/` — read the matching one when doing that kind of work. Planned (to be created when needed):

- **docs/bootc.md** — the build/deploy/update flow: `bootc build`, `image-prepare` media types, `install`, `upgrade`, and the `Containerfile` stage architecture.
- **docs/adding-a-package.md** — how to add a package or binary tool to the image, including checksum verification and layer ordering.
