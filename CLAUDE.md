# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

cknix is a Kubernetes CSI (Container Storage Interface) driver that populates volumes with the result of Nix expressions. It allows Kubernetes pods to mount volumes containing the output of Nix builds, enabling declarative package management within Kubernetes workloads.

## Architecture

The system consists of:
- **CSI Controller**: Runs builds in a centralized controller for caching and coordination
- **CSI Node Driver**: Realizes expressions as volumes on individual nodes
- **Custom Resource Definition (CRD)**: `expressions.cknix.cool` defines Nix expressions to be built
- **Python CSI Implementation**: Uses kopf for Kubernetes operator functionality and grpclib for CSI protocol

## Build System

This project uses **Nix exclusively** for dependency management and building. There is no traditional Python package management (pip, poetry, etc.).

### Common Commands

```bash
# Enter development environment
nix develop

# Build the CSI driver package
nix build .#cknix-csi

# Build the container image
nix build .#nix2containerImage

# Build all packages
nix build .#repoenv

# Load container image (if using Docker/Podman)
nix build .#nix2containerImage && docker load < result

# Run the CSI driver locally
nix run .#cknix-csi -- --help

# Prefer using "nix command" rather than nix-commands
```

### Package Structure

- `flake.nix`: Main Nix flake with all package definitions and Python dependencies
- `nix/pkgs/cknix-csi.nix`: Python package definition for the CSI driver
- `nix/pkgs/`: Custom Nix packages (certbuilder, aiopath, csi-proto-python, etc.)
- `cknix_csi/`: Python source code for the CSI driver
  - `cknix.py`: Main CSI driver implementation with gRPC services
  - `helpers.py`: Build utilities and helper functions
  - `cli.py`: Command-line interface

### Dependencies

Key Python packages managed through Nix:
- `kopf`: Kubernetes operator framework
- `grpclib`: gRPC library for CSI protocol
- `csi-proto-python`: CSI protocol definitions
- `aiopath`: Async filesystem operations
- `aiosqlite`: Async SQLite database operations

## Kubernetes Integration

### Custom Resources

The driver uses a CRD `expressions.cknix.cool` with:
- `spec.data.expr`: The Nix expression to evaluate
- `status.phase`: Current build phase (Pending, Running, Succeeded, Failed)
- `status.result`: Store path of the built expression
- `status.gcRoots`: GC root management for built packages

### Deployment

YAML manifests in `yaml/`:
- `crd.yaml`: Custom resource definition
- `deployment.yaml`: CSI controller deployment
- `daemonset.yaml`: CSI node driver daemonset
- `csidaemonset.yaml`: Additional CSI daemon configuration

### Testing

Test configurations in `yaml/test/`:
- `expression.yaml`: Sample expression CRD
- `ubuntu.yaml`: Ubuntu-based test pod
- `pv.yaml`: Persistent volume test

## Key Implementation Details

### Volume Lifecycle

1. Controller receives Expression CRD and builds Nix expression
2. Node driver realizes the same expression locally when pod is scheduled
3. Volume is mounted with the built packages available to the pod
4. GC roots are managed to prevent premature garbage collection

### Storage Behavior

The CSI driver intentionally deviates from standard CSI behavior:
- Multiple pods can mount "different" volumes from the same PVC
- Each mount gets the latest expression result from the CRD
- No traditional backing storage - volumes are ephemeral Nix store paths

## Development Notes

- All Python dependencies must be defined in `flake.nix`
- Container images are built using `nix2container` for optimal layering
- The driver requires `KUBE_NODE_NAME` environment variable
- Builds are executed via subprocess calls to `nix build`
- Uses async/await patterns throughout for non-blocking operations

## Nix Flakes Approach

- Try not using flakes directly
- Use flake-compat to expose an attrset identical to flakes from default.nix
- This approach avoids copying all source code to the Nix store while maintaining flake-like functionality