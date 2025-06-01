import os
import asyncio
import logging
import argparse
from . import knix

def parse_args():
    parser = argparse.ArgumentParser(description="knix CSI Driver")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--controller",
        action="store_true",
        help="Run in controller mode"
    )
    group.add_argument(
        "--node",
        action="store_true",
        help="Run in node mode"
    )
    parser.add_argument(
        "--loglevel",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Set the logging level (default: INFO)"
    )
    return parser.parse_args()

async def main_async():
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.loglevel),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s"
    )
    logger = logging.getLogger("knix-csi")
    loglevel_str = logging.getLevelName(logger.getEffectiveLevel())
    logger.info(f"Current log level: {loglevel_str}")

    # Don't log hpack stuff
    hpacklogger = logging.getLogger("hpack.hpack")
    hpacklogger.setLevel(logging.INFO)

    await knix.serve(args)

def main():
    asyncio.run(main_async())

if __name__ == "__main__":
    main()
