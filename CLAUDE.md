# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Version Control

**Always use Jujutsu (jj) instead of Git** for all version control operations in this repository.

## Project Overview

nix-csi is a Kubernetes CSI (Container Storage Interface) driver that mounts `/nix` stores into pods using ephemeral volumes. The system consists of:

1. **Node DaemonSet** - Runs on each Kubernetes node, implements the CSI driver protocol to mount Nix stores into pods
2. **Cache StatefulSet** - Central cache/coordinator that manages distributed builds and binary substitution
3. **Python Services** - Three main services packaged together:
   - `nix-csi`: CSI driver implementation (gRPC server)
   - `nix-cache`: Watches Kubernetes nodes/pods and updates the Nix machines file for distributed builds
   - `nix-timegc`: Time-based garbage collection for Nix stores

## Architecture

### Build System

The project uses Nix with flake-compatish for backwards compatibility. Key build outputs are defined in `default.nix`:

- **Environments** (`environments/`): Separate Nix environments for cache and node, built using dinix (a service manager). Each environment:
  - Shares common services (openssh, nix-daemon, shared-setup)
  - Has role-specific services defined in separate modules
  - Builds for both x86_64-linux and aarch64-linux architectures
  - Is deployed as a minimal container with services managed by dinit

- **Kubernetes Deployment** (`kubenix/`): Uses easykubenix to generate Kubernetes manifests
  - `options.nix`: Defines module options and builds separate `cachePackage` and `nodePackage`
  - `cache.nix`: Cache StatefulSet with initContainer that copies environment artifacts
  - `daemonset.nix`: Node DaemonSet with CSI driver registration
  - SSH keys from `./keys/*.pub` are automatically imported as authorized keys

### Communication Flow

**Cache → Nodes**: The cache service watches for pods labeled `app=nix-csi-node` and updates `/etc/machines` with builder DNS names (`pod.name.nix-builders.namespace.svc.cluster.local`). This enables distributed builds.

**Nodes → Cache**: Node pods use the cache as a binary substitute via `ssh-ng://nix@nix-cache?trusted=1` configured in `kubenix/config.nix`.

**CSI Protocol**: When a pod requests a volume with `storePath` or `nixExpr` or `flakeRef` in volumeAttributes, the node CSI driver:
1. Builds/fetches the requested Nix store path
2. Copies artifacts to the cache (if configured)
3. Mounts the store path into the pod using bind mounts

### Python Service Architecture

The Python services use:
- `grpclib` for async gRPC (CSI protocol implementation)
- `kr8s` for Kubernetes API interactions
- `csi-proto-python` for CSI protobuf definitions (generated from upstream spec)

All three services are packaged together in `python/` with a single `pyproject.toml`.

## Common Commands

### Building

Build and verify all environments for both architectures:
```bash
nix build --builders "eu.nixbuild.net aarch64-linux; eu.nixbuild.net x86_64-linux" --file . push --no-link
```

Build specific outputs:
```bash
nix build --file . kubenixApply.manifestJSONFile  # Kubernetes manifests
nix build --file . repoenv                         # Development environment
```

### Deployment

Deploy to Kubernetes cluster (reads SSH keys from `./keys/*.pub`):
```bash
nix run --file . kubenixEval.deploymentScript -- --yes --prune
```

Generate YAML manifests:
```bash
nix build --file . easykubenix.manifestYAMLFile
```

### Development

Enter development shell with all Python dependencies and tools:
```bash
nix-shell  # or use direnv
```

The development environment (`repoenv`) includes:
- Python with nix-csi, csi-proto-python, kr8s
- xonsh shell
- ruff, pyright (linting/type checking)
- kluctl, stern, kubectx (Kubernetes tools)
- buildah, skopeo, regctl (container tools)

### Testing

Run integration tests on a Kind cluster:
```bash
nix run --file . integrationTest
```

The integration test:
1. Verifies ctest pods are running with CSI volumes mounted
2. Checks `/nix/store` is accessible in test pods
3. Validates CSI driver registration
4. Confirms cache and node pods are operational

Integration tests run automatically in CI via `.github/workflows/integration-test.yaml`:

**Build job** (runs once, pushes to cachix and container registry):
1. Builds and pushes Lix image
2. Builds and pushes cache/node environments
3. Builds and pushes scratch image

**Test jobs** (can run in parallel, pull from caches):
- `test-kind`: Tests deployment on Kind cluster using `kubenixApply` with `local="true"`
- Future test jobs can be added for different deployment scenarios (e.g., different K8s versions, configurations)

### Python Development

The Python code is in `python/` with three packages:
- `python/nix_csi/` - CSI driver (main entry: `service.py`)
- `python/nix_cache/` - Cache manager (main entry: `cli.py`)
- `python/nix_timegc/` - Garbage collector (main entry: `cli.py`)

Version is managed in `python/pyproject.toml` and automatically imported into the Nix build.

## Key Configuration Points

### Volume Attributes

Pods request Nix stores via CSI volumeAttributes (see README for examples):
- `storePath`: Direct Nix store path to mount
- `nixExpr`: Nix expression to evaluate and mount
- `flakeRef`: Flake reference to build and mount

### Service Dependencies (dinit)

Both environments use dinit for service management with dependency chains:
- Cache: `shared-setup` → `nix-daemon` → `cache-daemon` → `cache-logger` → `cache` (umbrella)
- Node: `shared-setup` → `nix-daemon` → `csi-gc` → `csi-daemon` → `csi-logger` → `csi` (umbrella)

The `config-reconciler` service runs continuously to sync SSH keys and Nix config from mounted volumes to runtime locations.

## Important Files

- `default.nix`: Main entry point, defines all build outputs
- `environments/cache/default.nix`: Cache environment with shared + cache services
- `environments/node/default.nix`: Node environment with shared + CSI services
- `kubenix/options.nix`: Kubernetes module options and package builds
- `python/nix_csi/service.py`: CSI NodeServicer gRPC implementation
- `python/nix_cache/cli.py`: Cache service that maintains Nix machines file
- `liximage.nix`: Builds the Lix container used by initContainers
