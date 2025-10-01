import logging
import os
import socket
import shutil
import tempfile
import hashlib
import asyncio
import sys

from typing import Any, NamedTuple
from google.protobuf.wrappers_pb2 import BoolValue
from grpclib.server import Server
from grpclib.exceptions import GRPCError
from grpclib.const import Status
from csi import csi_grpc, csi_pb2
from pathlib import Path

logger = logging.getLogger("nix-csi")

CSI_PLUGIN_NAME = "nix.csi.store"
CSI_VENDOR_VERSION = "0.1.0"

KUBE_NODE_NAME = os.environ.get("KUBE_NODE_NAME")
if KUBE_NODE_NAME is None:
    raise Exception("Please make sure KUBE_NODE_NAME is set")

NIX_ROOT = Path("/nix/var/nix-csi")
NIX_GCROOTS = Path("/nix/var/nix/gcroots/nix-csi")
NIX_GCROOTS.mkdir(parents=True, exist_ok=True)


class CapturedOutput(NamedTuple):
    returncode: int
    stdout: str
    stderr: str


# Run async subprocess, capture output and returncode
async def run_captured(*args):
    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    ret = await proc.communicate()
    if proc.returncode is None:  # Can't happen? Make type-checker happy
        raise Exception(f"Couldn't get returncode from command {args}")
    return CapturedOutput(
        proc.returncode, ret[0].decode().strip(), ret[1].decode().strip()
    )


# Run async subprocess, forward output to console and return returncode
async def run_console(*args):
    proc = await asyncio.create_subprocess_exec(
        *args, stdout=sys.stdout, stderr=sys.stderr
    )
    ret = await proc.wait()
    return ret


# Run async subprocess, dismiss output and return returncode
async def run_devnull(*args):
    proc = await asyncio.create_subprocess_exec(*args)
    ret = await proc.wait()
    return ret


def log_request(method_name: str, request: Any):
    logger.info("Received %s:\n%s", method_name, request)


def md5(text: str):
    return hashlib.md5(text.encode()).hexdigest()


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

        expr = request.volume_context.get("expr")
        if expr is None:
            log_request("NodePublishVolume", request)
            raise Exception("Couldn't find expression")

        logger.info(f"Requested to build\n{expr}")

        root_name = md5(request.target_path)
        gcPath = NIX_GCROOTS.joinpath(root_name)

        expressionFile = Path(tempfile.mktemp(suffix=".nix"))
        expressionFile.write_text(expr)

        gcPath = NIX_GCROOTS.joinpath(root_name)

        # Get outPath from eval
        eval = await run_captured(
            "nix",
            "eval",
            "--raw",
            "--impure",
            "--file",
            str(expressionFile),
        )
        if eval.returncode != 0:
            raise Exception("Evaluation failed")

        # Build, stream to console
        build = await run_console(
            "nix",
            "build",
            "--impure",
            "--out-link",
            str(gcPath),
            "--file",
            str(expressionFile),
        )
        if build != 0:
            raise Exception("Build failed")

        # Get the resulting storepath
        packagePath = Path(eval.stdout)

        fakeRoot = NIX_ROOT.joinpath(root_name)
        nixCsiPrefix = fakeRoot.joinpath("nix")
        packageResultPath = nixCsiPrefix.joinpath("var/result")
        # Capitalized to emphasise they're Nix environment variables
        NIX_STATE_DIR = nixCsiPrefix.joinpath("var/nix")
        NIX_STORE_DIR = nixCsiPrefix.joinpath("store")

        # Get dependency paths
        pathInfo = await run_captured(
            "nix",
            "path-info",
            "--recursive",
            str(packagePath),
        )
        paths = set(pathInfo.stdout.splitlines())

        # Create container store structure
        NIX_STATE_DIR.mkdir(parents=True, exist_ok=True)
        NIX_STORE_DIR.mkdir(parents=True, exist_ok=True)

        # Copy dependencies to substore, rsync saves a lot of implementation headache
        # here. --archive keeps all attributes, --hard-links hardlinks everything
        # it can while replicating symlinks exactly as they were.
        rsync = await run_devnull(
            "rsync", "--archive", "--hard-links", *paths, str(NIX_STORE_DIR)
        )

        # Link root derivation to /nix/var/result in the container. This is a "well-know" path
        ln = await run_devnull(
            "ln", "--force", "--symbolic", str(packagePath), str(packageResultPath)
        )

        # Create Nix database
        # This is an execline script that runs nix-store --dump-db | NIX_STATE_DIR=something nix-store --load-db
        nix_init_db = await run_devnull("nix_init_db", str(NIX_STATE_DIR), *paths)

        if rsync != 0 or ln != 0 or nix_init_db != 0:
            # Remove gcroots if we failed something else
            gcPath.unlink(missing_ok=True)
            # Remove what we were working on
            shutil.rmtree(fakeRoot, True)
            raise Exception("Linking or database initialization failed")

        if fakeRoot is None:
            error = "Unable to build fakeStore"
            logger.error(msg=error)
            raise GRPCError(
                Status.INTERNAL,
                error,
            )

        expressionFile.unlink(missing_ok=True)

        sourcePath = fakeRoot.joinpath("nix")
        targetPath = Path(request.target_path)

        logger.debug(msg=f"Mounting {fakeRoot}/nix on {request.target_path}")
        Path(request.target_path).mkdir(parents=True, exist_ok=True)
        if request.readonly:
            # For readonly we use a bind mount, the benefit is that different
            # container stores using bindmounts will get the same inodes and
            # share page cache with others, reducing host storage and memory usage.
            mount = await run_devnull(
                "mount",
                "--verbose",
                "--bind",
                "-o",
                "ro",
                str(sourcePath),
                str(targetPath),
            )
            if mount != 0:
                raise Exception("Failed to bind mount")
        else:
            # For readwrite we use an overlayfs mount, the benefit here is that
            # it works as CoW even if the underlying filesystem doesn't support
            # it, reducing host storage usage.
            parent = targetPath.parent
            workdir = parent.joinpath("workdir")
            upperdir = parent.joinpath("upperdir")
            workdir.mkdir(parents=True, exist_ok=True)
            upperdir.mkdir(parents=True, exist_ok=True)
            mount = await run_devnull(
                "mount",
                "--verbose",
                "-t",
                "overlay",
                "overlay",
                "-o",
                f"rw,lowerdir={sourcePath},upperdir={upperdir},workdir={workdir}",
                str(targetPath),
            )
            if mount != 0:
                raise Exception("Failed to overlayfs mount")

        # Relink nix-csi gcroots to a Path that's removed with the pod
        await run_devnull(
            "ln",
            "--symbolic",
            "--force",
            "--no-dereference",
            str(Path(request.target_path).joinpath("var/result")),
            str(gcPath),
        )

        reply = csi_pb2.NodePublishVolumeResponse()
        await stream.send_message(reply)

    async def NodeUnpublishVolume(self, stream):
        request: csi_pb2.NodeUnpublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeUnpublishVolumeRequest is None")
        log_request("NodeUnpublishVolume", request)

        logger.debug(msg=f"Unmounting {request.target_path}")
        try:
            pathMd5 = md5(request.target_path)
            NIX_GCROOTS.joinpath(pathMd5).unlink()
            shutil.rmtree(NIX_ROOT.joinpath(pathMd5), True)
        except Exception as ex:
            logger.error(ex)
        umount = await run_devnull("umount", "--verbose", request.target_path)
        if umount != 0:
            logger.error("Failed to umount")

        reply = csi_pb2.NodeUnpublishVolumeResponse()
        await stream.send_message(reply)

    async def NodeGetCapabilities(self, stream):
        request: csi_pb2.NodeGetCapabilitiesRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetCapabilitiesRequest is None")
        # log_request("NodeGetCapabilities", request)
        reply = csi_pb2.NodeGetCapabilitiesResponse(
            capabilities=[
                csi_pb2.NodeServiceCapability(
                    rpc=csi_pb2.NodeServiceCapability.RPC(
                        type=csi_pb2.NodeServiceCapability.RPC.STAGE_UNSTAGE_VOLUME
                    )
                ),
            ]
        )
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
        raise Exception("NodeGetVolumeStats not implemented")

    async def NodeExpandVolume(self, stream):
        del stream  # typechecker
        raise Exception("NodeExpandVolume not implemented")

    async def NodeStageVolume(self, stream):
        del stream  # typechecker
        raise Exception("NodeStageVolume not implemented")

    async def NodeUnstageVolume(self, stream):
        del stream  # typechecker
        raise Exception("NodeUnstageVolume not implemented")


async def serve():
    sock_path = "/csi/csi.sock"
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

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
