#! /usr/bin/env python3

import asyncio
import logging

logger = logging.getLogger("helpers")

class ProcRet:
    def __init__(self, retcode: int, stdout: str, stderr: str):
        self.retcode = retcode
        self.stdout = stdout
        self.stderr = stderr

async def run_subprocess(cmd: list[str]) -> ProcRet:
    logger.debug(f"Running command: {' '.join(cmd)}")
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
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

    return ProcRet(retcode, stdout.decode().rstrip(), stderr.decode().rstrip())

async def cp(src: str, dst: str, args: list[str] = []) -> ProcRet:
    commonArgs = [
        "cp",
        "--recursive",
        "--reflink=always",
        "--archive",
    ]

    result = await run_subprocess(commonArgs + args + [ src, dst])

    return result

async def cpp(src: str, dst: str) -> ProcRet:
    return await cp(src, dst, ["--parents"])

async def ln(pointer: str, symlink: str) -> ProcRet:
    return await run_subprocess([
                                    "ln",
                                    "--symbolic",
                                    "--force",
                                    pointer,
                                    symlink,  
                                ])

async def mkdir(path: str) -> ProcRet:
    result = await run_subprocess([
        "mkdir",
        "--parents",
        path,
    ])

    return result


async def eval(expr: str) -> ProcRet:
    result = await run_subprocess([
        "nix",
        "eval",
        "--impure",
        "--expr",
        expr,
    ])

    return result

async def build(expr: str) -> ProcRet:
    result = await run_subprocess([
        "nix",
        "build",
        "--no-link",
        "--print-out-paths",
        "--impure",
        "--expr",
        expr,
    ])

    return result

async def pathInfo(expr: str) -> ProcRet:
    result = await run_subprocess([
        "nix",
        "path-info",
        "--recursive",
        "--impure",
        "--expr",
        expr,
    ])

    return result
