import asyncio
import kr8s
import logging
import os
import re
import shutil
import socket
import tempfile

from .copytocache import copyToCache
from .identityservicer import IdentityServicer
from .subprocessing import run_captured, run_console, try_captured, try_console
from asyncio import Semaphore
from collections import defaultdict
from collections.abc import Mapping, Sequence
from csi import csi_grpc, csi_pb2
from grpclib import GRPCError
from grpclib.const import Status
from grpclib.server import Server
from importlib import metadata
from kr8s.asyncio.objects import Pod
from pathlib import Path
from typing import Any, Iterator

logger = logging.getLogger("nix-csi")

CSI_PLUGIN_NAME = "nix.csi.store"
CSI_VENDOR_VERSION = metadata.version("nix-csi")

# Exit code from mount command when target is already mounted
MOUNT_ALREADY_MOUNTED = 32

# Paths we base everything on.
# Remember that these are CSI pod paths not node paths.
NIX_ROOT = Path("/")
CSI_ROOT = NIX_ROOT / "nix/var/nix-csi"
CSI_VOLUMES = CSI_ROOT / "volumes"
CSI_GCROOTS = NIX_ROOT / "nix/var/nix/gcroots/nix-csi"

# Configurable via kubenix option: rsyncConcurrency (default: 1)
# Set via RSYNC_CONCURRENCY environment variable
RSYNC_CONCURRENCY = Semaphore(max(int(os.environ.get("RSYNC_CONCURRENCY", "1")), 1))

# Configurable via kubenix option: nodeBuildTimeout (default: 300)
# Set via NIX_BUILD_TIMEOUT environment variable
NIX_BUILD_TIMEOUT = float(os.environ.get("NIX_BUILD_TIMEOUT", "300"))

# Builder configuration
# Set via environment variables from kubenix when builders are enabled
BUILDERS_ENABLED = os.environ.get("BUILDERS_ENABLED", "false").lower() == "true"

NAMESPACE = os.environ.get("KUBE_NAMESPACE", "nix-csi")
BUILDERS_SERVICE = "nix-csi-builders"

# Nix base32 excludes: e, o, t, u
STORE_PATH_RE = re.compile(r"/nix/store/[0-9a-df-np-sv-z]{32}-[^\s/]+")


def extract_store_paths(value: Any) -> Iterator[Path]:
    match value:
        case str():
            for match in STORE_PATH_RE.findall(value):
                yield Path(match)
        case Mapping():
            for v in value.values():
                yield from extract_store_paths(v)
        case Sequence():
            for item in value:
                yield from extract_store_paths(item)


def extract_store_name(value: Path | str) -> str:
    return str(value).removeprefix("/nix/store/")


async def get_current_system():
    """Get system string evaluated by nix"""
    return (
        await try_captured(
            "nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem"
        )
    ).stdout


async def get_builder_uris():
    """Query k8s API for builder pods, return list of SSH URIs for --builders flag."""
    if not BUILDERS_ENABLED:
        return []

    try:
        # Use kr8s to query pods with label selector
        # kr8s.asyncio.get() returns an async generator, iterate with async for
        uris = []
        async for pod in kr8s.asyncio.get(
            "pods", namespace=NAMESPACE, label_selector="app.kubernetes.io/name=builder"
        ):
            if pod.status.phase == "Running":
                pod_name = pod.metadata.name
                uri = f"ssh://nix@{pod_name}.{BUILDERS_SERVICE}.{NAMESPACE}.svc.cluster.local"
                uris.append(uri)

        logger.debug(f"Discovered {len(uris)} builder pods: {uris}")
        return uris
    except Exception as e:
        logger.warning(f"Failed to discover builder pods: {e}")
        return []


class NodeServicer(csi_grpc.NodeBase):
    volumeLocks: defaultdict[str, Semaphore] = defaultdict(Semaphore)

    def __init__(self, system: str):
        self.system = system

    async def NodePublishVolume(self, stream):
        request: csi_pb2.NodePublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodePublishVolumeRequest is None")

        logger.info(f"Publish {request.target_path}")

        async with self.volumeLocks[request.volume_id]:
            targetPath = Path(request.target_path)
            storePath = request.volume_context.get(self.system, None)
            flakeRef = request.volume_context.get("flakeRef", None)
            nixExpr = request.volume_context.get("nixExpr", None)

            # Using sentinel path instead of None to avoid Optional type and None checks everywhere.
            # The if/elif blocks below should set this to a real path; the exists() check at line ~157
            # will fail if none of the branches executed (sentinel path doesn't exist).
            primaryPackagePath: Path = Path("/nonexistent/path/that/should/never/exist")
            gcRoot = CSI_GCROOTS / request.volume_id

            extraArgs = []

            # Discover builder pods when builders are enabled
            # CSI pods run with --max-jobs 0 to delegate all builds to builder pods
            builder_uris = await get_builder_uris()
            if builder_uris:
                extraArgs.extend(["--max-jobs", "0"])
                for uri in builder_uris:
                    extraArgs.extend(["--builders", uri])
                extraArgs.append("--builders-use-substitutes")
                logger.info(f"Using {len(builder_uris)} builder pods for builds")

            # Simple string check is fine - value controlled by easykubenix (always "true" or "false")
            if os.environ.get("CACHE_ENABLED", "false") == "true":
                try:
                    logger.debug("Trying to connect to cache")
                    await asyncio.wait_for(
                        try_console("ssh", "nix@nix-cache", "--", "true"),
                        timeout=2.0,
                    )
                    extraArgs.extend(
                        [
                            "--extra-substituters",
                            "ssh-ng://nix@nix-cache?trusted=1&priority=20",
                        ]
                    )
                    logger.debug("Cache connectivity check succeeded")
                except (GRPCError, OSError, asyncio.TimeoutError):
                    logger.warning("Cache connectivity check failed")

            podName = request.volume_context.get("csi.storage.k8s.io/pod.name", None)
            podNamespace = request.volume_context.get(
                "csi.storage.k8s.io/pod.namespace", None
            )
            podUid = request.volume_context.get("csi.storage.k8s.io/pod.uid", None)

            packagePaths = []
            if podName and podNamespace and podUid:
                pod = await Pod.get(podName, podNamespace)
                if pod.metadata.uid != podUid:
                    raise GRPCError(Status.INTERNAL, "poduid doesn't match")

                pod = set(extract_store_paths(pod.raw))
                for packagePath in pod:
                    logger.debug(f"{packagePath=}")
                    async with self.volumeLocks[str(packagePath)]:
                        name = extract_store_name(packagePath)
                        logger.debug(f"{name=}")
                        result = await try_console(
                            "nix",
                            "build",
                            *extraArgs,
                            "--print-out-paths",
                            "--out-link",
                            gcRoot / name,
                            packagePath,
                            timeout=NIX_BUILD_TIMEOUT,
                        )
                        packagePaths.append(Path(result.stdout.splitlines()[0]))

            if packagePaths:
                logger.debug(f"Extracted packages {packagePaths=}")

            # Source selection order (intentional, documented in README):
            # 1. storePath - if present, use directly
            # 2. flakeRef - if storePath not present, build flake
            # 3. nixExpr - if neither above present, evaluate expression
            # Users can specify multiple; first non-None in priority order is used.
            if storePath is not None:
                async with self.volumeLocks[storePath]:
                    logger.debug(f"{storePath=}")
                    name = extract_store_name(storePath)
                    result = await try_console(
                        "nix",
                        "build",
                        *extraArgs,
                        "--print-out-paths",
                        "--out-link",
                        gcRoot / name,
                        storePath,
                        timeout=NIX_BUILD_TIMEOUT,
                    )
                    packagePaths.append(Path(result.stdout.splitlines()[0]))
                    if not primaryPackagePath.exists():
                        primaryPackagePath = Path(result.stdout.splitlines()[0])

            if flakeRef is not None:
                async with self.volumeLocks[flakeRef]:
                    logger.debug(f"{flakeRef=}")

                    # Fetch storePath from caches
                    result = await try_console(
                        "nix",
                        "build",
                        *extraArgs,
                        "--print-out-paths",
                        "--out-link",
                        gcRoot / "flake",
                        flakeRef,
                        timeout=NIX_BUILD_TIMEOUT,
                    )
                    packagePaths.append(Path(result.stdout.splitlines()[0]))
                    if not primaryPackagePath.exists():
                        primaryPackagePath = Path(result.stdout.splitlines()[0])

            if nixExpr is not None:
                async with self.volumeLocks[nixExpr]:
                    logger.debug(f"{nixExpr=}")
                    with tempfile.NamedTemporaryFile(mode="w", suffix=".nix") as tmp:
                        tmp.write(nixExpr)
                        tmp.flush()

                        # Fetch storePath from caches
                        result = await try_console(
                            "nix",
                            "build",
                            *extraArgs,
                            "--print-out-paths",
                            "--out-link",
                            gcRoot / "expr",
                            "--file",
                            tmp.name,
                            timeout=NIX_BUILD_TIMEOUT,
                        )
                        packagePaths.append(Path(result.stdout.splitlines()[0]))
                        if not primaryPackagePath.exists():
                            primaryPackagePath = Path(result.stdout.splitlines()[0])

            if not primaryPackagePath.exists() and not packagePaths:
                logger.error("packagePath doesn't exist after building")
                raise GRPCError(
                    Status.INVALID_ARGUMENT,
                    "packagePath turned out invalid",
                )

            # Root directory for volume. Contains /nix, also contains "workdir" and
            # "upperdir" if we're doing overlayfs
            volumeRoot = CSI_VOLUMES / request.volume_id
            # Capitalized to emphasise they're Nix environment variables
            NIX_STATE_DIR = volumeRoot / "nix/var/nix"
            # Create NIX_STATE_DIR where database will be initialized
            NIX_STATE_DIR.mkdir(parents=True, exist_ok=True)

            # Get storepaths from all packages
            storePaths = (
                await try_captured(
                    "nix",
                    "path-info",
                    "--recursive",
                    *packagePaths,
                )
            ).stdout.splitlines()

            try:
                # This try block is essentially nix copy into a chroot store with
                # extra steps. (Hardlinking instead of dumbcopying)

                # Install CSI gcroots
                for packagePath in packagePaths:
                    name = extract_store_name(packagePath)
                    await try_captured(
                        "nix",
                        "build",
                        "--out-link",
                        gcRoot / name,
                        packagePath,
                        timeout=NIX_BUILD_TIMEOUT,
                    )

                # Copy closure to substore, rsync saves a lot of implementation
                # headache here. --archive keeps all attributes, --hard-links
                # hardlinks everything hardlinkable.
                async with RSYNC_CONCURRENCY:
                    await try_captured(
                        "rsync",
                        "--one-file-system",
                        "--recursive",
                        "--links",
                        "--hard-links",
                        "--mkpath",
                        *storePaths,
                        volumeRoot / "nix/store",
                    )

                # Create Nix database
                # This is a bash script that runs nix-store --dump-db | NIX_STATE_DIR=something nix-store --load-db
                await try_captured(
                    "nix_init_db",
                    NIX_STATE_DIR,
                    *storePaths,
                )

                # install gcroots in container using chroot, store this is
                # required because the auto roots created for /nix/var/result
                # will point to Narnia while this one points into store.
                for packagePath in packagePaths:
                    name = extract_store_name(packagePath)
                    await try_captured(
                        "nix",
                        "build",
                        "--store",
                        volumeRoot,
                        "--out-link",
                        NIX_STATE_DIR / f"gcroots/{name}",
                        packagePath,
                    )

                # install /nix/var/result in container using chroot store
                if primaryPackagePath.exists():
                    await try_captured(
                        "nix",
                        "build",
                        "--store",
                        volumeRoot,
                        "--out-link",
                        volumeRoot / "nix/var/result",
                        primaryPackagePath,
                    )
            except Exception:
                logger.exception("Failed to build volume")
                # Remove gcroots if we failed something else
                shutil.rmtree(gcRoot, ignore_errors=True)
                # Remove what we were working on
                shutil.rmtree(volumeRoot, True)
                raise

            targetPath.mkdir(parents=True, exist_ok=True)
            mountCommand = []
            if request.readonly:
                # For readonly we use a bind mount, the benefit is that different
                # container stores using bindmounts will get the same inodes and
                # share page cache with others, reducing memory usage.
                mountCommand = [
                    "mount",
                    "--verbose",
                    "--bind",
                    "-o",
                    "ro",
                    volumeRoot,
                    targetPath,
                ]
            else:
                # For readwrite we use an overlayfs mount, the benefit here is that
                # it works as CoW even if the underlying filesystem doesn't support
                # it, reducing host storage usage.
                workdir = volumeRoot / "workdir"
                upperdir = volumeRoot / "upperdir"
                workdir.mkdir(parents=True, exist_ok=True)
                upperdir.mkdir(parents=True, exist_ok=True)
                mountCommand = [
                    "mount",
                    "--verbose",
                    "-t",
                    "overlay",
                    "overlay",
                    "-o",
                    f"rw,lowerdir={volumeRoot},upperdir={upperdir},workdir={workdir}",
                    targetPath,
                ]

            mount = await run_console(*mountCommand)
            if mount.returncode == MOUNT_ALREADY_MOUNTED:
                logger.debug(f"Mount target {targetPath} was already mounted")
            elif mount.returncode != 0:
                # Clean up resources on mount failure
                shutil.rmtree(gcRoot, ignore_errors=True)
                shutil.rmtree(volumeRoot, ignore_errors=True)
                raise GRPCError(
                    Status.INTERNAL,
                    f"Failed to mount {mount.returncode=} {mount.stderr=}",
                )

            reply = csi_pb2.NodePublishVolumeResponse()
            await stream.send_message(reply)

            # Rework this horrible cache bullshit
            if primaryPackagePath.exists():
                task = asyncio.create_task(copyToCache(primaryPackagePath))
                task.add_done_callback(
                    lambda t: logger.error(f"copyToCache failed: {t.exception()}")
                    if t.exception()
                    else None
                )

    @staticmethod
    async def IsMount(path: Path):
        return (await run_captured("findmnt", "--mountpoint", path)).returncode == 0

    @staticmethod
    async def Unmount(path: Path):
        return await run_captured("umount", "--verbose", path)

    async def NodeUnpublishVolume(self, stream):
        request: csi_pb2.NodeUnpublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeUnpublishVolumeRequest is None")

        logger.info(f"Unpublish {request.target_path}")

        async with self.volumeLocks[request.volume_id]:
            targetPath = Path(request.target_path)

            # Cleanup operations are intentionally fail-fast (not wrapped in individual try/except).
            # Kubelet will retry NodeUnpublishVolume indefinitely on failure, so we want to
            # stop at the first error and let the retry start from scratch. This is safer than
            # attempting partial cleanup, as each retry re-attempts all steps in order.

            # Unmount
            if await NodeServicer.IsMount(targetPath):
                umount = await NodeServicer.Unmount(targetPath)
                if umount.returncode != 0 and await NodeServicer.IsMount(targetPath):
                    raise GRPCError(
                        Status.INTERNAL, "unmount failed", f"{umount.combined=}"
                    )
                else:
                    logger.debug(f"unmounted {request.target_path=}")

            # Remove mount dir
            if targetPath.exists():
                try:
                    targetPath.rmdir()
                    logger.debug(f"removed {targetPath=}")
                except Exception as ex:
                    raise GRPCError(
                        Status.INTERNAL, f"removing {targetPath=} failed", ex
                    )

            # Remove gcroots
            gcRoot = CSI_GCROOTS / request.volume_id
            if gcRoot.exists():
                try:
                    shutil.rmtree(gcRoot, ignore_errors=True)
                    logger.debug(f"unlinked {gcRoot=}")
                except Exception as ex:
                    raise GRPCError(
                        Status.INTERNAL, f"unlinking {targetPath=} failed", ex
                    )

            # Remove hardlink farm
            volumePath = CSI_VOLUMES / request.volume_id
            if volumePath.exists():
                try:
                    shutil.rmtree(volumePath)
                    logger.debug(f"removed {volumePath=}")
                except Exception as ex:
                    raise GRPCError(
                        Status.INTERNAL, f"recursive removing {targetPath=} failed", ex
                    )

            reply = csi_pb2.NodeUnpublishVolumeResponse()
            await stream.send_message(reply)

    async def NodeGetCapabilities(self, stream):
        request: csi_pb2.NodeGetCapabilitiesRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetCapabilitiesRequest is None")
        reply = csi_pb2.NodeGetCapabilitiesResponse(capabilities=[])
        await stream.send_message(reply)

    async def NodeGetInfo(self, stream):
        request: csi_pb2.NodeGetInfoRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetInfoRequest is None")
        node_name = os.environ.get("KUBE_NODE_NAME")
        if not node_name:
            raise GRPCError(
                Status.FAILED_PRECONDITION,
                "KUBE_NODE_NAME environment variable not set",
            )
        reply = csi_pb2.NodeGetInfoResponse(node_id=node_name)
        await stream.send_message(reply)

    async def NodeGetVolumeStats(self, _stream):
        raise GRPCError(Status.UNIMPLEMENTED, "NodeGetVolumeStats not implemented")

    async def NodeExpandVolume(self, _stream):
        raise GRPCError(Status.UNIMPLEMENTED, "NodeExpandVolume not implemented")

    async def NodeStageVolume(self, _stream):
        raise GRPCError(Status.UNIMPLEMENTED, "NodeStageVolume not implemented")

    async def NodeUnstageVolume(self, _stream):
        raise GRPCError(Status.UNIMPLEMENTED, "NodeUnstageVolume not implemented")


async def serve():
    sock_path = "/csi/csi.sock"
    Path(sock_path).unlink(missing_ok=True)

    identityServicer = IdentityServicer()
    nodeServicer = NodeServicer(await get_current_system())

    server = Server(
        [
            identityServicer,
            nodeServicer,
        ]
    )

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.bind(sock_path)
        sock.listen(128)
        # setblocking(False) is redundant - async IO handles this

        await server.start(sock=sock)
        logger.info(f"CSI driver (grpclib) listening on unix://{sock_path}")
        await server.wait_closed()
    except Exception:
        sock.close()
        Path(sock_path).unlink(missing_ok=True)
        raise
