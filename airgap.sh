#!/usr/bin/env bash
set -euo pipefail

installable="${1:-.#demo}"

ssh_config="${SSH_CONFIG:-ssh_config}"
ssh_host="${SSH_HOST:-airgap}"
remote_store="ssh-ng://${ssh_host}"
trusted_caches=( ${TRUSTED_CACHES:-https://cache.nixos.org} )

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ssh_config="$(realpath "$ssh_config")"
export NIX_SSHOPTS="-F $ssh_config"

echo "==> Checking SSH"
ssh -F "$ssh_config" "$ssh_host" true

echo "==> Evaluating"
nix derivation show -r "$installable" > "$tmp/derivations.json"

drv="$(nix path-info --derivation "$installable")"
root_drv="$(basename "$drv")"
echo "    drv: $drv"

echo "==> Planning cache/FOD frontiers"
jq -r \
  --arg root "$root_drv" \
  '.derivations[$root].outputs | keys[] | [$root, .] | @tsv' \
  "$tmp/derivations.json" > "$tmp/queue.tsv"
: > "$tmp/plan.tsv"
printf '%s\n' "$drv" > "$tmp/build-drvs"

probe_cache() {
  local path="$1"
  local cache

  for cache in "${trusted_caches[@]}"; do
    if nix path-info \
        --store "$cache" \
        --json \
        --json-format 1 \
        "$path" \
        >/dev/null 2>&1
    then
      printf '%s\n' "$cache"
      return 0
    fi
  done
  return 1
}

declare -A seen
while IFS=$'\t' read -r node output; do
  key="$node:$output"
  [[ -n "${seen[$key]:-}" ]] && continue
  seen[$key]=1

  path="$(jq -r \
    --arg node "$node" \
    --arg output "$output" \
    '.derivations[$node].env[$output] // empty' \
    "$tmp/derivations.json")"
  [[ -n "$path" ]] || continue

  if cache="$(probe_cache "$path")"; then
    printf 'cache\t%s\t%s\n' "$cache" "$path" >> "$tmp/plan.tsv"
    continue
  fi

  if jq -e \
      --arg node "$node" \
      --arg output "$output" \
      '.derivations[$node].outputs[$output].hash? != null' \
      "$tmp/derivations.json" >/dev/null
  then
    printf 'fod\t/nix/store/%s\t%s\n' "$node" "$path" >> "$tmp/plan.tsv"
    continue
  fi
  printf '/nix/store/%s\n' "$node" >> "$tmp/build-drvs"

  jq -r \
    --arg node "$node" \
    '.derivations[$node].inputs.drvs
     | to_entries[]
     | .key as $input
     | .value.outputs[]
     | [$input, .]
     | @tsv' \
    "$tmp/derivations.json" >> "$tmp/queue.tsv"
done < "$tmp/queue.tsv"
sort -u "$tmp/plan.tsv" -o "$tmp/plan.tsv"

awk -F '\t' '$1 == "cache" { print $2 "\t" $3 }' "$tmp/plan.tsv" > "$tmp/cache-frontier.tsv"
awk -F '\t' '$1 == "fod" { print $2 "\t" $3 }' "$tmp/plan.tsv" > "$tmp/fod-frontier.tsv"
cut -f1 "$tmp/fod-frontier.tsv" | sort -u > "$tmp/fod-drvs"
cut -f2 "$tmp/fod-frontier.tsv" | sort -u > "$tmp/fods"
sort -u "$tmp/build-drvs" -o "$tmp/build-drvs"

while read -r build_drv; do
  node="${build_drv##*/}"
  jq -r \
    --arg node "$node" \
    '.derivations[$node].inputs.srcs[]? | "/nix/store/\(.)"' \
    "$tmp/derivations.json"
done < "$tmp/build-drvs" | sort -u > "$tmp/source-inputs"

{
  cat "$tmp/build-drvs"
  if [[ -s "$tmp/source-inputs" ]]; then
    mapfile -t source_inputs < "$tmp/source-inputs"
    nix-store --query --requisites "${source_inputs[@]}"
  fi
} | sort -u > "$tmp/source-closure"

echo "==> Transfer plan"
printf '    trusted-cache frontier: %s paths\n' "$(wc -l < "$tmp/cache-frontier.tsv")"
printf '    FOD frontier: %s paths\n' "$(wc -l < "$tmp/fods")"

if [[ -s "$tmp/fod-drvs" ]]; then
  echo "==> Realising FODs locally"
  mapfile -t fod_drvs < "$tmp/fod-drvs"
  nix-store --add-root "$tmp/fod-root" --realise "${fod_drvs[@]}"
fi

if [[ -s "$tmp/fods" ]]; then
  echo "==> Copying FODs"
  nix copy \
    --no-recursive \
    --to "$remote_store" \
    --stdin < "$tmp/fods"
fi

if [[ -s "$tmp/cache-frontier.tsv" ]]; then
  echo "==> Copying trusted-cache frontier"
  while read -r cache; do
    awk -F '\t' -v cache="$cache" '$1 == cache { print $2 }' \
      "$tmp/cache-frontier.tsv" |
      nix copy \
        --from "$cache" \
        --to "$remote_store" \
        --stdin
  done < <(cut -f1 "$tmp/cache-frontier.tsv" | sort -u)
fi

echo "==> Copying derivation/source closure"
nix copy \
  --no-recursive \
  --to "$remote_store" \
  --stdin < "$tmp/source-closure"

echo "==> Building on airgapped machine"
ssh -F "$ssh_config" "$ssh_host" \
  "nix-store --realise '$drv'"
