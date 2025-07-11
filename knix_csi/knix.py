import asyncio
import logging
import os
import socket
import sys
import json
import argparse
import threading
import kopf
import hashlib
import re
import shutil

from pathlib import Path
from typing import Any, Optional
from google.protobuf.wrappers_pb2 import BoolValue
from grpclib.server import Server
from grpclib.exceptions import GRPCError
from grpclib.const import Status
from csi import csi_grpc, csi_pb2

from . import helpers

logger = logging.getLogger("csi.driver")

CSI_PLUGIN_NAME = "knix.csi.store"
CSI_VENDOR_VERSION = "0.1.0"

KUBE_NODE_NAME = os.environ.get("KUBE_NODE_NAME")
if KUBE_NODE_NAME is None:
    raise Exception("Please make sure KUBE_NODE_NAME is set")
KUBE_NODE_NAME = str(KUBE_NODE_NAME)


def log_request(method_name: str, request: Any):
    logger.info("Received %s:\n%s", method_name, request)


async def realizeExpr(expr: str) -> Optional[str]:
    buildResult = await helpers.build(expr)

    if buildResult.retcode != 0:
        return

    packageName = str(buildResult.stdout).removeprefix("/nix/store/").removesuffix("/")
    packagePath = buildResult.stdout
    packageRefPath = f"/nix/var/knix/{packageName}"
    packageVarPath = f"{packageRefPath}/nix/var"
    packageResultPath = f"{packageRefPath}/nix/var/result"

    if Path(packageRefPath).is_dir():
        logger.info(f"Package {packageName} is already realized")
        return packageName

    # Link package to gcroots
    await helpers.ln(packagePath, f"/nix/var/nix/gcroots/{packageName}")

    pathInfoResult = await helpers.pathInfo(expr)

    # Create "container store root"
    await helpers.mkdir(packageRefPath)
    # Create /nix/var in "container store root"
    await helpers.mkdir(packageVarPath)
    # Copy all dependencies of package into container store
    for path in pathInfoResult.stdout.splitlines():
        res = await helpers.cpp(path, packageRefPath)
        if res.retcode != 0:
            return
    # Copy package to result folder (/nix/var/nix/result in container)
    await helpers.cp(f"{packagePath}/.", f"{packageResultPath}/")

    return packageName


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
        exprName = pvcSpec["metadata"]["annotations"]["knix-expr"]
    except Exception:
        error = f"Failed to get knix-expr annotation from PVC {pvcSpec['metadata']['name']}{request.name}"
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
            "expressions.knix.cool",
            exprName,
        ]
    )

    if exprResult.retcode != 0:
        error = f"Failed to get knix expression {exprName}"
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
        for k, v in request.volume_context.items():
            if k == "expr":
                expr = v

        if expr is None:
            raise Exception("Couldn't find expression")

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

        await self.expressionQueue.put(expr)

        packageName = str(evalRes.stdout).removeprefix("/nix/store/").removesuffix("/")

        while not Path(f"/nix/var/knix/{packageName}").exists():
            for i in range(10):
                if i == 0:
                    logger.info(
                        msg=f"Package {packageName} is not realized yet. Waiting 10 seconds."
                    )
                await asyncio.sleep(1)

        if not Path(request.target_path).exists():
            logger.debug(
                msg=f"Creating {request.target_path} where store will be mounted"
            )
            Path(request.target_path).mkdir(parents=True, exist_ok=True)

        # Initialize gcroots.json database
        gcRootsPath = Path("/nix/var/knix/gcroots.json")
        if not gcRootsPath.exists():
            gcRootsPath.parent.mkdir(parents=True)
            gcRootsPath.write_text(json.dumps([]))
        gcRootsList: list = json.loads(gcRootsPath.read_text())
        gcRootsList.append(
            {
                "packageName": packageName,
                "targetPath": request.target_path,
            }
        )
        # Write gcRoots database back to disk
        gcRootsPath.write_text(json.dumps(gcRootsList))

        logger.debug(
            msg=f"Mounting /nix/var/knix/{packageName} on {request.target_path}"
        )
        await helpers.mkdir(request.target_path)
        await helpers.run_subprocess(
            [
                "mount",
                "--bind",
                "--verbose",
                f"/nix/var/knix/{packageName}/nix",
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

        # Initialize gcroots.json database
        gcRootsPath = Path("/nix/var/knix/gcroots.json")
        if not gcRootsPath.exists():
            gcRootsPath.parent.mkdir(parents=True)
            gcRootsPath.write_text(json.dumps([]))
        gcRootsList: list = json.loads(gcRootsPath.read_text())
        # Remove gcRoot for the volume we're dismounting now
        gcRootsList = list(
            filter(lambda x: x["targetPath"] != request.target_path, gcRootsList)
        )
        # Remove gcRoot for targetPaths that doesn't exist anymore
        gcRootsList = list(
            filter(lambda x: Path(x["targetPath"]).exists(), gcRootsList)
        )
        # Write gcRoots database back to disk
        gcRootsPath.write_text(json.dumps(gcRootsList))

        # Get all valid gcRoot names
        validRootNames = [d["packageName"] for d in gcRootsList]

        # Loop the directories we wanna clean and remove anything that doesn't belog
        for cleanPath in ["/nix/var/nix/gcroots", "/nix/var/knix"]:
            for gcRoot in Path(cleanPath).iterdir():
                name = (
                    str(gcRoot)
                    .removeprefix("/nix/var/nix/gcroots/")
                    .removeprefix("/nix/var/knix/")
                )
                # Make sure it looks like a package before removing it
                if not bool(re.match(r"^[a-z0-9]{32}-[^-]+-", name)):
                    continue
                # Check that we're not one of the valid path and remove otherwise
                if name not in validRootNames:
                    logger.info(msg=f"Removing {gcRoot}")
                    await helpers.run_subprocess(
                        [
                            "rm",
                            "--recursive",
                            "--force",
                            str(gcRoot),
                        ]
                    )

        # Move this to a scheduler and look further into if there's an easy way
        # to estimate how much garbage-collecting will reclaim.
        # logger.info(msg=f"Collecting garbage")
        # await helpers.run_subprocess([
        #     "nix",
        #     "store",
        #     "gc",
        # ])

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


@kopf.on.create("expressions.knix.cool")  # type: ignore
@kopf.on.update("expressions.knix.cool", field="data.expr")  # type: ignore
async def handleExpression(name, namespace, spec, old, new, diff, **_):
    res = await helpers.kubectlNS(namespace, ["get", helpers.CRDNAME, name])
    obj = json.loads(res.stdout)
    res = await helpers.build(obj["data"]["expr"])
    pass


# @kopf.on.create('pods') # type: ignore
# async def onPodUpdate(name, namespace, spec, old, new, diff, **_):
#     pass
