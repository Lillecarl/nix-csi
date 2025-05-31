#! /usr/bin/env python3

import asyncio
import json
import zmq
import zmq.asyncio

async def main():
    context = zmq.asyncio.Context()
    socket = context.socket(zmq.REQ)
    print("Connecting")
    socket.connect("tcp://10.56.43.203:5556")
    print("Connected, sending payload")
    await socket.send_string(json.dumps({
                               "action": "opbuild",
                               "expr": "(import /knix/default.nix).legacyPackages.x86_64-linux.hello",

                           }))
    print("Payload sent, waiting for response")
    response = await socket.recv_string()
    print("Received response")
    print(response)

if __name__ == "__main__":
    asyncio.run(main())
    
