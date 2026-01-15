import logging
from collections import defaultdict
from pathlib import Path
from asyncio import Semaphore, sleep
from .subprocessing import run_captured, run_console

logger = logging.getLogger("nix-csi")

# Locks that prevent the same derivation to be uploaded in parallel
copyLock: defaultdict[Path, Semaphore] = defaultdict(Semaphore)


async def copyToCache(packagePath: Path):
    # TODO: Rewrite this entire copy process to support user-supplied copy scripts.
    # This will allow end-users to copy to arbitrary destinations (S3, GCS, custom caches, etc.)
    # rather than hard-coding ssh-ng://nix@nix-cache.
    #
    # TODO: Building should be moved to separate builder pods rather than happening
    # within the CSI daemonset. The daemonset should only handle mounting pre-built paths.
    # This will improve separation of concerns and allow dedicated builder infrastructure.

    # Only run one copy per path per time
    async with copyLock[packagePath]:
        paths = [str(packagePath)]
        # Try to get derivation paths recursively. This may fail if we only have
        # store paths without .drv files (e.g., fetched from substituters), which is normal.
        pathInfoDrv = await run_captured(
            "nix",
            "path-info",
            "--recursive",
            "--derivation",
            packagePath,
        )
        if pathInfoDrv.returncode == 0:
            paths += pathInfoDrv.stdout.splitlines()
        else:
            logger.debug(
                f"No derivation paths found for {packagePath} (normal if fetched from substituters)"
            )

        # Filter out .drv files and deduplicate (path-info runs return overlapping results)
        # Set comprehension {x for x in ...} creates a set with unique values
        paths = {p for p in paths if not p.endswith(".drv")}

        if len(paths) > 0:
            for attempt in range(6):
                if attempt > 0:
                    exp_backoff = min(5 * (2 ** (attempt - 1)), 60)
                    logger.warning(
                        f"Retry {attempt}/6 copying to cache after {exp_backoff}s: {packagePath}"
                    )
                    await sleep(exp_backoff)

                nixCopy = await run_captured(
                    "nix", "copy", "--to", "ssh-ng://nix@nix-cache", *paths
                )
                if nixCopy.returncode == 0:
                    logger.debug(f"Successfully copied to cache: {packagePath}")
                    break
            else:
                logger.error(f"Failed to copy to cache after 6 attempts: {packagePath}")
