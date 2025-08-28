from collections import deque
import os
import asyncio
import logging
import argparse
import threading
from . import cknix


def parse_args():
    parser = argparse.ArgumentParser(description="cknix CSI Driver")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--controller", action="store_true", help="Run in controller mode"
    )
    group.add_argument("--node", action="store_true", help="Run in node mode")
    parser.add_argument(
        "--loglevel",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Set the logging level (default: INFO)",
    )
    return parser.parse_args()


async def expressionQueueWorker(expressionQueue: asyncio.Queue[str]):
    logger = logging.getLogger("cknix-csi")
    expressionDeque: deque[str] = deque()
    try:
        while True:
            expressionDeque.append(await expressionQueue.get())
            seen = set()
            newExpressionDeque = deque()
            for item in expressionDeque:
                if item not in seen:
                    seen.add(item)
                    newExpressionDeque.append(item)
            expressionDeque = newExpressionDeque

            for expr in expressionDeque:
                logger.info(f"Building Nix expression: {expr}")
                await cknix.realizeExpr(expr)

    except asyncio.CancelledError:
        pass

async def main_async():
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.loglevel),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    logger = logging.getLogger("cknix-csi")
    loglevel_str = logging.getLevelName(logger.getEffectiveLevel())
    logger.info(f"Current log level: {loglevel_str}")

    # Don't log hpack stuff
    hpacklogger = logging.getLogger("hpack.hpack")
    hpacklogger.setLevel(logging.INFO)

    await cknix.serve(args)

def main():
    asyncio.run(main_async())


if __name__ == "__main__":
    main()
