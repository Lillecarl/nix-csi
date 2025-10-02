# nix-csi
nix-csi implements a CSI driver that populates a volume with the result of a nix expression

AKA: A nix-snapshotter clone implemented on the CSI layer rather than the CRI layer.

## Highlevel design
nix-csi is a [CSI](https://github.com/container-storage-interface/spec)
implementation that implements ephemeral volumes consisting of a fully functional
/nix folder with store, database and everything required to run NixOS(privileged),
nixNG (unprivileged) or exactly anything else that you've packaged with Nix
in Kubernetes (or another CSI compatible scheduler/orchestrator thingy like Nomad
(PR's welcome)).

nix-csi is a glorified script runner that does the following:
* nix eval
* nix build
* nix path-info (get full closure)
* rsync (hardlinkgs)
* mount

The mount calls will be either bind or overlayfs depending on if you're mounting
RO or RW. The benefit of hardlinks and bind-mounts is that inodes are shared all
the way meaning that your processes share page-cache for applications resulting
in lower memory usage than running normal docker images.

OverlayFS gives similar storage savings but without page-cache sharing.

## Beware
And beware of bugs and unfinished sandwiches.

## TODO:
* Testing (no unittests and mocking bogus)
* Implement some kind of central binary cache
* Examples
* Support different Nix versions
