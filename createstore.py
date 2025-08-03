#!/usr/bin/env python3
"""Build Nix store derivations using plumbum."""

import logging
from plumbum import local

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger("plumbum.local")
logger.setLevel(logging.DEBUG)

substorePath = "/nix/var/cknix"

nix = local["nix"]
mkdir = local["mkdir"]
cp = local["cp"]
jq = local["jq"]
head = local["head"]
nix_store = local["nix-store"]


def realize_store(file: str, attr: str) -> None | str:
    """Build and realize a Nix expression into the substore."""
    # Build the expression
    build_result = nix("build", "--no-link", "--print-out-paths", "--file", file, attr)
    if not build_result:
        return None

    package_path = build_result.strip()
    package_name = package_path.removeprefix("/nix/store/").removesuffix("/")
    package_ref_path = f"{substorePath}/{package_name}"
    package_result_path = f"{package_ref_path}/nix/var/result"
    PREFIX = f"{package_ref_path}/nix"
    NIX_STATE_DIR = f"{PREFIX}/var/nix"

    if local.path(package_ref_path).is_dir():
        print(f"Package {package_name} is already realized")
        return package_name

    # Get dependency paths
    path_info = nix("path-info", "--recursive", package_path)
    path_list = path_info.strip().splitlines()

    # Create container store structure
    mkdir("--parents", package_ref_path)
    mkdir("--parents", NIX_STATE_DIR)
    # Create Nix database
    mkdir("--parents", f"{NIX_STATE_DIR}/db")
    # Use Plumbum combinators to pipe from --dump-db to --load-db
    # We only export the paths we need with a path_list
    (
        nix_store["--dump-db", *path_list]
        | nix_store["--load-db"].with_env(USER="nobody", NIX_STATE_DIR=NIX_STATE_DIR)
    )()

    hardlink: bool = True
    reflink: bool = True
    # Copy dependencies to substore
    for path in path_list:
        if path.strip():
            pathargs = [f"{path}/.", f"{package_ref_path}/."]
            if hardlink:
                try:
                    cp("--recursive", "--link", *pathargs)
                except Exception:
                    print("Unable to hardlink")
                    hardlink = False
            elif reflink:
                try:
                    cp("--recursive", "--reflink=always", *pathargs)
                except Exception:
                    print("Unable to reflink")
                    reflink = False
            else:
                try:
                    cp("--recursive", *pathargs)
                except Exception:
                    print("Unable to copy")
                    reflink = False

    # Copy package contents to result
    if hardlink:
        cp("--recursive", "--link", f"{package_path}/.", f"{package_result_path}/")
    else:
        cp("--recursive", f"{package_path}/.", f"{package_result_path}/")

    return package_name


if __name__ == "__main__":
    realize_store("/home/lillecarl/Code/nixos/repl.nix", "pkgs.hello")
