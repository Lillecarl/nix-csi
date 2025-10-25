#! /usr/bin/env python3

import os
import kr8s
from typing import cast
from kr8s.asyncio.objects import Pod, Job, ConfigMap

NAMESPACE = os.environ.get("KUBE_NAMESPACE", "default")
KUBE_NODE_NAME = os.environ.get("KUBE_NODE_NAME", "shitbox")


async def run(storePath: str, expression: str):
    jobName = f"build-{os.path.basename(storePath)[:32]}"
    job: Job | None = None

    try:
        job = await Job.get(jobName, NAMESPACE)
    except kr8s.NotFoundError:
        job = await Job(
            {
                "metadata": {
                    "name": jobName,
                    "annotations": {"nix.csi/storePath": storePath},
                },
                "spec": {
                    "ttlSecondsAfterFinished": 86400,
                    "template": {
                        "spec": {
                            "suspend": True,
                            "containers": [
                                {
                                    "name": "build",
                                    "image": "quay.io/nix-csi/scratch:1.0.0",
                                    "command": [
                                        "build",
                                    ],
                                    "env": [
                                        {
                                            "name": "PATH",
                                            "value": "/nix/var/result/bin",
                                        },
                                        {
                                            "name": "HOME",
                                            "value": "/nix/var/nix-csi/home",
                                        },
                                        {
                                            "name": "USER",
                                            "value": "root",
                                        },
                                        # This is pretty shady and should be reconsidered
                                        {
                                            "name": "NIX_PATH",
                                            "value": os.environ["NIX_PATH"],
                                        },
                                    ],
                                    "volumeMounts": [
                                        {
                                            "name": "nix-store",
                                            "mountPath": "/nix",
                                        },
                                        {
                                            "name": "nix-config",
                                            "mountPath": "/etc/nix",
                                        },
                                        {
                                            "name": "nix-buildinfo",
                                            "mountPath": "/buildinfo",
                                        },
                                        {
                                            "name": "nix-buildscript",
                                            "mountPath": "/buildscript",
                                        },
                                    ],
                                },
                            ],
                            "restartPolicy": "Never",
                            "volumes": [
                                {
                                    "name": "nix-store",
                                    "hostPath": {
                                        "path": "/var/lib/nix-csi/nix",
                                        "type": "Directory",
                                    },
                                },
                                {
                                    "name": "nix-config",
                                    "configMap": {"name": "nix-config"},
                                },
                                {
                                    "name": "nix-buildscript",
                                    "configMap": {"name": "nix-buildscript"},
                                },
                                {
                                    "name": "nix-buildinfo",
                                    "configMap": {"name": jobName},
                                },
                            ],
                        },
                        "affinity": {
                            "nodeAffinity": {
                                "preferredDuringSchedulingIgnoredDuringExecution": [
                                    # Use tagged builders if available
                                    {
                                        "weight": 100,
                                        "preference": {
                                            "matchExpressions": [
                                                {
                                                    "key": "nix.csi/builder",
                                                    "operator": "Exists",
                                                }
                                            ]
                                        },
                                    },
                                    # Use same host that requested the build if available
                                    {
                                        "weight": 50,
                                        "preference": {
                                            "matchExpressions": [
                                                {
                                                    "key": "kubernetes.io/hostname",
                                                    "operator": "In",
                                                    "values": [KUBE_NODE_NAME],
                                                },
                                            ]
                                        },
                                    },
                                ]
                            }
                        },
                    },
                    "backoffLimit": 1,  # amount of restarts allowed
                },
            },
            NAMESPACE,
        )
        await job.create()
        cm = await ConfigMap(
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": jobName,
                },
                "data": {"default.nix": expression},
            },
            NAMESPACE,
        )
        await cm.create()
        await cm.set_owner(job)
        await job.patch({"spec": {"suspend": False}})

    await job.wait(["condition=Complete", "condition=Failed"])

    success = job.status.get("succeeded", 0) == 1
    log = ""

    async for pod in kr8s.asyncio.get(
        "pods",
        namespace=NAMESPACE,
        label_selector={"batch.kubernetes.io/job-name": jobName},
    ):
        pod = cast(Pod, pod)
        log += f"{pod.name=}\n"
        log += "\n".join([line async for line in pod.logs()])

    if success:
        await job.delete(propagation_policy="Foreground")

    return (success, log)
