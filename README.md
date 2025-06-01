# knix, Nix in Kubernetes
knix implements a CSI driver that populates a volume with the result of a nix expression

## Highlevel design
We run builds in a unique CSI controller, the idea is to make the commands
pluggable here so we can run builds on another machine (or nixbuild) and populate
a cache before running builds on the nodes.

Once the controller has finished building and a pod has claimed the PVC we'll
run the same build on the node to realize the expression as a volume.

## TODO:
* Testing (no unittests and mocking bogus)
* Implement a good GC
* Consider if the CRD should be namespaced or not or both
* Consider what happens when the CRD changes, the volume will stay the same.
