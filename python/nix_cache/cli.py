#! /usr/bin/env python3

import asyncio
import os
import kr8s
import argparse
import logging
import textwrap
from pathlib import Path
from nix_csi.subprocessing import run_captured


async def update_machines(namespace: str):
    """Fetches builder pod info and atomically updates the nix machines file."""
    try:
        builder_nodes = {
            node.name: node
            async for node in kr8s.asyncio.get(
                "nodes", label_selector="nix.csi/builder"
            )
        }

        if not builder_nodes:
            logging.info("No builder nodes found, preparing to clear machines file.")

        arch_map = {
            "amd64": "x86_64-linux",
            "arm64": "aarch64-linux",
        }

        builders = []
        async for pod in kr8s.asyncio.get(
            "pods", namespace=namespace, label_selector={"app": "nix-csi-node"}
        ):
            node_name = pod.spec.nodeName
            if node := builder_nodes.get(node_name):
                k8s_arch = node.metadata.labels.get("kubernetes.io/arch")
                if not k8s_arch:
                    logging.warning(
                        f"Node '{node_name}' missing 'kubernetes.io/arch' label. Skipping pod '{pod.name}'."
                    )
                    continue

                nix_arch = arch_map.get(k8s_arch)
                if not nix_arch:
                    logging.warning(
                        f"Unhandled architecture '{k8s_arch}' for node '{node_name}'. Skipping pod '{pod.name}'."
                    )
                    continue

                # Cluster internal DNS search-domain will sort out the full name
                builders.append(
                    f"ssh-ng://{pod.metadata['name']}.{os.environ['BUILDERS_SERVICE_NAME']}?trusted=1 {nix_arch}"
                )

        machines_path = Path("/etc/machines")
        temp_path = machines_path.with_suffix(".tmp")
        content = "".join(f"{builder}\n" for builder in builders)
        temp_path.write_text(content)
        temp_path.rename(machines_path)

        logging.info(
            f"Atomically updated {machines_path} with {len(builders)} builders."
        )

    except kr8s.NotFoundError:
        logging.warning("Resources not found, skipping update.")
    except Exception:
        logging.exception("An error occurred during update.")


async def update_worker(update_event: asyncio.Event, namespace: str):
    """Waits for an update signal, debounces, and runs the update."""
    while True:
        await update_event.wait()
        update_event.clear()
        logging.info("Change detected. Debouncing for 5 second before update.")
        await asyncio.sleep(5)
        await update_machines(namespace)


async def watch_pods(update_event: asyncio.Event, namespace: str):
    """Watches for pod events and signals for a config update."""
    label_selector = {"app": "nix-csi-node"}
    logging.info(
        f"Watching for pod events in namespace '{namespace}' with selector '{label_selector}'..."
    )
    while True:
        try:
            async for event_type, obj in kr8s.asyncio.watch(
                "pods", namespace=namespace, label_selector=label_selector
            ):
                if event_type not in ["ADDED", "DELETED"]:
                    continue

                logging.info(
                    f"Pod event '{event_type}' for {obj.name}. Triggering update."
                )
                update_event.set()

        except asyncio.CancelledError:
            logging.info("Pod watcher task cancelled.")
            break
        except Exception:
            logging.exception("Pod watch error. Retrying in 15 seconds...")
            await asyncio.sleep(15)


async def watch_nodes(update_event: asyncio.Event):
    """Watches for node label events and signals for a config update."""
    label_selector = "nix.csi/builder"
    logging.info(f"Watching for node events with selector '{label_selector}'...")
    while True:
        try:
            async for event_type, obj in kr8s.asyncio.watch(
                "nodes", label_selector=label_selector
            ):
                if event_type not in ["ADDED", "DELETED"]:
                    continue
                logging.info(
                    f"Node event '{event_type}' for {obj.name}. Triggering update."
                )
                update_event.set()

        except asyncio.CancelledError:
            logging.info("Node watcher task cancelled.")
            break
        except Exception:
            logging.exception("Node watch error. Retrying in 15 seconds...")
            await asyncio.sleep(15)


async def async_main():
    namespace = os.environ["KUBE_NAMESPACE"]

    # This event will be used to signal when an update is needed.
    update_needed_event = asyncio.Event()

    # Trigger an initial update on startup
    update_needed_event.set()

    tasks = [
        asyncio.create_task(update_worker(update_needed_event, namespace)),
        asyncio.create_task(watch_pods(update_needed_event, namespace)),
        asyncio.create_task(watch_nodes(update_needed_event)),
    ]

    await asyncio.gather(*tasks)


def parse_args():
    parser = argparse.ArgumentParser(description="nix CSI driver")
    parser.add_argument(
        "--loglevel",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Set the logging level (default: INFO)",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    logging.getLogger("nix-csi").setLevel(getattr(logging, args.loglevel))

    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        print("Interrupted by user.")


if __name__ == "__main__":
    main()
