#! /usr/bin/env python3

import asyncio
import sys
import os
import json
import logging
import zmq
import zmq.asyncio
from fastapi import FastAPI
from hypercorn.asyncio import serve
from hypercorn.config import Config
from queue import Queue

sys.path.insert(0, os.getcwd())

import helpers

logging.basicConfig(
    level=logging.INFO,  # Set the default logger level
    format="%(asctime)s %(levelname)s %(name)s: %(message)s"
)

logger = logging.getLogger("build")

queue = Queue()

async def pub():
    ctx = zmq.asyncio.Context()
    socket = ctx.socket(zmq.PUB)
    socket.bind("tcp://*:5555")  # Listen on all interfaces, port 5555

    try:
        while True:
            expr = await queue.get()
            # expr = "(builtins.getFlake (toString \"/knix\")).legacyPackages.x86_64-linux.hello"
            payload = {
                "host": "shitbox",
                "action": "build",
                "expr": expr,
            }
            msg = json.dumps(payload)
            buildResult = await helpers.build(expr)
            if buildResult.retcode != 0:
                continue
            
            packageName = str(buildResult.stdout).removeprefix("/nix/store/").removesuffix("/")
            logger.info(msg=f"Built {packageName}")
            await socket.send_string(msg)
            logger.info(msg=f"Sent: {msg}")
    except asyncio.CancelledError:
        pass
    finally:
        socket.close()
        ctx.term()

async def comm():
    ctx = zmq.asyncio.Context()
    socket = ctx.socket(zmq.REP)
    socket.bind("tcp://*:5556")
    try:
        while True:
            msg = await socket.recv_string()
            payload = json.loads(msg)
            logging.info(msg=f"Received message, payload {msg}")

            if payload["action"] == "opbuild":
                buildResult = await helpers.build(payload["expr"])
                if buildResult.retcode != 0:
                    return

                packageName = str(buildResult.stdout).removeprefix("/nix/store/").removesuffix("/")
                socket.send_string(packageName)

            if payload["action"] == "dsbuild":
                queue.put(payload["expr"])
                socket.send_string("")
    except asyncio.CancelledError:
        pass
    finally:
        socket.close()
        ctx.term()


def fastapi_app():
    app = FastAPI()

    @app.get("/")
    async def root():
        return {"message": "Hello, Async World!"}

    return app

async def fastapi_server():
    app = fastapi_app()
    config = Config()
    config.bind = ["0.0.0.0:5556"]
    await serve(app, config)

async def main():
    await asyncio.gather(pub(), fastapi_server())
    
if __name__ == "__main__":
    asyncio.run(main())
