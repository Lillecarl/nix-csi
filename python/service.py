import logging
import os
import socket
import shutil
import tempfile
import asyncio
import sys
import shlex

from typing import Any, NamedTuple, Optional
from google.protobuf.wrappers_pb2 import BoolValue
from grpclib.server import Server
from grpclib.exceptions import GRPCError
from grpclib.const import Status
from csi import csi_grpc, csi_pb2
from pathlib import Path

logger = logging.getLogger("nix-csi")

CSI_PLUGIN_NAME = "nix.csi.store"
CSI_VENDOR_VERSION = "0.1.0"

MOUNT_ALREADY_MOUNTED = 32

KUBE_NODE_NAME = os.environ.get("KUBE_NODE_NAME")
if KUBE_NODE_NAME is None:
    raise Exception("Please make sure KUBE_NODE_NAME is set")

# Paths we base everything on. Remember that these are CSI pod paths not
# node paths.
CSI_ROOT = Path("/nix/var/nix-csi")
CSI_VOLUMES = CSI_ROOT / "volumes"
NIX_GCROOTS = Path("/nix/var/nix/gcroots/nix-csi")


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


def get_kernel_boot_time() -> int:
    """Returns kernel boot time as Unix timestamp."""
    stat_file = Path("/hoststat")
    for line in stat_file.read_text().splitlines():
        if line.startswith("btime "):
            return int(line.split()[1])
    raise RuntimeError("btime not found in /hoststat")


def should_cleanup_mounts() -> bool:
    """Check if system rebooted since last run."""
    current_boot = get_kernel_boot_time()

    state_file = CSI_ROOT / "boottime"

    if not state_file.exists():
        state_file.write_text(str(current_boot))
        return False

    last_boot = int(state_file.read_text().strip())

    if current_boot != last_boot:
        state_file.write_text(str(current_boot))
        return True

    return False


def boot_cleanup():
    """Cleanup volume trees and gcroots if we have rebooted"""
    logger.info("Checking boot-time for cleanup operations")
    if should_cleanup_mounts():
        if CSI_VOLUMES.exists():
            logger.info("Cleaning old volumes")
            shutil.rmtree(CSI_VOLUMES)
            CSI_VOLUMES.mkdir(parents=True, exist_ok=True)
        if NIX_GCROOTS.exists():
            logger.info("Cleaning gcroots")
            shutil.rmtree(NIX_GCROOTS)
            NIX_GCROOTS.mkdir(parents=True, exist_ok=True)


class SubprocessResult(NamedTuple):
    returncode: int
    stdout: str
    stderr: str
    combined: str


def log_command(*args, log_level: int):
    logger.log(
        log_level,
        f"Running command: {shlex.join([str(arg) for arg in args])}",
    )


# Run async subprocess, capture output and returncode
async def run_captured(*args):
    return await run_console(*args, log_level=logging.NOTSET)


# Run async subprocess, forward output to console and return returncode
async def run_console(*args, log_level: int = logging.DEBUG):
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
            decoded = line.decode()
            buffer.append(decoded)
            combined_data.append(decoded)
            logger.log(log_level, decoded.rstrip("\n"))

    await asyncio.gather(
        stream_output(proc.stdout, stdout_data),
        stream_output(proc.stderr, stderr_data),
        proc.wait(),
    )

    assert proc.returncode is not None
    return SubprocessResult(
        proc.returncode,
        "".join(stdout_data).strip(),
        "".join(stderr_data).strip(),
        "".join(combined_data).strip(),
    )


def log_request(method_name: str, request: Any):
    logger.info("Received %s:\n%s", method_name, request)


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


class NodeServicer(csi_grpc.NodeBase):
    async def NodePublishVolume(self, stream):
        request: csi_pb2.NodePublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodePublishVolumeRequest is None")

        logger.info("Received NodePublishVolume")
        logger.info(f"{request.target_path=}")
        logger.info(f"{request.volume_id=}")

        targetPath = Path(request.target_path)

        # Check if already mounted (idempotency)
        check_mount = await run_captured("mountpoint", "-q", targetPath)
        if check_mount.returncode == 0:
            logger.info(f"Volume {request.volume_id} already mounted at {targetPath}")
            reply = csi_pb2.NodePublishVolumeResponse()
            await stream.send_message(reply)
            return

        expr = request.volume_context.get("expr")
        if expr is None:
            raise NixCsiError(
                Status.INVALID_ARGUMENT, "Missing 'expr' in volume_context"
            )

        logger.info(f"Requested to build\n{expr}")

        root_name = request.volume_id

        expressionFile = Path(tempfile.mktemp(suffix=".nix"))
        try:
            expressionFile.write_text(expr)

            gcPath = NIX_GCROOTS / root_name

            # Get outPath from eval
            eval = await run_console(
                "nix",
                "eval",
                "--raw",
                "--impure",
                "--file",
                expressionFile,
            )
            if eval.returncode != 0:
                raise NixCsiError(
                    Status.INVALID_ARGUMENT,
                    f"nix eval failed: {eval.returncode=} {eval.stderr=}",
                )

            # Build, stream to console
            build = await run_console(
                "nix",
                "build",
                "--impure",
                "--out-link",
                gcPath,
                "--file",
                expressionFile,
            )
            if build.returncode != 0:
                raise NixCsiError(
                    Status.INVALID_ARGUMENT,
                    f"nix build failed: {build.returncode=} {build.stderr=}",
                )

        except Exception as ex:
            raise ex
        finally:
            expressionFile.unlink(missing_ok=True)

        # Get the resulting storepath
        packagePath = Path(eval.stdout)

        fakeRoot = CSI_VOLUMES / root_name
        nixCsiPrefix = fakeRoot / "nix"
        packageResultPath = nixCsiPrefix / "var/result"
        # Capitalized to emphasise they're Nix environment variables
        NIX_STATE_DIR = nixCsiPrefix / "var/nix"
        NIX_STORE_DIR = nixCsiPrefix / "store"

        # Get dependency paths
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
        paths = set(pathInfo.stdout.splitlines())

        # Create container store structure
        NIX_STATE_DIR.mkdir(parents=True, exist_ok=True)
        NIX_STORE_DIR.mkdir(parents=True, exist_ok=True)

        try:
            # Copy dependencies to substore, rsync saves a lot of implementation headache
            # here. --archive keeps all attributes, --hard-links hardlinks everything
            # it can while replicating symlinks exactly as they were.
            rsync = await run_captured(
                "rsync",
                "--one-file-system",
                "--archive",
                "--hard-links",
                *paths,
                NIX_STORE_DIR,
            )
            if rsync.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"rsync failed {rsync.returncode=} {rsync.stderr=}",
                )

            # Link root derivation to /nix/var/result in the container. This is a "well-know" path
            ln1 = await run_captured(
                "ln", "--force", "--symbolic", packagePath, packageResultPath
            )
            if ln1.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"ln1 failed {ln1.returncode=} {ln1.stdout=} {ln1.stderr=}",
                )

            # Link root derivation to /nix/var/result in the container. This is a "well-know" path
            (NIX_STATE_DIR / "gcroots").mkdir(parents=True, exist_ok=True)
            ln2 = await run_captured(
                "ln",
                "--force",
                "--symbolic",
                "/nix/var/result",
                NIX_STATE_DIR / "gcroots" / "result",
            )
            if ln2.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"ln2 failed {ln2.returncode=} {ln2.stdout=} {ln2.stderr=}",
                )

            # Create Nix database
            # This is an execline script that runs nix-store --dump-db | NIX_STATE_DIR=something nix-store --load-db
            nix_init_db = await run_captured("nix_init_db", NIX_STATE_DIR, *paths)
            if nix_init_db.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"nix_init_db failed {nix_init_db.returncode=} {nix_init_db.stdout=} {nix_init_db.stderr=}",
                )
        except NixCsiError as ex:
            # Remove gcroots if we failed something else
            gcPath.unlink(missing_ok=True)
            # Remove what we were working on
            shutil.rmtree(fakeRoot, True)
            raise ex

        sourcePath = fakeRoot / "nix"

        targetPath.mkdir(parents=True, exist_ok=True)
        if request.readonly:
            # For readonly we use a bind mount, the benefit is that different
            # container stores using bindmounts will get the same inodes and
            # share page cache with others, reducing host storage and memory usage.
            mount = await run_console(
                "mount",
                "--verbose",
                "--bind",
                "-o",
                "ro",
                sourcePath,
                targetPath,
            )
            if mount.returncode == MOUNT_ALREADY_MOUNTED:
                logger.debug(f"Mount target {targetPath} was already mounted")
            elif mount.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"Failed to bind mount {mount.returncode=} {mount.stderr=}",
                )
        else:
            # For readwrite we use an overlayfs mount, the benefit here is that
            # it works as CoW even if the underlying filesystem doesn't support
            # it, reducing host storage usage.
            parent = targetPath.parent
            workdir = parent / "workdir"
            upperdir = parent / "upperdir"
            workdir.mkdir(parents=True, exist_ok=True)
            upperdir.mkdir(parents=True, exist_ok=True)
            mount = await run_console(
                "mount",
                "--verbose",
                "-t",
                "overlay",
                "overlay",
                "-o",
                f"rw,lowerdir={sourcePath},upperdir={upperdir},workdir={workdir}",
                targetPath,
            )
            if mount.returncode == MOUNT_ALREADY_MOUNTED:
                logger.debug(f"Mount target {targetPath} was already mounted")
            elif mount.returncode != 0:
                raise NixCsiError(
                    Status.INTERNAL,
                    f"Failed to overlayfs mount {mount.returncode=} {mount.stderr=}",
                )

        reply = csi_pb2.NodePublishVolumeResponse()
        await stream.send_message(reply)

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
            node_id=str(KUBE_NODE_NAME),
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


async def serve():
    # Clean old volumes on startup
    boot_cleanup()
    # Create directories we operate in
    CSI_ROOT.mkdir(parents=True, exist_ok=True)
    CSI_VOLUMES.mkdir(parents=True, exist_ok=True)
    NIX_GCROOTS.mkdir(parents=True, exist_ok=True)

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
