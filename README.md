# nix-airgap

Transfer Nix builds to an air-gapped machine.

## Use case

Air-gapped Nix has three workflows:

| Workflow | Imports | Airgap builds |
| --- | --- | ---: |
| `nix-airgap` | CA paths and trusted outputs | Some |
| Trusted import | Whole closure | Little or none |
| Source/FOD-only (“rebuild the world”) | Inputs only | Almost everything |

### `nix-airgap`

Use `nix-airgap` from a connected client to transfer cached outputs and build only
cache misses on the air-gapped host. The `cache.nixos.org` signing key is trusted by
default. Select the cache list per transfer with repeated `--trusted-cache` flags or
`TRUSTED_CACHES`; either replaces the default cache list.

The SSH account need not be a Nix `trusted-user`: `nix-airgap` transfers only paths a
non-trusted account can add—CA paths such as FODs and literal source inputs (e.g. `./.`), the evaluated `.drv` graph, and
outputs from explicitly selected trusted caches.

### Trusted import

If the importing user is trusted by the air-gapped daemon, build normally and copy
the complete closure to removable media, for example with a `file://` binary cache:

```sh
nix build .#whatever
nix copy --to file:///mnt/usb/cache .#whatever

# On the air-gapped machine:
nix copy --from file:///mnt/usb/cache --no-check-sigs /nix/store/...-result
```

This trust model makes `nix-airgap` unnecessary.

### Source/FOD-only transfer (“rebuild the world”)

Transfer flake inputs and FOD/CA dependencies, then build the remaining graph with
substituters disabled. Bootstrap material remains necessary; see the [FOD-only copy script](https://discourse.nixos.org/t/best-practices-for-air-gapped-nixos-servers-with-untrusted-users/79498/11).

## Usage

Build the CLI with Nix:

```sh
nix run .#default -- INSTALLABLE SSH_HOST
```

Example:

```sh
SSH_CONFIG=./vm/ssh_config \
  nix run .#default -- .#demo airgap
```

`INSTALLABLE` may be a flake installable or a `.drv` path. `SSH_HOST` is resolved by
OpenSSH. Set `SSH_CONFIG` when a custom SSH config is needed.

Remote builds do not create a result link by default. Persist one explicitly:

```sh
nix run .#default -- .#demo airgap \
  --remote-out-link /home/test/result
```

The command prints resulting store paths with `--print-out-paths`.

## Planning

Use `--dry-run` to plan locally without SSH, transfers, or builds:

```sh
nix run .#default -- .#demo airgap --dry-run
```

The plan reports trusted-cache, FOD, and remote-build frontiers:

- `--show-cache-frontier` lists each path and source cache.
- `--show-fod-frontier` lists each FOD with `valid ca` or `missing ca` metadata.
- `--show-build-frontier` lists derivations left for the remote machine.

Use them together when needed:

```sh
nix run .#default -- .#demo airgap --dry-run \
  --show-cache-frontier --show-fod-frontier --show-build-frontier
```

Configure caches with either repeated flags or an environment variable:

```sh
nix run .#default -- .#demo airgap \
  --trusted-cache https://cache.nixos.org \
  --trusted-cache https://example-cache.invalid

TRUSTED_CACHES='https://cache.nixos.org https://example-cache.invalid' \
  nix run .#default -- .#demo airgap
```

## Transfer model

The planner walks the derivation graph and checks configured caches via asynchronous,
bounded HTTP narinfo probes.

- Trusted-cache outputs and healthy FODs (`ca != null`) transfer in batch with `nix copy`.
- Broken FOD metadata (`ca = null`) uses bounded concurrent `nix store add` operations,
  reconstructing CA registration from `.drv` metadata and verifying each output path.
- The evaluated `.drv` graph and sources for remote-built DRVs transfer with `nix copy`;
  remote Nix builds the output.

The FOD workaround avoids forwarding untrusted cache signatures. It addresses the
Cachix metadata issue documented in
[cachix/cachix#740](https://github.com/cachix/cachix/issues/740).

## SSH

`SSH_HOST` is passed to both OpenSSH and the Nix `ssh-ng` store URL. Set
`SSH_CONFIG` to an OpenSSH config file when the host needs custom connection settings;
the tool passes it to `ssh` and exports it through `NIX_SSHOPTS` for Nix store operations.

```sh
SSH_CONFIG=/absolute/path/to/ssh_config nix run .#default -- .#demo airgap
```


## Development

Enter the flake development shell, then use uv:

```sh
nix develop
uv lock
uv run nix-airgap --help
```

The production package uses `uv2nix` and `pyproject-nix`. The default package is
also available as `.#airgap`.

The included `vm/` and `.#demo` are development fixtures for testing the transfer flow.

To exercise the demo from the client VM:

```sh
ssh -F ssh_config client
cd /work/vm
SSH_CONFIG=./ssh_config nix run .#default -- .#demo airgap --remote-out-link /tmp/demo
```

Then inspect the result on the air-gapped VM:

```sh
ssh -F ssh_config airgap
ls -l /tmp/demo
```

Checks:

```sh
nix flake check
python3 -m py_compile src/airgap/cli.py
```

### VMs

`nix/vm.nix` defines two VMs:

- `airgap`: hostname `airgap`, isolated network, SSH forwarded to host port `13964`.
- `client`: hostname `client`, full internet access, SSH forwarded to host port `13965`.

Prepare shared SSH key from repository root:

```sh
chmod 600 vm/vm-key
```

Start each VM from `vm/`, in separate terminals. The VM launcher changes into a
temporary directory, so the config uses `$OLDPWD/..` to preserve the live repository share:

```sh
cd vm
nix run ..#nixosConfigurations.airgap.config.system.build.vm
```

```sh
cd vm
nix run ..#nixosConfigurations.client.config.system.build.vm
```

Both VMs use `useBootLoader = true` and a 20 GiB root image. `boot.growPartition`
expands the backing image's root partition and filesystem on first boot. Restart existing
VMs with the new build; delete old qcow files only if they predate the 20 GiB image.

The repository working tree is shared from `vm/..` through a raw 9p mount at
`/run/shared-raw`, then exposed at `/work` through `bindfs` as `test:users`.
Host ownership remains determined by the user launching the VM; no host UID is configured.

From `vm/`, connect using aliases in `ssh_config`:

```sh
ssh -F ssh_config airgap
ssh -F ssh_config client
```

The shared `airgap` SSH alias works from both host and client: host connections use
`127.0.0.1:13964`; client connections use the host gateway at `10.0.2.2:13964`.
