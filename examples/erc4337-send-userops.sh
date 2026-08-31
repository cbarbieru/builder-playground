#!/usr/bin/env bash
#
# Creates ERC-4337 accounts and sends UserOperations through the playground's bundler.
#
#   builder-playground start l1 --bundler alto      # or --bundler rundler
#   ./examples/erc4337-send-userops.sh [ACCOUNTS] [OPS_PER_ACCOUNT]
#
# Accounts are created by calling SimpleAccountFactory.createAccount directly, which is
# the supported path: alto's gas estimator cannot deploy accounts through initCode.
#
# Needs curl and either foundry's `cast` on PATH or docker (a foundry container is used
# as a fallback).
#
set -euo pipefail

ACCOUNTS=${1:-3}
OPS_PER_ACCOUNT=${2:-1}

# ERC-4337 v0.6, predeployed at genesis by --bundler
ENTRY_POINT=0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789
FACTORY=0x9406Cc6185a346906296840746125a0E44976454

# the first static prefunded account owns every smart account we create
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
OWNER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

RECIPIENT=0x000000000000000000000000000000000000dEaD
FUNDING=1ether

port() {
  builder-playground port "$1" "$2" 2>/dev/null | tr -d '[:space:]'
}

EL_PORT=$(port el http)
BUNDLER_PORT=$(port bundler http)
if [[ -z "$EL_PORT" || -z "$BUNDLER_PORT" ]]; then
  echo "error: could not read the playground ports. Is it running with --bundler?" >&2
  echo "       start it with: builder-playground start l1 --bundler alto" >&2
  exit 1
fi

# the bundler is always reached from this host over its published port
BUNDLER_URL="http://localhost:${BUNDLER_PORT}"

if command -v cast >/dev/null 2>&1; then
  RPC_URL="http://localhost:${EL_PORT}"
  cast_() { cast "$@"; }
else
  # no local foundry: run cast in a container. Joining the playground's own network and
  # addressing the execution client by service name is more reliable than reaching back
  # out to the host.
  PLAYGROUND_NETWORK=${PLAYGROUND_NETWORK:-$(docker network ls --format '{{.Name}}' |
    grep '^builder-playground-' | head -1)}
  if [[ -n "$PLAYGROUND_NETWORK" ]]; then
    RPC_URL="http://el:8545"
    cast_() {
      docker run --rm --platform linux/amd64 --network "$PLAYGROUND_NETWORK" \
        -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
        --entrypoint cast ghcr.io/foundry-rs/foundry:latest "$@"
    }
  else
    RPC_URL="http://host.docker.internal:${EL_PORT}"
    cast_() {
      docker run --rm --platform linux/amd64 -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
        --entrypoint cast ghcr.io/foundry-rs/foundry:latest "$@"
    }
  fi
fi

rpc() { # rpc METHOD PARAMS_JSON
  curl -s -X POST "$BUNDLER_URL" -H 'Content-Type: application/json' \
    --data-binary "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}

json() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

echo "execution client : $RPC_URL"
echo "bundler          : $BUNDLER_URL"
echo "entry point      : $(rpc eth_supportedEntryPoints '[]' | json 'd["result"][0]')"
echo

# ---------------------------------------------------------------- create accounts
declare -a SMART_ACCOUNTS=()
for ((i = 1; i <= ACCOUNTS; i++)); do
  salt=$(( $(date +%s) % 100000 * 1000 + i ))
  cast_ send "$FACTORY" "createAccount(address,uint256)" "$OWNER" "$salt" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" >/dev/null
  addr=$(cast_ call "$FACTORY" "getAddress(address,uint256)(address)" "$OWNER" "$salt" \
    --rpc-url "$RPC_URL" | tr -d '[:space:]')
  # the account pays its own prefund, so it needs a balance
  cast_ send "$addr" --value "$FUNDING" --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" >/dev/null
  SMART_ACCOUNTS+=("$addr")
  echo "created account $i/$ACCOUNTS: $addr"
done
echo

# ---------------------------------------------------------------- send user operations
sent=0
failed=0

send_user_op() { # send_user_op ACCOUNT
  local account=$1

  local nonce call_data
  nonce=$(cast_ call "$ENTRY_POINT" "getNonce(address,uint192)(uint256)" "$account" 0 \
    --rpc-url "$RPC_URL" | tr -d '[:space:]')
  call_data=$(cast_ calldata "execute(address,uint256,bytes)" "$RECIPIENT" 1 0x | tr -d '[:space:]')

  local fee=3000000000 tip=1000000000
  local cgl=500000 vgl=1000000 pvg=100000

  # The account verifies a real signature even while estimating, so sign the operation at
  # its placeholder gas values first, then sign again once the bundler has priced it (the
  # hash covers the gas fields).
  local signature unsigned estimate
  signature=$(sign_user_op "$account" "$nonce" "$call_data" "$cgl" "$vgl" "$pvg" "$fee" "$tip")
  unsigned=$(user_op_json "$account" "$nonce" "$call_data" "$cgl" "$vgl" "$pvg" "$fee" "$tip" "$signature")
  estimate=$(rpc eth_estimateUserOperationGas "[$unsigned,\"$ENTRY_POINT\"]")
  if [[ -n "$(echo "$estimate" | json 'd.get("error","")')" ]]; then
    echo "  estimate failed: $(echo "$estimate" | json 'json.dumps(d["error"])')" >&2
    return 1
  fi
  cgl=$(echo "$estimate" | json 'int(d["result"]["callGasLimit"],16)')
  vgl=$(echo "$estimate" | json 'int(d["result"]["verificationGasLimit"],16)')
  pvg=$(echo "$estimate" | json 'int(d["result"]["preVerificationGas"],16)')

  local signed
  signature=$(sign_user_op "$account" "$nonce" "$call_data" "$cgl" "$vgl" "$pvg" "$fee" "$tip")
  signed=$(user_op_json "$account" "$nonce" "$call_data" "$cgl" "$vgl" "$pvg" "$fee" "$tip" "$signature")

  local response op_hash
  response=$(rpc eth_sendUserOperation "[$signed,\"$ENTRY_POINT\"]")
  op_hash=$(echo "$response" | json 'd.get("result","")')
  if [[ -z "$op_hash" ]]; then
    echo "  send failed: $(echo "$response" | json 'json.dumps(d.get("error"))')" >&2
    return 1
  fi

  # wait for it to be bundled and mined
  local receipt tx
  for _ in $(seq 1 45); do
    receipt=$(rpc eth_getUserOperationReceipt "[\"$op_hash\"]")
    tx=$(echo "$receipt" | json 'd["result"]["receipt"]["transactionHash"] if d.get("result") else ""')
    if [[ -n "$tx" ]]; then
      local ok
      ok=$(echo "$receipt" | json 'd["result"]["success"]')
      echo "  userop $op_hash success=$ok tx=$tx"
      [[ "$ok" == "True" || "$ok" == "true" ]] && return 0 || return 1
    fi
    sleep 1
  done
  echo "  timed out waiting for $op_hash" >&2
  return 1
}

sign_user_op() { # sender nonce callData cgl vgl pvg fee tip -> signature
  # the EntryPoint hashes every field except the signature, so ask it rather than
  # reimplementing the packing
  local tuple hash
  tuple="($1,$2,0x,$3,$4,$5,$6,$7,$8,0x,0x)"
  hash=$(cast_ call "$ENTRY_POINT" \
    "getUserOpHash((address,uint256,bytes,bytes,uint256,uint256,uint256,uint256,uint256,bytes,bytes))(bytes32)" \
    "$tuple" --rpc-url "$RPC_URL" | tr -d '[:space:]')
  cast_ wallet sign --private-key "$OWNER_KEY" "$hash" | tr -d '[:space:]'
}

user_op_json() { # sender nonce callData cgl vgl pvg fee tip signature
  python3 -c "
import sys
s,n,cd,cgl,vgl,pvg,fee,tip,sig = sys.argv[1:10]
print(__import__('json').dumps({
  'sender': s, 'nonce': hex(int(n)), 'initCode': '0x', 'callData': cd,
  'callGasLimit': hex(int(cgl)), 'verificationGasLimit': hex(int(vgl)),
  'preVerificationGas': hex(int(pvg)), 'maxFeePerGas': hex(int(fee)),
  'maxPriorityFeePerGas': hex(int(tip)), 'paymasterAndData': '0x', 'signature': sig}))" "$@"
}

for account in "${SMART_ACCOUNTS[@]}"; do
  echo "sending $OPS_PER_ACCOUNT userop(s) from $account"
  for ((j = 1; j <= OPS_PER_ACCOUNT; j++)); do
    if send_user_op "$account"; then sent=$((sent + 1)); else failed=$((failed + 1)); fi
  done
done

echo
echo "sent $sent, failed $failed"
[[ $failed -eq 0 ]]
