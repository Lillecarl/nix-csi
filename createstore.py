#!/usr/bin/env python3
"""Build Nix store derivations using plumbum."""

import asyncio
import logging
from cknix_csi.cknix import realize_store

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)

if __name__ == "__main__":
    asyncio.run(
        realize_store(
            """
            (import /home/lillecarl/Code/nixos/repl.nix).pkgs.hello.out
        """,
            "4b6ef9dc-655f-4e63-b11c-3881281ed1d0",  # gcroots name
        )
    )
