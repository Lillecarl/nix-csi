import asyncio
import logging
import os
import socket
import sys
import json
import argparse

from pathlib import Path
from typing import Any, Optional
from google.protobuf.wrappers_pb2 import BoolValue
from grpclib.server import Server
from grpclib.exceptions import GRPCError
from grpclib.const import Status
from csi import csi_grpc, csi_pb2

# Hack importpath so we can reach helpers without building a package
sys.path.insert(0, "/knix/python")

import helpers

logger = logging.getLogger("csi.driver")

CSI_PLUGIN_NAME = "knix.csi.store"
CSI_VENDOR_VERSION = "0.1.0"

KUBE_NODE_NAME = os.environ.get("KUBE_NODE_NAME")
if KUBE_NODE_NAME is None:
    raise Exception("Please make sure KUBE_NODE_NAME is set")
KUBE_NODE_NAME = str(KUBE_NODE_NAME)

def log_request(method_name: str, request: Any):
    logger.info("Received %s:\n%s", method_name, request)

async def realizeExpr(expr: str, volume_id: str) -> Optional[str]:
    buildResult = await helpers.build(expr)

    if buildResult.retcode != 0:
        return
    
    packageName = str(buildResult.stdout).removeprefix("/nix/store/").removesuffix("/")
    packagePath = buildResult.stdout
    packageRefPath = f"/nix/var/knix/{volume_id}" 
    packageVarPath =  f"{packageRefPath}/nix/var"
    packageResultPath =  f"{packageRefPath}/nix/var/result"


    if Path(packageRefPath).is_dir():
        logger.info(f"Package {packageName} is already realized at {packageRefPath}")
        return packageName

    # Link package to gcroots
    await helpers.ln(packagePath, f"/nix/var/nix/gcroots/{volume_id}")

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


class IdentityServicer(csi_grpc.IdentityBase):
    async def GetPluginInfo(self, stream):
        request: csi_pb2.GetPluginInfoRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("GetPluginInfoRequest is None")
        log_request("GetPluginInfo", request)
        reply = csi_pb2.GetPluginInfoResponse(
            name=CSI_PLUGIN_NAME,
            vendor_version=CSI_VENDOR_VERSION
        )
        await stream.send_message(reply)

    async def GetPluginCapabilities(self, stream):
        request: csi_pb2.GetPluginCapabilitiesRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("GetPluginCapabilitiesRequest is None")
        log_request("GetPluginCapabilities", request)
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
        log_request("Probe", request)
        reply = csi_pb2.ProbeResponse(ready=BoolValue(value=True))
        await stream.send_message(reply)

class ControllerServicer(csi_grpc.ControllerBase):
    async def CreateVolume(self, stream):
        request: csi_pb2.CreateVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("CreateVolumeRequest is None")
        log_request("CreateVolume", request)

        volume_id = request.name
        capacity_bytes = request.capacity_range.required_bytes if request.capacity_range else 0
        
        pvcResult = await helpers.run_subprocess([
            "kubectl",
            "--all-namespaces",
            "--output=json",
            "get",
            "persistentvolumeclaims",
        ])
        if pvcResult.retcode != 0:
            log_cmderror(pvcResult)

        pvc = None
        try:
            for i in json.loads(pvcResult.stdout)["items"]:
                if i["metadata"]["uid"] in request.name:
                    pvc = i
                    break
                break
        except KeyError:
            logger.info("KeyError")
            pass

        if pvc is None:
            error = f"Failed to find PVC with volumeName {request.name}"
            logger.error(msg=error)
            raise GRPCError(
                Status.INTERNAL,
                error,
            )

        exprName = None
        try:
            exprName = pvc["metadata"]["annotations"]["knix-expr"]
        except KeyError:
            error = f"Failed to get knix-expr annotation from PVC {pvc["metadata"]["name"]}{request.name}"
            logger.error(msg=error)
            raise GRPCError(
                Status.INTERNAL,
                error,
            )

        exprResult = await helpers.run_subprocess([
            "kubectl",
            "--output=json",
            "get",
            "expressions.knix.cool",
            exprName,
        ])

        if exprResult.retcode != 0:
            error = f"Failed to get knix expression {exprName}"
            logger.error(msg=error)
            raise GRPCError(
                Status.INTERNAL,
                error,
            )

        expr = json.loads(exprResult.stdout)["data"]["expr"]

        logger.info(msg=f"Found expression {exprName} with expression {expr}")
        await helpers.build(expr)

        reply = csi_pb2.CreateVolumeResponse(
            volume=csi_pb2.Volume(
                volume_id=volume_id,
                capacity_bytes=capacity_bytes,
                volume_context={"expr": expr},
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
        request: csi_pb2.ControllerPublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ControllerPublishVolumeRequest is None")
        log_request("ControllerPublishVolume", request)
        reply = csi_pb2.ControllerPublishVolumeResponse(
            publish_context={"expr": "PLACEHOLDER"}
        )
        await stream.send_message(reply)

    async def ControllerUnpublishVolume(self, stream):
        request: csi_pb2.ControllerUnpublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ControllerUnpublishVolumeRequest is None")
        log_request("ControllerUnpublishVolume", request)
        reply = csi_pb2.ControllerUnpublishVolumeResponse()
        await stream.send_message(reply)

    async def ValidateVolumeCapabilities(self, stream):
        request: csi_pb2.ValidateVolumeCapabilitiesRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ValidateVolumeCapabilitiesRequest is None")
        log_request("ValidateVolumeCapabilities", request)
        supported = any(
            cap.access_mode.mode == csi_pb2.VolumeCapability.AccessMode.SINGLE_NODE_WRITER
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
        request: csi_pb2.ListVolumesRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ListVolumesRequest is None")
        log_request("ListVolumes", request)
        entries = []
        if os.path.exists("/nix/var/knix"):
            for volume_id in os.listdir("/nix/var/knix"):
                volume_path = os.path.join("/nix/var/knix", volume_id)
                if os.path.isdir(volume_path):
                    entries.append(
                        csi_pb2.ListVolumesResponse.Entry(
                            volume=csi_pb2.Volume(
                                volume_id=volume_id,
                                # volume_context={"hostPath": volume_path}
                            )
                        )
                    )

        reply = csi_pb2.ListVolumesResponse(
            entries=entries,
            next_token=""
        )
        await stream.send_message(reply)

    async def GetCapacity(self, stream):
        request: csi_pb2.GetCapacityRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("GetCapacityRequest is None")
        log_request("GetCapacity", request)
        reply = csi_pb2.GetCapacityResponse(
            available_capacity=2**40  # 1 TB
        )
        await stream.send_message(reply)

    async def ControllerGetCapabilities(self, stream):
        request: csi_pb2.ControllerGetCapabilitiesRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ControllerGetCapabilitiesRequest is None")
        log_request("ControllerGetCapabilities", request)
        reply = csi_pb2.ControllerGetCapabilitiesResponse(
            capabilities=[
                csi_pb2.ControllerServiceCapability(
                    rpc=csi_pb2.ControllerServiceCapability.RPC(
                        type=csi_pb2.ControllerServiceCapability.RPC.CREATE_DELETE_VOLUME
                    )
                ),
                csi_pb2.ControllerServiceCapability(
                    rpc=csi_pb2.ControllerServiceCapability.RPC(
                        type=csi_pb2.ControllerServiceCapability.RPC.LIST_VOLUMES
                    )
                ),
            ]
        )
        await stream.send_message(reply)

    async def CreateSnapshot(self, stream):
        request: csi_pb2.CreateSnapshotRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("CreateSnapshotRequest is None")
        log_request("CreateSnapshot", request)
        reply = csi_pb2.CreateSnapshotResponse()
        await stream.send_message(reply)

    async def DeleteSnapshot(self, stream):
        request: csi_pb2.DeleteSnapshotRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("DeleteSnapshotRequest is None")
        log_request("DeleteSnapshot", request)
        reply = csi_pb2.DeleteSnapshotResponse()
        await stream.send_message(reply)

    async def ListSnapshots(self, stream):
        request: csi_pb2.ListSnapshotsRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ListSnapshotsRequest is None")
        log_request("ListSnapshots", request)
        reply = csi_pb2.ListSnapshotsResponse(entries=[], next_token="")
        await stream.send_message(reply)

    async def ControllerExpandVolume(self, stream):
        request: csi_pb2.ControllerExpandVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ControllerExpandVolumeRequest is None")
        log_request("ControllerExpandVolume", request)
        reply = csi_pb2.ControllerExpandVolumeResponse()
        await stream.send_message(reply)

    async def ControllerGetVolume(self, stream):
        request: csi_pb2.ControllerGetVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("ControllerGetVolumeRequest is None")
        log_request("ControllerGetVolume", request)
        reply = csi_pb2.ControllerGetVolumeResponse(
            volume=csi_pb2.Volume(
                volume_id=request.volume_id,
                # volume_context={"expr": "PLACEHOLDER"}
            )
        )
        await stream.send_message(reply)

    async def ControllerModifyVolume(self, stream):
        request: csi_pb2.ControllerModifyVolumeRequest | None = await stream.recv_message()
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

        logger.debug(msg=f"Looking for Nix expression in volume_context, volume_id: {request.volume_id}")
        expr = None
        for k,v in request.volume_context.items():
            if k == "expr":
                logger.info(msg=f"Got expression {v}")
                expr = v

        if expr is None:
            error = f"Failed to get expr from volume_context"
            logger.error(msg=error)
            raise GRPCError(
                Status.INTERNAL,
                error
            )

        logger.debug(msg=f"Realizing Nix expression: {expr}, volume_id: {request.volume_id}")
        realizeRes = await realizeExpr(expr, request.volume_id)

        logger.debug(msg=f"Creating {request.target_path} if it doesn't exist")
        await helpers.run_subprocess([
            "mkdir",
            "--parents",
            request.target_path,
        ])

        logger.debug(msg=f"Mounting /nix/var/knix/{request.volume_id} on {request.target_path}")
        await helpers.run_subprocess([
            "mount",
            "--bind",
            "--verbose",
            f"/nix/var/knix/{request.volume_id}/nix",
            request.target_path,
        ])

        reply = csi_pb2.NodePublishVolumeResponse()
        await stream.send_message(reply)

    async def NodeUnpublishVolume(self, stream):
        request: csi_pb2.NodeUnpublishVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeUnpublishVolumeRequest is None")
        log_request("NodeUnpublishVolume", request)

        logger.debug(msg=f"Unmounting {request.target_path}")
        await helpers.run_subprocess([
            "umount",
            "--verbose",
            request.target_path,
        ])
        logger.debug(msg=f"Removing /nix/var/knix/{request.volume_id}")
        await helpers.run_subprocess([
            "rm",
            "--recursive",
            "--force",
            f"/nix/var/knix/{request.volume_id}"
        ])
        logger.debug(msg=f"Unlinking /nix/var/nix/gcroots/{request.volume_id}")
        await helpers.run_subprocess([
            "unlink",
            f"/nix/var/nix/gcroots/{request.volume_id}"
        ])
        logger.debug(msg=f"Running garbage collection")
        gcResult = await helpers.run_subprocess([
            "nix",
            "store",
            "gc",
            "--dry-run",
            "--debug",
        ])

        logger.debug(msg=f"nix store gc output:")
        logger.debug(msg=f"stdout: {gcResult.stdout}")
        logger.debug(msg=f"stderr: {gcResult.stderr}")

        reply = csi_pb2.NodeUnpublishVolumeResponse()
        await stream.send_message(reply)

    async def NodeGetCapabilities(self, stream):
        request: csi_pb2.NodeGetCapabilitiesRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetCapabilitiesRequest is None")
        log_request("NodeGetCapabilities", request)
        reply = csi_pb2.NodeGetCapabilitiesResponse(
            capabilities=[
                # csi_pb2.NodeServiceCapability(
                #     rpc=csi_pb2.NodeServiceCapability.RPC(
                #         type=csi_pb2.NodeServiceCapability.RPC.STAGE_UNSTAGE_VOLUME
                #     )
                # ),
            ]
        )
        await stream.send_message(reply)

    async def NodeGetInfo(self, stream):
        request: csi_pb2.NodeGetInfoRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetInfoRequest is None")
        log_request("NodeGetInfo", request)
        # reply = csi_pb2.NodeGetInfoResponse(
        #     node_id=str(KUBE_NODE_NAME),
        #     accessible_topology=csi_pb2.Topology(
        #         segments={
        #             "topology.knix.csi/node": str(KUBE_NODE_NAME)
        #         }
        #     ),
        # )
        reply = csi_pb2.NodeGetInfoResponse(
            node_id=str(KUBE_NODE_NAME),
        )
        await stream.send_message(reply)

    async def NodeGetVolumeStats(self, stream):
        request: csi_pb2.NodeGetVolumeStatsRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeGetVolumeStatsRequest is None")
        log_request("NodeGetVolumeStats", request)
        reply = csi_pb2.NodeGetVolumeStatsResponse()
        await stream.send_message(reply)

    async def NodeExpandVolume(self, stream):
        request: csi_pb2.NodeExpandVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeExpandVolumeRequest is None")
        log_request("NodeExpandVolume", request)
        reply = csi_pb2.NodeExpandVolumeResponse()
        await stream.send_message(reply)

    async def NodeStageVolume(self, stream):
        request: csi_pb2.NodeStageVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeStageVolumeRequest is None")
        log_request("NodeStageVolume", request)
        reply = csi_pb2.NodeStageVolumeResponse()
        await stream.send_message(reply)

    async def NodeUnstageVolume(self, stream):
        request: csi_pb2.NodeUnstageVolumeRequest | None = await stream.recv_message()
        if request is None:
            raise ValueError("NodeUnstageVolumeRequest is None")
        log_request("NodeUnstageVolume", request)
        reply = csi_pb2.NodeUnstageVolumeResponse()
        await stream.send_message(reply)

async def serve(sock_path="/csi/csi.sock"):
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(sock_path)
    sock.listen(128)
    sock.setblocking(False)

    server = Server([
        IdentityServicer(),
        ControllerServicer(),
        NodeServicer(),
    ])
    await server.start(sock=sock)
    logger.info(f"CSI driver (grpclib) listening on unix://{sock_path}")
    await server.wait_closed()

def parse_args():
    parser = argparse.ArgumentParser(description="knix CSI Driver")
    parser.add_argument(
        "--loglevel",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Set the logging level (default: INFO)"
    )
    return parser.parse_args()

if __name__ == "__main__":
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.loglevel),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s"
    )
    loglevel_str = logging.getLevelName(logger.getEffectiveLevel())
    logger.info(f"Current log level: {loglevel_str}")

    # Don't log hpack stuff
    hpacklogger = logging.getLogger("hpack.hpack")
    hpacklogger.setLevel(logging.INFO)

    asyncio.run(serve())
