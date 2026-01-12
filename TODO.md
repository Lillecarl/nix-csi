# TODO

## Volume subpathing
Make /nix a subPath of the CSI volume instead of "hiding" it. This
will allow mounting storePaths to the filesystem really easily without
activationScripts and shit.

## Better SSH key management
* Split server and client configuration
* SSH certificates?
* Use pregenerated ssh-keys for in-cluster configuration 

## Support Nix signing
* Implement signing all paths in the cache (when?)

## Improve GC
* Copy entire CSI stores to cache on an interval (Keep paths cache alive)
* Rewrite timegc to query dead paths before querying DB for regtime

## Building
* Wrap distributed building in a nicer "package"
* Better substitution configuration
* Implement speed factor

## Controller
* Rename cache to controller, integrate Kopf for additional future features.
