#! /usr/bin/env python3

import kopf
import logging
import json
import asyncio
import time
import threading
import signal
import sys
import os
import zmq
import zmq.asyncio
from queue import Queue
from typing import Any
from pathlib import Path
from pprint import pprint

sys.path.insert(0, os.getcwd())

import helpers

serviceIP = "10.56.43.203"

ctx = zmq.asyncio.Context()
socket = ctx.socket(zmq.PUB)
socket.bind("tcp://*:5555")  # Listen on all interfaces, port 5555

@kopf.on.startup() # type: ignore
async def on_startup(memo, settings: kopf.OperatorSettings, **_):
    # Plain and simple local endpoint with an auto-generated certificate:
    # settings.admission.server = kopf.WebhookServer()
    settings.admission.server = kopf.WebhookServer(
                                                   addr="0.0.0.0",
                                                   port = 443,
                                                   # host="knix-deployment.default.svc.k8s.shitbox.lillecarl.com",
                                                   host="10.56.43.203",
                                               )
    settings.admission.managed = "knix.is.cool"
    settings.persistence.finalizer = "knix.is.cool/kopf-finalizer"

@kopf.on.cleanup() # type: ignore
async def on_cleanup(memo, logger, **kwargs):
    pass 

async def patchExprStatus(name, namespace, statusobject):
    patchObj = [{
        "op": "replace",
        "path": "/status",
        "value": statusobject,
    }]

    await helpers.run_subprocess([
                                    "kubectl",
                                    f"--namespace={namespace}",
                                    "patch",
                                    "expressions.knix.cool",
                                    "hello",
                                    "--type=json",                                     
                                    "--subresource=status",
                                    f"--patch={json.dumps(patchObj)}"
                                 ])

async def buildExpr(exprName: str, exprNamespace: str, exprData: str):
    # Wait for object to be commited, fix this
    await asyncio.sleep(1)

    # Update status
    await patchExprStatus(exprName, exprNamespace, {
                        "phase": "Pending",
                        "message": "Evaluation successful",
                    })
    # Build expression
    buildResult = await helpers.build(exprData)
    if buildResult.retcode != 0:
        # Build failed
        await patchExprStatus(exprName, exprNamespace, {
                            "phase": "Failed",
                            "message": "Build failed",
                        })

        return

    packageName = str(buildResult.stdout).removeprefix("/nix/store/").removesuffix("/")

    # Build successful
    await patchExprStatus(exprName, exprNamespace, {
                        "phase": "Succeeded",
                        "message": "Build successful",
                        "result": packageName,
                    })

    # We should only build when pod is scheduled
    # socket.send_string(json.dumps({
    #                                   "host": "shitbox",
    #                                   "expr": exprData,
    #                               }))

@kopf.on.mutate('expressions.knix.cool') # type: ignore
async def handle_expressions(name, namespace, body, memo, patch: kopf.Patch, warnings: list[str], **_):
    try:
        expr = body["data"]["expr"]
        print(expr)
        evalResult = await helpers.eval(expr)
        if evalResult.retcode != 0:
            raise kopf.AdmissionError(f"""
Failed to evaluate nix expression
{expr}
stderr: {evalResult.stderr}
""")

        asyncio.create_task(buildExpr(name, namespace, expr))
            
    except Exception as ex:
        pass


# This has to be mutate + create for some reason. Otherwise we get patch errors
@kopf.on.mutate('pods', operation="CREATE") # type: ignore
async def mutate_pods(body, patch, **_):
    try:
        exprObjName = body["metadata"]["annotations"]["knix-expr"]
        namespace = body["metadata"]["namespace"]
        knixExpr = await getKnixExpr(exprObjName, namespace)
    except KeyError as ex:
        return # keyerror just means we don't have the annotation

    packageBasePath = f"/var/lib/knix/nix/var/knix/{knixExpr["status"]["result"]}/nix"

    existingVolumes = []
    try:
        existingVolumes = body["spec"]["volumes"]
    except:
        pass # No existing volumes

    existingVolumes.append({
                                "name": "knix",
                                "hostPath": {
                                    "path": str(packageBasePath),
                                    "type": "Directory",
                                }
                           })

    existingContainers = body["spec"]["containers"]
    for container in existingContainers:
        container["volumeMounts"].append({
                                          "mountPath": "/nix",
                                          "name": "knix",
                                      })

    patch["spec"] = {
        "volumes": existingVolumes,
        "containers": existingContainers
    }

@kopf.on.event('pods') # type: ignore
async def run_builds(event, **_):
    try:
        if event["type"] != "MODIFIED":
            return

        logging.info(msg=json.dumps(event))

        pod = event["object"]
        nodeName = pod["spec"]["nodeName"]
        exprObjName = pod["metadata"]["annotations"]["knix-expr"]
        namespace = pod["metadata"]["namespace"]
        knixExpr = await getKnixExpr(exprObjName, namespace)

        logging.info(msg=f"Sending build {knixExpr["data"]["expr"]} to {nodeName}")
        socket.send_string(json.dumps({
                                          "host": nodeName,
                                          "expr": knixExpr["data"]["expr"],
                                      }))
    except Exception as ex:
        pass

# crName = custom resource name
async def getKnixExpr(crName, namespace) -> dict:
    resourceResult = await helpers.run_subprocess([
                                                      "kubectl",
                                                      "--output=json",
                                                      f"--namespace={namespace}",
                                                      "get",
                                                      "expressions.knix.cool",
                                                      crName,
                                                  ])
    if resourceResult.retcode != 0:
        return {} # Error handling pls

    resourceObject = json.loads(resourceResult.stdout)

    return resourceObject
