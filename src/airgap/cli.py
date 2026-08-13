#!/usr/bin/env python3
"""Copy an installable's closure to an air-gapped Nix machine."""

from __future__ import annotations

import argparse
import asyncio
from typing import Iterable
import httpx
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


def run(*args: str, stdin: str | None = None, quiet: bool = False) -> str:
    command = (
        [args[0], "--extra-experimental-features", "nix-command flakes", *args[1:]]
        if args[0] == "nix"
        else list(args)
    )
    result = subprocess.run(
        command,
        check=True,
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL if quiet else None,
    )
    return result.stdout


CACHE_PROBE_CONCURRENCY = 32
FOD_ADD_CONCURRENCY = 8


def unique(values: Iterable[str]) -> list[str]:
    return sorted(set(values))


async def probe_batch(
    paths: list[str], caches: list[str]
 ) -> dict[str, str | None]:
    limits = httpx.Limits(
        max_connections=CACHE_PROBE_CONCURRENCY,
        max_keepalive_connections=CACHE_PROBE_CONCURRENCY,
    )
    timeout = httpx.Timeout(15.0)
    semaphore = asyncio.Semaphore(CACHE_PROBE_CONCURRENCY)

    async with httpx.AsyncClient(limits=limits, timeout=timeout) as client:
        async def probe(path: str, cache: str) -> tuple[str, str, bool]:
            async with semaphore:
                store_hash = Path(path).name.split("-", 1)[0]
                url = f"{cache.rstrip('/')}/{store_hash}.narinfo"
                try:
                    response = await client.get(url, follow_redirects=True)
                    return path, cache, response.status_code == 200
                except httpx.HTTPError:
                    return path, cache, False

        probes = await asyncio.gather(
            *(probe(path, cache) for path in paths for cache in caches)
        )
    available = {(path, cache): found for path, cache, found in probes}
    return {
        path: next(
            (cache for cache in caches if available[(path, cache)]),
            None,
        )
        for path in paths
    }


async def add_fods(
    fods: list[str],
    fod_specs: dict[str, tuple[str, str, str]],
    remote_store: str,
 ) -> None:
    semaphore = asyncio.Semaphore(FOD_ADD_CONCURRENCY)

    async def add_fod(fod: str) -> None:
        mode, hash_algo, name = fod_specs[fod]
        async with semaphore:
            process = await asyncio.create_subprocess_exec(
                "nix",
                "--extra-experimental-features",
                "nix-command flakes",
                "store",
                "add",
                "--store",
                remote_store,
                "--mode",
                mode,
                "--hash-algo",
                hash_algo,
                "--name",
                name,
                fod,
                stdout=asyncio.subprocess.PIPE,
            )
            stdout, _ = await process.communicate()
        if process.returncode != 0:
            raise RuntimeError(f"FOD add failed: {fod}")
        added = stdout.decode().strip()
        if added != fod:
            raise RuntimeError(
                f"FOD path mismatch: expected {fod}, got {added}"
            )

    await asyncio.gather(*(add_fod(fod) for fod in fods))


def fod_metadata(fods: list[str]) -> dict[str, dict]:
    if not fods:
        return {}
    return json.loads(
        run("nix", "path-info", "--json", "--json-format", "1", *fods)
    )


def split_fods_by_metadata(
    metadata: dict[str, dict],
 ) -> tuple[list[str], list[str]]:
    copyable = [fod for fod, info in metadata.items() if info.get("ca") is not None]
    broken = [fod for fod, info in metadata.items() if info.get("ca") is None]
    return copyable, broken


def _main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installable")
    parser.add_argument("ssh_host")
    parser.add_argument(
        "--trusted-cache",
        action="append",
        dest="trusted_caches",
        default=None,
        help="Trusted binary cache URL; repeat for multiple caches",
    )
    parser.add_argument(
        "--remote-out-link",
        default=None,
        help="Persistent remote result symlink path; omit for no-link",
    )
    parser.add_argument(
        "--show-build-frontier",
        action="store_true",
        help="Print derivations the remote build must realize",
    )
    parser.add_argument(
        "--show-fod-frontier",
        action="store_true",
        help="Print FOD paths in the transfer frontier",
    )
    parser.add_argument(
        "--show-cache-frontier",
        action="store_true",
        help="Print cache paths in the transfer frontier",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Plan transfer without realizing, copying, or building",
    )
    args = parser.parse_args()
    trusted_caches = args.trusted_caches or shlex.split(
        os.environ.get("TRUSTED_CACHES", "https://cache.nixos.org")
    )
    ssh_command = ["ssh"]
    if ssh_config := os.environ.get("SSH_CONFIG"):
        ssh_config = str(Path(ssh_config).resolve())
        ssh_command.extend(["-F", ssh_config])
        os.environ["NIX_SSHOPTS"] = f"-F {ssh_config}"
    remote_store = f"ssh-ng://{args.ssh_host}"
    ssh_command.append(args.ssh_host)

    with tempfile.TemporaryDirectory(prefix="nix-airgap-") as tmp_name:
        tmp = Path(tmp_name)
        if not args.dry_run:
            print("==> Checking SSH")
            subprocess.run([*ssh_command, "true"], check=True)

        print("==> Evaluating")
        derivations = json.loads(
            run("nix", "derivation", "show", "-r", args.installable)
        )["derivations"]
        drv = (
            args.installable
            if args.installable.endswith(".drv")
            else run("nix", "path-info", "--derivation", args.installable).strip()
        )
        root = Path(drv).name
        print(f"    drv: {drv}")

        print("==> Planning cache/FOD frontiers")
        queue = [(root, output) for output in derivations[root]["outputs"]]
        plan: set[tuple[str, str, str]] = set()
        build_drvs = {drv}
        fod_specs: dict[str, tuple[str, str, str]] = {}
        seen: set[tuple[str, str]] = set()

        while queue:
            batch = []
            while queue:
                node, output = queue.pop()
                if (node, output) in seen:
                    continue
                seen.add((node, output))
                data = derivations[node]
                path = data.get("env", {}).get(output)
                if path:
                    batch.append((node, output, data, path))
            cache_results = asyncio.run(
                probe_batch(
                    [path for _, _, _, path in batch],
                    trusted_caches,
                )
            )
            for node, output, data, path in batch:
                cache = cache_results[path]
                if cache:
                    plan.add(("cache", cache, path))
                    continue
                if data.get("outputs", {}).get(output, {}).get("hash") is not None:
                    output_data = data["outputs"][output]
                    hash_algo = output_data["hash"].split("-", 1)[0]
                    fod_specs[path] = (
                        output_data.get("method", "flat"),
                        hash_algo,
                        data["name"],
                    )
                    plan.add(("fod", f"/nix/store/{node}", path))
                    continue
                build_drvs.add(f"/nix/store/{node}")
                for input_drv, input_data in data.get("inputs", {}).get("drvs", {}).items():
                    queue.extend(
                        (Path(input_drv).name, input_output)
                        for input_output in input_data["outputs"]
                    )
        cache_frontier = unique(f"{cache}\t{path}" for kind, cache, path in plan if kind == "cache")
        fod_frontier = unique(f"{drv}\t{path}" for kind, drv, path in plan if kind == "fod")
        fod_drvs = unique(line.split("\t", 1)[0] for line in fod_frontier)
        fods = unique(line.split("\t", 1)[1] for line in fod_frontier)
        fod_info = fod_metadata(fods)

        source_inputs = unique(
            f"/nix/store/{source}"
            for build_drv in build_drvs
            for source in derivations[Path(build_drv).name].get("inputs", {}).get("srcs", [])
        )
        source_closure = set(build_drvs)
        if source_inputs:
            source_closure.update(
                run("nix", "path-info", "--recursive", *source_inputs).splitlines()
            )

        print("==> Transfer plan")
        print(f"    trusted-cache frontier: {len(cache_frontier)} paths")
        print(f"    FOD frontier: {len(fods)} paths")
        print(f"    remote build frontier: {len(build_drvs)} derivations")
        if args.show_fod_frontier:
            print("    FOD paths:")
            for fod in fods:
                status = "valid ca" if fod_info[fod].get("ca") is not None else "missing ca"
                print(f"      {status:<10} {fod}")
        if args.show_cache_frontier:
            print("    cache paths:")
            cache_width = max(
                (len(entry.split("\t", 1)[0]) for entry in cache_frontier),
                default=0,
            )
            for entry in cache_frontier:
                cache, path = entry.split("\t", 1)
                print(f"      {cache:<{cache_width}} {path}")
        if args.show_build_frontier:
            print("    derivations:")
            for build_drv in sorted(build_drvs):
                print(f"      {build_drv}")

        if args.dry_run:
            print("==> Dry run: no paths transferred or built")
            return

        if fod_drvs:
            print("==> Realising FODs locally without substitutes")
            run(
                "nix",
                "build",
                "--no-substitute",
                "--out-link",
                str(tmp / "fod-root"),
                *(f"{fod_drv}^*" for fod_drv in fod_drvs),
            )
        if fods:
            copyable_fods, broken_fods = split_fods_by_metadata(fod_info)
            if copyable_fods:
                print("==> Copying FODs")
                run(
                    "nix",
                    "copy",
                    "--no-recursive",
                    "--to",
                    remote_store,
                    "--stdin",
                    stdin="\n".join(copyable_fods) + "\n",
                )
            if broken_fods:
                # Don't nix copy broken FODs: local metadata may carry an
                # untrusted signature and ca = null. Re-add bytes to remote
                # store from .drv content-addressing metadata instead.
                print("==> Adding broken FODs to remote store")
                asyncio.run(add_fods(broken_fods, fod_specs, remote_store))
        for cache in unique(line.split("\t", 1)[0] for line in cache_frontier):
            paths = [line.split("\t", 1)[1] for line in cache_frontier if line.startswith(f"{cache}\t")]
            if paths:
                print(f"==> Copying trusted-cache frontier: {cache}")
                run("nix", "copy", "--from", cache, "--to", remote_store, "--stdin", stdin="\n".join(paths) + "\n",)

        print("==> Copying derivation/source closure")
        run("nix", "copy", "--no-recursive", "--to", remote_store, "--stdin", stdin="\n".join(unique(source_closure)) + "\n")

        print("==> Building on airgapped machine")
        remote_build_flags = (
            ["--out-link", shlex.quote(args.remote_out_link)]
            if args.remote_out_link
            else ["--no-link"]
        )
        result = subprocess.run(
            [
                *ssh_command,
                "nix",
                "--extra-experimental-features",
                shlex.quote("nix-command flakes"),
                "build",
                *remote_build_flags,
                f"{drv}^*",
            ],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        )
        print(result.stdout, end="")


def main() -> None:
    try:
        _main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            message = f"command failed with exit status {error.returncode}"
            status = error.returncode
        else:
            message = str(error)
            status = 1
        print(f"error: {message}", file=sys.stderr)
        raise SystemExit(status) from None


if __name__ == "__main__":
    main()
