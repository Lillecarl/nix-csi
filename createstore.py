#!/usr/bin/env python3
"""Build Nix store derivations using plumbum."""

import sys
import logging
from plumbum import local

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger("createstore")
logger.setLevel(logging.DEBUG)

substorePath = "/nix/var/cknix"

nix = local["nix"]
mkdir = local["mkdir"]
cp = local["cp"]
nix_store = local["nix-store"]
ln = local["ln"]


def realize_store(
    file: str,
    attr: str,
    root_name: str,
    hardlink: bool = True,
    reflink: bool = True,
    copy: bool = True,
) -> None | str:
    """Build and realize a Nix expression into a sub/fake store."""
    # Build the expression
    build_result = nix(
        "build",
        "--no-link",
        "--print-out-paths",
        "--file",
        file,
        attr,
        stderr=sys.stderr,
    )
    if not build_result:
        logger.error("Build failed")
        return None

    # Get the resulting storepath
    package_path = build_result.strip()
    # Extract the package name
    package_name = package_path.removeprefix("/nix/store/").removesuffix("/")

    fakeroot = f"{substorePath}/{root_name}"
    prefix = f"{fakeroot}/nix"
    package_result_path = f"{prefix}/var/result"
    # Capitalized to emphasise they're Nix environment variables
    NIX_STATE_DIR = f"{prefix}/var/nix"
    NIX_STORE_DIR = f"{prefix}/store"

    if local.path(fakeroot).is_dir():
        print(f"Package {package_name} {root_name} is already realized")
        return package_name

    # Get dependency paths
    path_info = nix("path-info", "--recursive", package_path)
    path_list = path_info.strip().splitlines()

    # Create container store structure
    mkdir("--parents", NIX_STATE_DIR)
    mkdir("--parents", NIX_STORE_DIR)

    # Copy dependencies to substore
    for path in path_list:
        if path.strip():
            pathargs = [path, NIX_STORE_DIR]
            # Overly verbose for error reportings sake
            if hardlink:
                try:
                    cp("--recursive", "--link", *pathargs)
                    continue
                except Exception as ex:
                    logger.error("Unable to hardlink")
                    logger.error(ex)
                    hardlink = False
            if reflink:
                try:
                    cp("--recursive", "--reflink=always", *pathargs)
                    continue
                except Exception:
                    logger.error("Unable to reflink")
                    reflink = False
            if copy:
                try:
                    # coreutils cp will reflink if it can
                    cp("--recursive", *pathargs)
                    continue
                except Exception:
                    logger.error("Unable to copy")
                    copy = False
            else:
                raise Exception(
                    "No configured and functional store cloning method available"
                )

    # Copy package contents to result. This is a "well-know" path
    if hardlink:
        cp("--recursive", "--link", package_path, package_result_path)
    else:
        # coreutils cp will reflink if it can
        cp("--recursive", package_path, package_result_path)

    # Create Nix database
    # Use Plumbum combinators to pipe from --dump-db to --load-db
    # We only export the paths we need from the path_list
    (
        nix_store["--dump-db", *path_list]
        | nix_store["--load-db"].with_env(USER="nobody", NIX_STATE_DIR=NIX_STATE_DIR)
    )()

    # Link result into gcroots
    cknix_roots = "/nix/var/nix/gcroots/cknix"
    mkdir("--parents", cknix_roots)
    ln("--symbolic", "--force", package_path, f"{cknix_roots}/{root_name}")

    return package_name


if __name__ == "__main__":
    realize_store(
        "/home/lillecarl/Code/nixos/repl.nix",
        "pkgs.hello.out",
        "4b6ef9dc-655f-4e63-b11c-3881281ed1d0",  # gcroots name
        True,
        True,
        True,
    )
