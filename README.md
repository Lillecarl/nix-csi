# cknix, cloud kubernetes native nix(?)
cknix implements a CSI driver that populates a volume with the result of a nix expression

## Highlevel design
We run builds in a unique CSI controller, the idea is to make the commands
pluggable here so we can run builds on another machine (or nixbuild) and populate
a cache before running builds on the nodes.

Once the controller has finished building and a pod has claimed the PVC we'll
run the same build on the node to realize the expression as a volume.

## Beware
This CSI doesn't care about how a CSI should behave regarding backing storage.
It'll happily mount two different backing areas into pods that think they are
bound to the same PVC. This is so that new pods always get the latest expression
from the expressions.knix.cool CRD.

And beware of bugs and unfinished sandwiches.

## TODO:
* Testing (no unittests and mocking bogus)
* Implement good GC on both node and controller
* Consider if the CRD should be namespaced or not or both
* Allow serving a binary cache from the controller
* Allow configuring settings easier
* Examples
* Investigate alternatives to many subprocess calls
* Implement/investigate guarantees for builds finishing on controller before going to node
* Support different Nix versions
