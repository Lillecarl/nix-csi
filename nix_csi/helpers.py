#! /usr/bin/env python3

import asyncio
import logging
import json

logger = logging.getLogger("helpers")

class ProcRet:
    def __init__(self, retcode: int, stdout: str, stderr: str, cmd: str):
        self.retcode = retcode
        self.stdout = stdout
        self.stderr = stderr
        self.cmd = cmd


# simple subprocess function with automatic error printing
async def run_subprocess(*cmd, silent=False) -> ProcRet:
    if not silent:
        logger.debug(f"Running command: {' '.join(cmd)}")
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    stdout, stderr = await proc.communicate()

    retcode = proc.returncode
    if retcode is None:
        raise Exception("No returncode from command, wtf?")

    if retcode != 0:
        logger.error(msg=f"Command error, code: {retcode}")
        logger.error(f"Command: {' '.join(cmd)}")
        logger.error(msg="stdout:")
        logger.error(msg=stdout.decode())
        logger.error(msg="stderr:")
        logger.error(msg=stderr.decode())

    return ProcRet(
        retcode, stdout.decode().rstrip(), stderr.decode().rstrip(), " ".join(cmd)
    )


# simple subprocess function with automatic error printing
async def run_subprocess2(*cmd, silent=False) -> ProcRet:
    if not silent:
        logger.debug(f"Running command: {' '.join(cmd)}")
    proc = await asyncio.create_subprocess_exec(*cmd)
    await proc.wait()

    retcode = proc.returncode
    if retcode is None:
        raise Exception("No returncode from command, wtf?")

    if retcode != 0:
        logger.error(msg=f"Command error, code: {retcode}")
        logger.error(f"Command: {' '.join(cmd)}")
        logger.error(msg="stdout:")

    return ProcRet(retcode, "", "", " ".join(cmd))


async def kubectlNS(namespace: str, args: list[str]):
    base = [
        "kubectl",
        f"--namespace={namespace}",
        "--output=json",
    ]
    final = base + args
    return await run_subprocess(final)
