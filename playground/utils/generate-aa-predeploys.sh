#!/usr/bin/env bash
#
# Regenerates aa-predeploys.json, the ERC-4337 v0.6 genesis alloc baked into the L1
# genesis by `builder-playground start l1 --bundler <name>`.
#
# Approach: run pimlico's mock-aa-environment contract deployer against a throwaway
# anvil, dump the resulting state, and keep only the accounts needed for v0.6. The
# deployer is used because it is the reference deployment that bundlers are tested
# against; it needs anvil cheatcodes (anvil_setCode, anvil_impersonateAccount, ...),
# which is why the contracts are baked into genesis rather than deployed at runtime
# against reth.
#
# Requires: docker, python3.
#
set -euo pipefail

cd "$(dirname "$0")"

ANVIL_IMAGE="ghcr.io/foundry-rs/foundry:latest"
DEPLOYER_IMAGE="ghcr.io/pimlicolabs/mock-contract-deployer:main"
NETWORK="aa-predeploy-gen"
CONTAINER="aa-predeploy-anvil"
OUT="aa-predeploys.json"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
docker network create "$NETWORK" >/dev/null

echo "==> starting anvil"
docker run -d --name "$CONTAINER" --network "$NETWORK" --platform linux/amd64 \
  --entrypoint anvil "$ANVIL_IMAGE" \
  --host 0.0.0.0 --block-time 0.1 --silent --hardfork prague >/dev/null

for _ in $(seq 1 60); do
  if docker run --rm --network "$NETWORK" --platform linux/amd64 --entrypoint sh "$ANVIL_IMAGE" \
      -c "cast block-number --rpc-url http://$CONTAINER:8545" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "==> deploying the reference ERC-4337 environment"
docker run --rm --network "$NETWORK" --platform linux/amd64 \
  -e ANVIL_RPC="http://$CONTAINER:8545" "$DEPLOYER_IMAGE" >/dev/null

echo "==> dumping state"
docker run --rm --network "$NETWORK" --platform linux/amd64 --entrypoint sh "$ANVIL_IMAGE" \
  -c "cast rpc anvil_dumpState --rpc-url http://$CONTAINER:8545" > dumpstate.hex

echo "==> extracting the v0.6 accounts"
python3 - "$OUT" <<'PY'
import binascii, collections, gzip, json, sys

out_path = sys.argv[1]

with open("dumpstate.hex") as fh:
    payload = fh.read().strip().strip('"')
state = json.loads(gzip.decompress(binascii.unhexlify(payload[2:])))
accounts = {addr.lower(): acct for addr, acct in state["accounts"].items()}

# (address, nonce override, description). Addresses are the canonical CREATE2
# deployments, identical on every chain.
#
# v0.6 rather than v0.7: v0.6 has simulateValidation on the EntryPoint itself, so bundlers
# simulate against the real contract. v0.7 moved simulation into a separate
# EntryPointSimulations that bundlers inject with a state override, and because that is
# deployed bytecode its constructor never runs, leaving its senderCreator immutable at
# zero. That makes account creation through initCode fail with AA13 in safe mode.
TARGETS = [
    ("0x4e59b44847b379578588920cA78FbF26c0B4956C", 1, "Deterministic CREATE2 deployer"),
    ("0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789", None, "EntryPoint v0.6"),
    # deployed by the EntryPoint constructor; the EntryPoint holds its address as an
    # immutable, so account creation reverts with AA13 if it is missing
    ("0x7fc98430eAEdbb6070B35B39D798725049088348", None, "SenderCreator v0.6"),
    ("0x8ABB13360b87Be5EEb1B98647A016adD927a136c", None, "SimpleAccount v0.6 implementation"),
    ("0x9406Cc6185a346906296840746125a0E44976454", None, "SimpleAccountFactory v0.6"),
]

alloc = collections.OrderedDict()
for address, nonce_override, label in sorted(TARGETS, key=lambda t: t[0].lower()):
    account = accounts.get(address.lower())
    if account is None:
        raise SystemExit(f"{label} ({address}) missing from the anvil state dump")

    entry = collections.OrderedDict()
    entry["balance"] = "0x0"
    # the CREATE2 deployer's nonce is normalised: it only counts how many contracts the
    # reference environment deployed through it, and CREATE2 does not depend on it
    nonce = nonce_override if nonce_override is not None else int(account.get("nonce", 0))
    if nonce:
        entry["nonce"] = hex(nonce)
    entry["code"] = account["code"]
    storage = account.get("storage") or {}
    if storage:
        entry["storage"] = collections.OrderedDict(sorted(storage.items()))
    alloc[address] = entry

    size = len(account["code"]) // 2 - 1
    print(f"    {label:36} {address} {size:>6} bytes")

with open(out_path, "w") as fh:
    json.dump(alloc, fh, indent=2)
    fh.write("\n")
PY

rm -f dumpstate.hex
echo "==> wrote $OUT"
