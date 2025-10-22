import asyncio
import logging
import os
import shlex
import shutil
import socket
import tempfile
import time

from csi import csi_grpc, csi_pb2
from google.protobuf.wrappers_pb2 import BoolValue
from grpclib.const import Status
from grpclib.exceptions import GRPCError
from grpclib.server import Server
from hashlib import sha256
from importlib import metadata
from pathlib import Path
from typing import Any, NamedTuple, Optional, List
from cachetools import TTLCache
from asyncio import Semaphore
from collections import defaultdict
from . import runbuild

logger = logging.getLogger("nix-csi")

CSI_PLUGIN_NAME = "nix.csi.store"
CSI_VENDOR_VERSION = metadata.version("nix-csi")

MOUNT_ALREADY_MOUNTED = 32

# Paths we base everything on. Remember that these are CSI pod paths not node paths.
CSI_ROOT = Path("/nix/var/nix-csi")
CSI_VOLUMES = CSI_ROOT / "volumes"
NIX_GCROOTS = Path("/nix/var/nix/gcroots/nix-csi")
NAMESPACE = os.environ["KUBE_NAMESPACE"]

RSYNC_CONCURRENCY = Semaphore(1)

class NixCsiError(GRPCError):
    def __init__(
        self,
        status: Status,
        message: Optional[str] = None,
        details: Any = None,
    ) -> None:
        logger.error(message)
        super().__init__(status, message, details)
        self.status = status
        self.message = message
        self.details = details


def get_kernel_boot_time(stat_file: Path = Path("/proc/stat")) -> int:
    """Returns kernel boot time as Unix timestamp."""
    for line in stat_file.read_text().splitlines():
        if line.startswith("btime "):
            return int(line.split()[1].strip())
    raise RuntimeError("btime not found in /hoststat")


def reboot_cleanup():
    """Cleanup volume trees and gcroots if we have rebooted"""
    stat_file = Path("/proc/stat")
    state_file = CSI_ROOT / "proc_stat"

    needs_cleanup = False
    if state_file.exists():
        try:
            old_boot = get_kernel_boot_time(state_file)
            current_boot = get_kernel_boot_time(stat_file)
            needs_cleanup = old_boot != current_boot
        except RuntimeError:
            # Corrupted state file, treat as needing cleanup
            needs_cleanup = True

    shutil.copy2(stat_file, state_file)

    if needs_cleanup:
        logger.info("Reboot detected - cleaning volumes and gcroots")
        for path in [CSI_VOLUMES, NIX_GCROOTS]:
            if path.exists():
                shutil.rmtree(path)
                path.mkdir(parents=True, exist_ok=True)


def log_command(*args, log_level: int):
    logger.log(
        log_level,
        f"Running command: {shlex.join([str(arg) for arg in args])}",
    )


class SubprocessResult(NamedTuple):
    returncode: int
    stdout: str
    stderr: str
    combined: str
    elapsed: float


# Run async subprocess, capture output and returncode
async def run_captured(*args):
    return await run_console(*args, log_level=logging.NOTSET)


# Run async subprocess, forward output to console and return returncode
async def run_console(*args, log_level: int = logging.DEBUG):
    start_time = time.perf_counter()
    log_command(*args, log_level=log_level)
    proc = await asyncio.create_subprocess_exec(
        *[str(arg) for arg in args],
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    stdout_data = []
    stderr_data = []
    combined_data = []

    async def stream_output(stream, buffer):
        async for line in stream:
            decoded = line.decode().strip()
            buffer.append(decoded)
            combined_data.append(decoded)
            logger.log(log_level, decoded)

    await asyncio.gather(
        stream_output(proc.stdout, stdout_data),
        stream_output(proc.stderr, stderr_data),
        proc.wait(),
    )
    elapsed_time = time.perf_counter() - start_time
    if elapsed_time > 5:
        logger.info(
            f"Comamnd executed in {elapsed_time} seconds: {shlex.join([str(arg) for arg in args[:5]])}"
        )

    assert proc.returncode is not None
    return SubprocessResult(
        proc.returncode,
        "\n".join(stdout_data).strip(),
        "\n".join(stderr_data).strip(),
        "\n".join(combined_data).strip(),
        elapsed_time,
    )


def log_request(method_name: str, request: Any):
    logger.info("Received %s:\n%s", method_name, request)


async def set_nix_path():
    NIX_PATH_PATH = CSI_ROOT / "NIX_PATH"
    build = await run_console(
        "nix",
        "build",
        "--file",
        "/etc/nix/nix-path.nix",
        "--out-link",
        NIX_PATH_PATH,
    )
    if build.returncode != 0:
        raise GRPCError(
            Status.INVALID_ARGUMENT,
            f"nix build (NIX_PATH) failed: {build.returncode=}",
        )
    os.environ["NIX_PATH"] = NIX_PATH_PATH.read_text().strip()


class NodeServicer(csi_grpc.NodeBase):
    # If you get evictions from cache size you are elite
    packagePathCache: TTLCache[str, Path] = TTLCache(1337, 60)
    pathInfoCache: TTLCache[Path, List[str]] = TTLCache(1337, 60)
    expressionLock: defaultdict[str, Semaphore] = defaultdict(Semaphore)

    async def NodePublishVolume(self, stream):
        request: csi_pb2.NodePublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodePublishVolumeRequest is None")

        logger.info("Received NodePublishVolume")

        logger.info(f"{request.target_path=}")
        logger.info(f"{request.volume_id=}")

        targetPath = Path(request.target_path)
        expression = request.volume_context.get("expression")
        storePath = request.volume_context.get("storePath")
        packagePath: Path = Path("/nonexistent/path/that/should/never/exist")
        gcPath = NIX_GCROOTS / request.volume_id

        if storePath is not None:
            packagePathCacheResult = self.packagePathCache.get(storePath)
            if packagePathCacheResult is not None and packagePathCacheResult.exists():
                packagePath = packagePathCacheResult
            else:
                logger.debug(f"{storePath=}")
                buildCommand = [
                    "nix",
                    "build",
                    "--out-link",
                    gcPath,
                    storePath,
                ]

                # Fetch storePath from caches
                build = await run_console(*buildCommand)
                if build.returncode != 0:
                    buildCommand += [
                        "--substituters",
                        "https://cache.nixos.org",
                    ]
                    build = await run_console(*buildCommand)
                    if build.returncode != 0:
                        logger.error(
                            f"nix build (expression) failed: {build.returncode=}"
                        )
                        # Use GRPCError here, we don't need to log output again
                        raise GRPCError(
                            Status.INVALID_ARGUMENT,
                            f"nix build (expression) failed: {build.returncode=} {build.stderr=}",
                        )
                packagePath = Path(build.stdout.splitlines()[0])
                self.packagePathCache[storePath] = packagePath
        elif expression is not None:
            async with self.expressionLock[expression]:
                with tempfile.NamedTemporaryFile(mode="w", suffix=".nix") as f:
                    expressionFile = Path(f.name)
                    f.write(expression)
                    f.flush()

                    packagePathCacheResult = self.packagePathCache.get(expression)
                    if packagePathCacheResult is not None and packagePathCacheResult.exists():
                        packagePath = packagePathCacheResult
                        logger.debug("Package path from cache")
                    else:
                        # eval expression to get storePath
                        eval = await run_captured(
                            "nix", "eval", "--impure", "--raw", "--file", expressionFile
                        )
                        if eval.returncode != 0:
                            raise GRPCError(
                                Status.INVALID_ARGUMENT,
                                f"nix eval (expression) failed: {eval.returncode=} {eval.combined=}",
                            )
                        packagePath = Path(eval.stdout)
                        self.packagePathCache[expression] = packagePath
                        logger.debug("Package path after eval, already exists")

                    # Spawn a Job to build the expression
                    if not packagePath.exists():
                        jobResult = await runbuild.run(str(packagePath), expression)
                        if jobResult[0]:
                            buildResult = await run_captured("nix", "build", storePath)
                            if buildResult.returncode == 0:
                                packagePath = Path(buildResult.stdout.splitlines()[0])
                                self.packagePathCache[expression] = packagePath
                                logger.debug("Package path from job and build")

                    # Build within CSI if Job build failed, this will be removed
                    if not packagePath.exists():
                        buildCommand = [
                            "nix",
                            "build",
                            "--impure",
                            "--print-out-paths",
                            "--out-link",
                            gcPath,
                            "--file",
                            expressionFile,
                        ]

                        # Build expression
                        build = await run_console(*buildCommand)
                        if build.returncode != 0:
                            buildCommand += [
                                "--substituters",
                                "https://cache.nixos.org",
                            ]
                            # Retry build with only CNS if it fails
                            build = await run_console(*buildCommand)
                            if build.returncode != 0:
                                logger.error(
                                    f"nix build (expression) failed: {build.returncode=}"
                                )
                                # Use GRPCError here, we don't need to log output again
                                raise GRPCError(
                                    Status.INVALID_ARGUMENT,
                                    f"nix build (expression) failed: {build.returncode=} {build.stderr=}",
                                )

                        packagePath = Path(build.stdout.splitlines()[0])
                        self.packagePathCache[expression] = packagePath
                        logger.debug("Package path from local build")
        else:
            raise GRPCError(
                Status.INVALID_ARGUMENT,
                "Set either `expression` or `storePath` in volume attributes",
            )

        # Root directory for volume. Contains /nix, also contains "workdir" and
        # "upperdir" if we're doing overlayfs
        volumeRoot = CSI_VOLUMES / request.volume_id
        # Capitalized to emphasise they're Nix environment variables
        NIX_STATE_DIR = volumeRoot / "nix/var/nix"
        # Create NIX_STATE_DIR where database will be initialized
        NIX_STATE_DIR.mkdir(parents=True, exist_ok=True)

        # Get closure
        paths = []
        pathInfoCacheResult = self.pathInfoCache.get(packagePath)
        if pathInfoCacheResult is not None:
            paths = pathInfoCacheResult
            logger.debug("Package closure from cache")
        else:
            pathInfo = await run_captured(
                "nix",
                "path-info",
                "--recursive",
                packagePath,
            )
            if pathInfo.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"nix path-info failed: {pathInfo.returncode=} {pathInfo.stderr=}",
                )
            paths = pathInfo.stdout.splitlines()
            self.pathInfoCache[packagePath] = paths
            logger.debug("Package closure path-info")

        try:
            # Copy closure to substore, rsync saves a lot of implementation
            # headache here. --archive keeps all attributes, --hard-links
            # hardlinks everything hardlinkable.
            async with RSYNC_CONCURRENCY:
                rsync = await run_captured(
                    "rsync",
                    "--one-file-system",
                    "--recursive",
                    "--links",
                    "--hard-links",
                    "--mkpath",
                    # "--archive",
                    *paths,
                    volumeRoot / "nix/store",
                )
                if rsync.returncode != 0:
                    raise NixCsiError(
                        Status.INTERNAL,
                        f"rsync failed {rsync.returncode=} {rsync.stderr=}",
                    )

            # Link root derivation to /nix/var/result in the container. This is a "well-know" path
            lnResult = await run_captured(
                "ln",
                "--force",
                "--symbolic",
                packagePath,
                volumeRoot / "nix/var/result",
            )
            if lnResult.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"ln1 failed {lnResult.returncode=} {lnResult.stdout=} {lnResult.stderr=}",
                )

            # gcroots in container
            (NIX_STATE_DIR / "gcroots").mkdir(parents=True, exist_ok=True)
            lnRoots = await run_captured(
                "ln",
                "--force",
                "--symbolic",
                "/nix/var/result",
                NIX_STATE_DIR / "gcroots" / "result",
            )
            if lnRoots.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"ln2 failed {lnRoots.returncode=} {lnRoots.stdout=} {lnRoots.stderr=}",
                )

            # Create Nix database
            # This is an execline script that runs nix-store --dump-db | NIX_STATE_DIR=something nix-store --load-db
            nix_init_db = await run_captured(
                "nix_init_db",
                NIX_STATE_DIR,
                *paths,
            )
            if nix_init_db.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"nix_init_db failed {nix_init_db.returncode=} {nix_init_db.stdout=} {nix_init_db.stderr=}",
                )
        except NixCsiError as ex:
            # Remove gcroots if we failed something else
            gcPath.unlink(missing_ok=True)
            # Remove what we were working on
            shutil.rmtree(volumeRoot, True)
            raise ex

        targetPath.mkdir(parents=True, exist_ok=True)
        mountCommand = []
        if request.readonly:
            # For readonly we use a bind mount, the benefit is that different
            # container stores using bindmounts will get the same inodes and
            # share page cache with others, reducing host storage and memory usage.
            mountCommand = [
                "mount",
                "--verbose",
                "--bind",
                "-o",
                "ro",
                volumeRoot / "nix",
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
                f"rw,lowerdir={volumeRoot / 'nix'},upperdir={upperdir},workdir={workdir}",
                targetPath,
            ]

        mount = await run_console(*mountCommand)
        if mount.returncode == MOUNT_ALREADY_MOUNTED:
            logger.debug(f"Mount target {targetPath} was already mounted")
        elif mount.returncode != 0:
            raise NixCsiError(
                Status.INTERNAL,
                f"Failed to mount {mount.returncode=} {mount.stderr=}",
            )

        reply = csi_pb2.NodePublishVolumeResponse()
        await stream.send_message(reply)

        async def copyToCache():
            pathInfo = await run_captured(
                "nix",
                "path-info",
                "--recursive",
                "--derivation",
                packagePath,
            )
            if pathInfo.returncode != 0:
                logger.error(
                    "Unable to copy because path-info failed, shouldn't be possible"
                )
                return

            # Filter away derivation files
            paths = {p for p in pathInfo.stdout.splitlines() if not p.endswith(".drv")}
            for _ in range(6):
                nixCopy = await run_captured(
                    "nix", "copy", "--to", "ssh://nix-cache", *paths
                )
                if nixCopy.returncode == 0:
                    logger.info(
                        f"{len(paths)} paths copied to cache in {nixCopy.elapsed:.2f} seconds"
                    )
                    break
                else:
                    logger.error(
                        f"nix copy failed: {nixCopy.returncode=}\n{nixCopy.combined=}"
                    )
                await asyncio.sleep(10)

        if os.getenv("BUILD_CACHE") == "true":
            asyncio.create_task(copyToCache())

    async def NodeUnpublishVolume(self, stream):
        request: csi_pb2.NodeUnpublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeUnpublishVolumeRequest is None")
        log_request("NodeUnpublishVolume", request)

        errors = []
        targetPath = Path(request.target_path)

        # Check if mounted first
        check = await run_captured("mountpoint", "--quiet", targetPath)
        if check.returncode == 0:
            umount = await run_console("umount", "--verbose", targetPath)
            if umount.returncode != 0:
                errors.append(f"umount failed {umount.returncode=} {umount.stderr=}")

        gcroot_path = NIX_GCROOTS / request.volume_id
        if gcroot_path.exists():
            try:
                gcroot_path.unlink()
            except Exception as ex:
                errors.append(f"gcroot unlink failed: {ex}")

        volume_path = CSI_VOLUMES / request.volume_id
        if volume_path.exists():
            try:
                shutil.rmtree(volume_path)
            except Exception as ex:
                errors.append(f"volume cleanup failed: {ex}")

        if errors:
            raise NixCsiError(Status.INTERNAL, "; ".join(errors))

        reply = csi_pb2.NodeUnpublishVolumeResponse()
        await stream.send_message(reply)

    async def NodeGetCapabilities(self, stream):
        request: csi_pb2.NodeGetCapabilitiesRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetCapabilitiesRequest is None")
        # log_request("NodeGetCapabilities", request)
        reply = csi_pb2.NodeGetCapabilitiesResponse(capabilities=[])
        await stream.send_message(reply)

    async def NodeGetInfo(self, stream):
        request: csi_pb2.NodeGetInfoRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetInfoRequest is None")
        # log_request("NodeGetInfo", request)
        reply = csi_pb2.NodeGetInfoResponse(
            node_id=str(os.environ.get("KUBE_NODE_NAME")),
        )
        await stream.send_message(reply)

    async def NodeGetVolumeStats(self, stream):
        del stream  # typechecker
        raise NixCsiError(Status.UNIMPLEMENTED, "NodeGetVolumeStats not implemented")

    async def NodeExpandVolume(self, stream):
        del stream  # typechecker
        raise NixCsiError(Status.UNIMPLEMENTED, "NodeExpandVolume not implemented")

    async def NodeStageVolume(self, stream):
        del stream  # typechecker
        raise NixCsiError(Status.UNIMPLEMENTED, "NodeStageVolume not implemented")

    async def NodeUnstageVolume(self, stream):
        del stream  # typechecker
        raise NixCsiError(Status.UNIMPLEMENTED, "NodeUnstageVolume not implemented")


class IdentityServicer(csi_grpc.IdentityBase):
    async def GetPluginInfo(self, stream):
        request: csi_pb2.GetPluginInfoRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("GetPluginInfoRequest is None")
        reply = csi_pb2.GetPluginInfoResponse(
            name=CSI_PLUGIN_NAME, vendor_version=CSI_VENDOR_VERSION
        )
        await stream.send_message(reply)

    async def GetPluginCapabilities(self, stream):
        request: (
            csi_pb2.GetPluginCapabilitiesRequest | None
        ) = await stream.recv_message()
        if request is None:
            raise ValueError("GetPluginCapabilitiesRequest is None")
        reply = csi_pb2.GetPluginCapabilitiesResponse(
            capabilities=[
                csi_pb2.PluginCapability(
                    service=csi_pb2.PluginCapability.Service(
                        type=csi_pb2.PluginCapability.Service.CONTROLLER_SERVICE
                    )
                ),
            ]
        )
        await stream.send_message(reply)

    async def Probe(self, stream):
        request: csi_pb2.ProbeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ProbeRequest is None")
        reply = csi_pb2.ProbeResponse(ready=BoolValue(value=True))
        await stream.send_message(reply)


async def serve():
    # Clean old volumes on startup
    reboot_cleanup()
    # Create directories we operate in
    CSI_ROOT.mkdir(parents=True, exist_ok=True)
    CSI_VOLUMES.mkdir(parents=True, exist_ok=True)
    NIX_GCROOTS.mkdir(parents=True, exist_ok=True)
    await set_nix_path()

    sock_path = "/csi/csi.sock"
    Path(sock_path).unlink(missing_ok=True)

    server = Server(
        [
            IdentityServicer(),
            NodeServicer(),
        ]
    )

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(sock_path)
    sock.listen(128)
    sock.setblocking(False)

    await server.start(sock=sock)
    logger.info(f"CSI driver (grpclib) listening on unix://{sock_path}")
    await server.wait_closed()
