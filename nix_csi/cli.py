import asyncio
import logging
import argparse
from . import csi


def parse_args():
    parser = argparse.ArgumentParser(description="nix CSI driver")
    parser.add_argument(
        "--loglevel",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Set the logging level (default: INFO)",
    )
    return parser.parse_args()


async def main():
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.loglevel),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    logger = logging.getLogger("nix-csi")
    loglevel_str = logging.getLevelName(logger.getEffectiveLevel())
    logger.info(f"Current log level: {loglevel_str}")

    await csi.serve()


if __name__ == "__main__":
    asyncio.run(main())
