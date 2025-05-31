#! /usr/bin/env python3

import asyncio
import logging
import sys
import os
import json
import signal
import zmq
import zmq.asyncio
from queue import Queue
from typing import Tuple, Optional
from pathlib import Path

sys.path.insert(0, os.getcwd())

import helpers

baseDir = "/nix/var/knix"

logging.basicConfig(
    level=logging.INFO,  # Set the default logger level
    format="%(asctime)s %(levelname)s %(name)s: %(message)s"
)

logger = logging.getLogger("build")
   
async def realizeExpr(expr: str) -> Optional[str]:
    buildResult = await helpers.build(expr)

    if buildResult.retcode != 0:
        return
    
    packageName = str(buildResult.stdout).removeprefix("/nix/store/").removesuffix("/")
    packagePath = buildResult.stdout
    packageRefPath = f"{baseDir}/{packageName}" 
    packageVarPath =  f"{packageRefPath}/nix/var"
    packageResultPath =  f"{packageRefPath}/nix/var/result"


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
    # Copy package to result folder (/nix/var/nix/result in container)
    # Trailing slashes are essential here to make cp do the right thing
    await helpers.cp(f"{packagePath}/", f"{packageResultPath}/")

    # Copy all dependencies of package into container store
    for path in pathInfoResult.stdout.splitlines():
        res = await helpers.cpp(path, packageRefPath)
        if res.retcode != 0:
            return
        
    return packageName


async def zmqSub(queue):
    ctx = zmq.asyncio.Context()
    socket = ctx.socket(zmq.SUB)
    socket.connect("tcp://10.56.43.203:5555")
    socket.setsockopt_string(zmq.SUBSCRIBE, "")
    logger.info(msg="Started ZMQ sub")

    try:
        while True:
            msg = await socket.recv()
            logger.info(msg=f"Received {msg.decode()}")
            payload = json.loads(msg.decode())
            if os.environ["KNIX_NODENAME"] == payload["host"]:
                # await realizeExpr(payload["expr"])
                await queue.put(payload["expr"])
            else:
                logger.info(f"Received build for other host {payload["host"]}")
    except asyncio.CancelledError:
        pass
    finally:
        socket.close()
        ctx.term()

async def zmqWorker(queue):
    logger.info(msg="Started worker")
    try:
        while True:
            expr = await queue.get()
            logger.info(msg=f"Working {expr}")
            await realizeExpr(expr)
    except asyncio.CancelledError:
        pass


async def main():
    queue = asyncio.Queue()
    subscriber_task = asyncio.create_task(zmqSub(queue))
    worker_task = asyncio.create_task(zmqWorker(queue))

    # Handle ctrl+c
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def stop():
        print("\nReceived exit signal.")
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop)

    await stop_event.wait()
    print("Cancelling tasks...")
    subscriber_task.cancel()
    worker_task.cancel()
    await asyncio.gather(subscriber_task, worker_task, return_exceptions=True)
    print("Shutdown complete.")

if __name__ == "__main__":
    asyncio.run(main())
