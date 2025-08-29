from enum import unique
import logging
import os
import socket
import argparse
import shutil
import tempfile

from typing import Any
from google.protobuf.wrappers_pb2 import BoolValue
from grpclib.server import Server
from grpclib.exceptions import GRPCError
from grpclib.const import Status
from csi import csi_grpc, csi_pb2
from pathlib import Path

from . import helpers

logger = logging.getLogger("cknix-csi")

CSI_PLUGIN_NAME = "cknix.csi.store"
CSI_VENDOR_VERSION = "0.1.0"

KUBE_NODE_NAME = os.environ.get("KUBE_NODE_NAME")
# if KUBE_NODE_NAME is None:
#     raise Exception("Please make sure KUBE_NODE_NAME is set")

CKNIX_ROOT = Path("/nix/var/cknix")


def log_request(method_name: str, request: Any):
    logger.info("Received %s:\n%s", method_name, request)


# nix eval + nix build + cp + nix_init_db
async def realize_store(
    file: Path,
    root_name: str,
) -> None | Path:
    """Build and realize a Nix expression into a sub/fake store."""
    # Build the expression
    build_result = await helpers.run_subprocess(
        "nix",
        "build",
        "--impure",
        "--no-link",
        "--print-out-paths",
        "--file",
        str(file),
    )
    if build_result.retcode != 0:
        raise Exception("Build failed")

    # Get the resulting storepath
    packagePath = build_result.stdout.strip()

    fakeRoot = CKNIX_ROOT.joinpath(root_name)
    cknixPrefix = fakeRoot.joinpath("nix")
    packageResultPath = cknixPrefix.joinpath("var/result")
    # Capitalized to emphasise they're Nix environment variables
    NIX_STATE_DIR = cknixPrefix.joinpath("var/nix")
    NIX_STORE_DIR = cknixPrefix.joinpath("store")

    # Get dependency paths
    path_info = await helpers.run_subprocess(
        "nix", "path-info", "--recursive", packagePath
    )
    paths = set(path_info.stdout.strip().splitlines())

    # Create container store structure
    NIX_STATE_DIR.mkdir(parents=True, exist_ok=True)
    NIX_STORE_DIR.mkdir(parents=True, exist_ok=True)

    # Copy dependencies to substore, rsync saves a lot of implementation headache
    # here. --archive keeps all attributes, --hard-links hardlinks everything
    # it can while replicating symlinks exactly as they were.
    await helpers.run_subprocess(
        "rsync", "--archive", "--hard-links", *paths, str(NIX_STORE_DIR)
    )

    # Link root derivation to /nix/var/result in the container. This is a "well-know" path
    await helpers.run_subprocess(
        "ln", "--symbolic", str(packagePath), str(packageResultPath)
    )

    # Create Nix database
    # This is an execline script that runs nix-store --dump-db | NIX_STATE_DIR=something nix-store --load-db
    await helpers.run_subprocess("nix_init_db", str(NIX_STATE_DIR), *paths)

    return fakeRoot


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


class ControllerServicer(csi_grpc.ControllerBase):
    async def CreateVolume(self, stream):
        request: csi_pb2.CreateVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("CreateVolumeRequest is None")
        log_request("CreateVolume", request)

        volume_id = request.name
        capacity_bytes = (
            request.capacity_range.required_bytes if request.capacity_range else 0
        )

        reply = csi_pb2.CreateVolumeResponse(
            volume=csi_pb2.Volume(
                volume_id=volume_id,
                capacity_bytes=capacity_bytes,
                volume_context={},
                accessible_topology=[],
            )
        )
        await stream.send_message(reply)

    async def DeleteVolume(self, stream):
        request: csi_pb2.DeleteVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("DeleteVolumeRequest is None")
        log_request("DeleteVolume", request)

        reply = csi_pb2.DeleteVolumeResponse()
        await stream.send_message(reply)

    async def ControllerPublishVolume(self, stream):
        raise Exception("ControllerPublishVolume not implemented")

    async def ControllerUnpublishVolume(self, stream):
        raise Exception("ControllerUnpublishVolume not implemented")

    async def ValidateVolumeCapabilities(self, stream):
        request: (
            csi_pb2.ValidateVolumeCapabilitiesRequest | None
        ) = await stream.recv_message()
        if request is None:
            raise ValueError("ValidateVolumeCapabilitiesRequest is None")
        log_request("ValidateVolumeCapabilities", request)
        supported = any(
            cap.access_mode.mode
            == csi_pb2.VolumeCapability.AccessMode.SINGLE_NODE_WRITER
            for cap in request.volume_capabilities
        )
        if supported:
            reply = csi_pb2.ValidateVolumeCapabilitiesResponse(
                confirmed=csi_pb2.ValidateVolumeCapabilitiesResponse.Confirmed(
                    volume_capabilities=request.volume_capabilities
                )
            )
        else:
            reply = csi_pb2.ValidateVolumeCapabilitiesResponse(
                message="Only SINGLE_NODE_WRITER supported"
            )
        await stream.send_message(reply)

    async def ListVolumes(self, stream):
        raise Exception("ListVolumes not implemented")

    async def GetCapacity(self, stream):
        raise Exception("GetCapacity not implemented")

    async def ControllerGetCapabilities(self, stream):
        request: (
            csi_pb2.ControllerGetCapabilitiesRequest | None
        ) = await stream.recv_message()
        if request is None:
            raise ValueError("ControllerGetCapabilitiesRequest is None")
        # log_request("ControllerGetCapabilities", request)
        reply = csi_pb2.ControllerGetCapabilitiesResponse(
            capabilities=[
                csi_pb2.ControllerServiceCapability(
                    rpc=csi_pb2.ControllerServiceCapability.RPC(
                        type=csi_pb2.ControllerServiceCapability.RPC.CREATE_DELETE_VOLUME
                    )
                ),
            ]
        )
        await stream.send_message(reply)

    async def CreateSnapshot(self, stream):
        raise Exception("CreateSnapshot not implemented")

    async def DeleteSnapshot(self, stream):
        raise Exception("DeleteSnapshot not implemented")

    async def ListSnapshots(self, stream):
        raise Exception("ListSnapshots not implemented")

    async def ControllerExpandVolume(self, stream):
        raise Exception("ControllerExpandVolume not implemented")

    async def ControllerGetVolume(self, stream):
        request: csi_pb2.ControllerGetVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ControllerGetVolumeRequest is None")
        log_request("ControllerGetVolume", request)
        reply = csi_pb2.ControllerGetVolumeResponse(
            volume=csi_pb2.Volume(
                volume_id=request.volume_id,
            )
        )
        await stream.send_message(reply)

    async def ControllerModifyVolume(self, stream):
        request: (
            csi_pb2.ControllerModifyVolumeRequest | None
        ) = await stream.recv_message()
        if request is None:
            raise ValueError("ControllerModifyVolumeRequest is None")
        log_request("ControllerModifyVolume", request)
        reply = csi_pb2.ControllerModifyVolumeResponse()
        await stream.send_message(reply)


class NodeServicer(csi_grpc.NodeBase):
    async def NodePublishVolume(self, stream):
        request: csi_pb2.NodePublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodePublishVolumeRequest is None")
        log_request("NodePublishVolume", request)

        expr = None
        podUid = None
        for k, v in request.volume_context.items():
            match k:
                case "expr":
                    expr = v
                case "csi.storage.k8s.io/pod.uid":
                    podUid = v

        if expr is None:
            raise Exception("Couldn't find expression")
        if podUid is None:
            raise Exception("Couldn't find podUid")

        expressionFile = Path(tempfile.mktemp(suffix=".nix"))
        expressionFile.write_text(expr)

        logger.debug(
            msg=f"Evaluating Nix expression: {expr}, volume_id: {request.volume_id}"
        )

        evalRes = await helpers.run_subprocess(
            "nix", "eval", "--impure", "--raw", "--file", expressionFile
        )

        if evalRes.retcode != 0:
            error = f"""
                Failed to evaluate expression:
                {expr}
            """
            logger.error(msg=error)
            raise GRPCError(
                Status.INTERNAL,
                error,
            )

        fakeRoot = await realize_store(expressionFile, podUid)
        if fakeRoot is None:
            error = "Unable to build fakeStore"
            logger.error(msg=error)
            raise GRPCError(
                Status.INTERNAL,
                error,
            )

        expressionFile.unlink()

        sourcePath = fakeRoot.joinpath("nix")
        targetPath = Path(request.target_path)

        logger.debug(msg=f"Mounting {fakeRoot}/nix on {request.target_path}")
        Path(request.target_path).mkdir(parents=True, exist_ok=True)
        sourcePath.joinpath("poduid").write_text(podUid)
        if request.readonly:
            # For readonly we use a bind mount, the benefit is that different
            # container stores using bindmounts will get the same inodes and
            # share page cache with others, reducing host storage and memory usage.
            await helpers.run_subprocess(
                "mount",
                "--bind",
                "--verbose",
                "-o",
                "ro",
                str(sourcePath),
                str(targetPath),
            )
        else:
            # For readwrite we use an overlayfs mount, the benefit here is that
            # it works as CoW even if the underlying filesystem doesn't support
            # it, reducing host storage usage.
            parent = targetPath.parent
            workdir = parent.joinpath("workdir")
            upperdir = parent.joinpath("upperdir")
            workdir.mkdir(parents=True, exist_ok=True)
            upperdir.mkdir(parents=True, exist_ok=True)
            await helpers.run_subprocess(
                "mount",
                "-t",
                "overlay",
                "overlay",
                "-o",
                f"rw,lowerdir={sourcePath},upperdir={upperdir},workdir={workdir}",
                str(targetPath),
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
            targetPath = Path(request.target_path)
            uidPath = targetPath.joinpath("poduid")
            podUid = uidPath.read_text()
            gcPath = CKNIX_ROOT.joinpath(podUid)
            shutil.rmtree(gcPath)
        except Exception as ex:
            logger.error("Unable to get poduid for GC")
            logger.error(ex)
        await helpers.run_subprocess("umount", "--verbose", request.target_path)

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
        raise Exception("NodeGetVolumeStats not implemented")

    async def NodeExpandVolume(self, stream):
        raise Exception("NodeExpandVolume not implemented")

    async def NodeStageVolume(self, stream):
        raise Exception("NodeStageVolume not implemented")

    async def NodeUnstageVolume(self, stream):
        raise Exception("NodeUnstageVolume not implemented")


async def serve(args: argparse.Namespace):
    sock_path = "/csi/csi.sock"
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

    server = Server([])

    if getattr(args, "node"):
        server = Server(
            [
                IdentityServicer(),
                NodeServicer(),
            ]
        )
    if getattr(args, "controller"):
        server = Server(
            [
                IdentityServicer(),
                ControllerServicer(),
            ]
        )

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(sock_path)
    sock.listen(128)
    sock.setblocking(False)

    await server.start(sock=sock)
    logger.info(f"CSI driver (grpclib) listening on unix://{sock_path}")
    await server.wait_closed()
