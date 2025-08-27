import asyncio
import logging
import os
import socket
import json
import argparse
import sys
from plumbum import local

from pathlib import Path
from typing import Any, Optional
from google.protobuf.wrappers_pb2 import BoolValue
from grpclib.server import Server
from grpclib.exceptions import GRPCError
from grpclib.const import Status
from csi import csi_grpc, csi_pb2

from . import helpers

logger = logging.getLogger("csi.driver")

CSI_PLUGIN_NAME = "cknix.csi.store"
CSI_VENDOR_VERSION = "0.1.0"

# todo: This shouldn't be a requirement for the controller part
KUBE_NODE_NAME = os.environ.get("KUBE_NODE_NAME")
if KUBE_NODE_NAME is None:
    raise Exception("Please make sure KUBE_NODE_NAME is set")
KUBE_NODE_NAME = str(KUBE_NODE_NAME)


def log_request(method_name: str, request: Any):
    logger.info("Received %s:\n%s", method_name, request)


#!/usr/bin/env python3
"""Build Nix store derivations using plumbum."""


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
    expr: str,
    root_name: str,
    hardlink: bool = True,
    reflink: bool = True,
    copy: bool = True,
) -> None | str:
    """Build and realize a Nix expression into a sub/fake store."""
    # Build the expression
    build_result = nix(
        "build",
        "--impure",
        "--no-link",
        "--print-out-paths",
        "--expr",
        expr,
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

    return fakeroot


async def getExpressionFromPvc(name: str, namespace: str, request: Any):
    pvcResult = await helpers.run_subprocess(
        [
            "kubectl",
            f"--namespace={namespace}",
            "--output=json",
            "get",
            "persistentvolumeclaims",
            name,
        ]
    )
    if pvcResult.retcode != 0:
        return

    pvcSpec = json.loads(pvcResult.stdout)

    if pvcSpec is None:
        error = f"Failed to find PVC with volumeName {request.name}"
        logger.error(msg=error)
        raise GRPCError(
            Status.INTERNAL,
            error,
        )

    exprName = None
    try:
        exprName = pvcSpec["metadata"]["annotations"]["cknix-expr"]
    except Exception:
        error = f"Failed to get cknix-expr annotation from PVC {pvcSpec['metadata']['name']}{request.name}"
        logger.error(msg=error)
        raise GRPCError(
            Status.INTERNAL,
            error,
        )

    exprResult = await helpers.run_subprocess(
        [
            "kubectl",
            f"--namespace={namespace}",
            "--output=json",
            "get",
            "expressions.cknix.cool",
            exprName,
        ]
    )

    if exprResult.retcode != 0:
        error = f"Failed to get cknix expression {exprName}"
        logger.error(msg=error)
        raise GRPCError(
            Status.INTERNAL,
            error,
        )

    expr = json.loads(exprResult.stdout)["data"]["expr"]
    logger.info(msg=f"Found expression {exprName} with expression {expr}")
    return expr


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

        expr = None
        for k, v in request.parameters.items():
            if k == "csi.storage.k8s.io/pvc/name":
                pvcName = v
            if k == "csi.storage.k8s.io/pvc/namespace":
                pvcNamespace = v
            if k == "expr":
                expr = v

        if expr is None:
            raise Exception("Couldn't find expression")

        buildResult = await helpers.build(expr)
        packageName = (
            str(buildResult.stdout).removeprefix("/nix/store/").removesuffix("/")
        )

        # Install packages into gcroots on controller
        await helpers.run_subprocess(
            [
                "nix-env",
                "--profile",
                f"/nix/var/nix/profiles/{packageName}",
                "--set",
                buildResult.stdout,
            ]
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

        # Implement host garbage collection

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
    def __init__(self, expressionQueue: asyncio.Queue[str]):
        self.expressionQueue = expressionQueue

    async def NodePublishVolume(self, stream):
        request: csi_pb2.NodePublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodePublishVolumeRequest is None")
        log_request("NodePublishVolume", request)

        logger.debug(
            msg=f"Looking for Nix expression in volume_context, volume_id: {request.volume_id}"
        )
        expr = None
        podUid = None
        for k, v in request.volume_context.items():
            logger.debug(f"{k=} {v=}")
            if k == "expr":
                expr = v
            if k == "csi.storage.k8s.io/pod.uid":
                podUid = v

        if expr is None:
            raise Exception("Couldn't find expression")
        if podUid is None:
            raise Exception("Couldn't find podUid")

        logger.debug(
            msg=f"Evaluating Nix expression: {expr}, volume_id: {request.volume_id}"
        )

        evalRes = await helpers.run_subprocess(
            ["nix", "eval", "--impure", "--raw", "--expr", expr]
        )

        if evalRes.retcode != 0:
            error = f"Failed to evaluate {expr}"
            logger.error(msg=error)
            raise GRPCError(
                Status.INTERNAL,
                error,
            )

        fakeRoot = await asyncio.to_thread(
            realize_store, expr, podUid, True, True, True
        )

        if fakeRoot is None:
            logger.error("Unable to build fakeStore")
            return

        logger.debug(msg=f"Mounting {fakeRoot} on {request.target_path}")
        await helpers.mkdir(request.target_path)
        await helpers.run_subprocess(
            [
                "mount",
                "--bind",
                "--verbose",
                f"{fakeRoot}/nix",
                request.target_path,
            ]
        )

        reply = csi_pb2.NodePublishVolumeResponse()
        await stream.send_message(reply)

    async def NodeUnpublishVolume(self, stream):
        request: csi_pb2.NodeUnpublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeUnpublishVolumeRequest is None")
        log_request("NodeUnpublishVolume", request)

        logger.debug(msg=f"Unmounting {request.target_path}")
        await helpers.run_subprocess(
            [
                "umount",
                "--verbose",
                request.target_path,
            ]
        )

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


async def serve(args: argparse.Namespace, expressionQueue: asyncio.Queue[str]):
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
                NodeServicer(expressionQueue),
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
