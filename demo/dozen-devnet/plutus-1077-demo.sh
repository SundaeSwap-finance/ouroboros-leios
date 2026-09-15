#!/usr/bin/env bash
# Manual demo for issue #1077: submit a tx whose declared Plutus ExUnits
# exceed the old per-tx limit (maxTxExUnits) but stay under the new
# EB-aggregate limit (maxBlockExUnits) that ouroboros-consensus's patched
# txMeasureAlonzo now uses. Run from inside the dev-demo-dozen-devnet nix
# shell, from anywhere (all paths below are absolute).
#
# Order of operations:
#   0. plain self-payment (no script at all) -- proves basic submit ->
#      on-chain-inclusion works on this devnet. Verified to land on-chain
#      before moving on.
#   1. a VALID Plutus spend (ExUnits comfortably inside maxTxExUnits) --
#      proves the script/datum/redeemer/collateral/protocol-params pipeline
#      works at all, before touching the actual thing under test.
#   2. the OVERSIZED Plutus spend (ExUnits between maxTxExUnits and
#      maxBlockExUnits) -- the actual #1077 patch validation.
set -euo pipefail

DOZEN=/tmp/dozen-devnet
NODE_SOCKET=$DOZEN/relay11/node.socket
MAGIC=164
CLI="/Users/pascal/git/github.com/LEIOS/IntersectMBO/cardano-cli/dist-newstyle/build/x86_64-linux/ghc-9.12.3/cardano-cli-11.2.2.0/x/cardano-cli/build/cardano-cli/cardano-cli dijkstra"

# v1, not v2: this devnet's live ledger state has no PlutusV2 cost model
# (confirmed 2026-09-14 -- `NoCostModel PlutusV2` on submit, consistent with
# the bug #3 "bonus" observation that the live ppCostModels CBOR only carries
# keys 0/V1 and 2/V3, never 1/V2 -- despite alonzo-genesis.json defining one).
# Any PlutusV2 tx is therefore unvalidatable here regardless of what our
# protocol-params-file says; v1/always-succeeds-spending.plutus sidesteps it.
SCRIPT=/Users/pascal/git/github.com/LEIOS/IntersectMBO/cardano-node/scripts/plutus/scripts/v1/always-succeeds-spending.plutus

# utxo1, not delegator1: delegator{1,2,3} are actively drained/recycled by the
# three running tx-firehose instances (same "pick the largest UTxO" greedy
# strategy as this script), which raced us for the same input and caused
# AllInputsAreSpent on an earlier attempt. utxo1 is a genesis UTxO key that
# nothing else touches (verified: absent from process-compose.yaml/run.sh).
KEYDIR=/Users/pascal/git/github.com/LEIOS/input-output-hk/ouroboros-leios/demo/proto-devnet/config/utxo-keys/utxo1
FUNDING_SKEY=$KEYDIR/utxo.skey

WORKDIR=$(mktemp -d)
echo "scratch dir: $WORKDIR"

# Live query, not a static genesis-derived fixture: `cardano-cli query
# protocol-parameters` used to hang forever against this node (bug #3 in the
# task notes), forcing a hand-built protocol-params-dijkstra.json as a
# workaround. Confirmed fixed 2026-09-15 -- querying live again.
PROTOCOL_PARAMS=$WORKDIR/protocol-params.json
$CLI query protocol-parameters --socket-path "$NODE_SOCKET" \
  --testnet-magic $MAGIC --out-file "$PROTOCOL_PARAMS"

# Poll `query utxo` at $1 until it has an entry whose txid is not in the
# comma-separated exclude list $2 ("__none__" if there's nothing to exclude),
# or give up after 5 minutes. query utxo only reflects confirmed blocks, never
# the mempool, so this is how we detect on-chain inclusion rather than mere
# mempool acceptance. This devnet's block rate is slow and uneven (observed:
# ~1 block per 20-30s on average, sometimes much longer).
wait_for_new_utxo() {
  local addr=$1 exclude=$2 out_file=$3
  local found=null
  for _ in $(seq 1 50); do
    sleep 6
    $CLI query utxo --address "$addr" --socket-path "$NODE_SOCKET" \
      --testnet-magic $MAGIC --out-file "$out_file"
    found=$(jq -r --arg excl "$exclude" \
      'to_entries
       | map(select(([.key] - ($excl | split(","))) != []))
       | max_by(.value.value.lovelace) | .key // "null"' \
      "$out_file")
    [ "$found" != "null" ] && { echo "$found"; return 0; }
    echo "  ...not yet, retrying" >&2
  done
  return 1
}

# Comma-joined UTxO keys currently at $1 (or "__none__" if empty), for use as
# wait_for_new_utxo's exclude list.
snapshot_utxo_keys() {
  local addr=$1 out_file=$2
  local keys
  $CLI query utxo --address "$addr" --socket-path "$NODE_SOCKET" \
    --testnet-magic $MAGIC --out-file "$out_file"
  keys=$(jq -r 'keys | join(",")' "$out_file")
  echo "${keys:-__none__}"
}

# Lock $2 lovelace at the script address with a trivial datum-hash datum
# (not inline: PlutusV1 scripts cannot be used in a tx alongside an inline
# datum -- ledger rule InlineDatumsNotSupported,
# cardano-ledger/eras/babbage/impl/.../Babbage/TxInfo.hs:117-118, confirmed
# live 2026-09-14 right after switching this demo's script from v2 to v1 for
# the missing-cost-model bug -- so the datum has to travel as a hash+witness
# pair instead), spending $1 (an input at FUNDING_ADDR); returns the new
# script utxo.
lock_at_script() {
  local funding_txin=$1 lock_amount=$2 label=$3
  local fee=300000
  local funding_lovelace
  funding_lovelace=$(jq -r --arg k "$funding_txin" '.[$k].value.lovelace' "$WORKDIR/funding-utxo.json")
  local change=$((funding_lovelace - lock_amount - fee))

  # SCRIPT_ADDR is deterministic across runs of this script, and earlier
  # (partial/failed) runs commonly leave a locked output sitting there
  # unspent (step 2 -- the only thing that would spend it -- often never
  # runs). Snapshotting and excluding whatever's already there, instead of
  # the old "__none__", is what makes wait_for_new_utxo below actually wait
  # for *this* run's tx instead of matching a leftover from a previous one on
  # its very first poll (which then also skipped the real confirmation wait,
  # racing every step downstream against on-chain state that hadn't landed
  # yet -- confirmed root cause of a BadInputsUTxO/InsufficientCollateral
  # failure on 2026-09-14).
  local existing_script_utxos
  existing_script_utxos=$(snapshot_utxo_keys "$SCRIPT_ADDR" "$WORKDIR/$label-script-utxo-before.json")

  # `set -e` does not propagate out of this function: both call sites invoke
  # it as `if ! X=$(lock_at_script ...); then`, and bash suspends errexit for
  # every command run while evaluating the tested command of an if/while/
  # until -- including, transitively, everything a function called there
  # does. Without an explicit check here, a failing build-raw/sign/submit
  # below would silently fall through into wait_for_new_utxo, which then
  # burns its full 5-minute timeout waiting for a tx that was never
  # submitted (confirmed live 2026-09-14: a build-raw failure on the first
  # oversized-lock attempt was followed by sign/submit both failing on a
  # missing input file, then a pointless 5-minute wait). `exit 1` is used
  # instead of `return 1` because it terminates unconditionally regardless of
  # that same suppression.
  echo "=== $label: lock ${lock_amount} lovelace at the script address, datum-hash datum ===" >&2
  $CLI transaction build-raw \
    --tx-in "$funding_txin" \
    --tx-out "${SCRIPT_ADDR}+${lock_amount}" \
    --tx-out-datum-hash-value 0 \
    --tx-out "${FUNDING_ADDR}+${change}" \
    --fee $fee \
    --out-file "$WORKDIR/$label.txbody" >&2 \
    || { echo "$label: transaction build-raw failed -- aborting" >&2; exit 1; }

  $CLI transaction sign \
    --tx-body-file "$WORKDIR/$label.txbody" --signing-key-file "$FUNDING_SKEY" \
    --testnet-magic $MAGIC --out-file "$WORKDIR/$label.tx" >&2 \
    || { echo "$label: transaction sign failed -- aborting" >&2; exit 1; }

  $CLI transaction submit --tx-file "$WORKDIR/$label.tx" \
    --socket-path "$NODE_SOCKET" --testnet-magic $MAGIC >&2 \
    || { echo "$label: transaction submit failed -- aborting" >&2; exit 1; }

  echo "--- waiting for $label to land on-chain ---" >&2
  wait_for_new_utxo "$SCRIPT_ADDR" "$existing_script_utxos" "$WORKDIR/$label-script-utxo.json"
}

FUNDING_ADDR=$($CLI address build \
  --payment-verification-key-file "$KEYDIR/utxo.vkey" \
  --testnet-magic $MAGIC)

SCRIPT_ADDR=$($CLI address build \
  --payment-script-file "$SCRIPT" \
  --testnet-magic $MAGIC)

echo "funding address: $FUNDING_ADDR"
echo "script address:  $SCRIPT_ADDR"

echo "--- picking a funded UTxO ---"
$CLI query utxo --address "$FUNDING_ADDR" --socket-path "$NODE_SOCKET" \
  --testnet-magic $MAGIC --out-file "$WORKDIR/funding-utxo.json"
FUNDING_TXIN=$(jq -r 'to_entries | max_by(.value.value.lovelace) | .key' "$WORKDIR/funding-utxo.json")
FUNDING_LOVELACE=$(jq -r --arg k "$FUNDING_TXIN" '.[$k].value.lovelace' "$WORKDIR/funding-utxo.json")
echo "using input: $FUNDING_TXIN ($FUNDING_LOVELACE lovelace)"
# Snapshot of everything already at FUNDING_ADDR before the sanity tx below --
# reused as wait_for_new_utxo's exclude list. FUNDING_ADDR routinely carries
# leftover UTxOs from earlier runs (persisted collateral -- see bug #7 -- and
# spend payouts), so excluding only $FUNDING_TXIN (the one input we're about
# to spend) is not enough: any other leftover entry would satisfy "!=
# $FUNDING_TXIN" on the very first poll and be mistaken for genuine
# confirmation, well before the real tx has landed. Confirmed root cause of
# an AllInputsAreSpent failure on 2026-09-14 (a second, later run of this
# script matched a stale 4.5M-lovelace payout left by an earlier run's valid
# spend, "confirmed" its own sanity tx with zero retries, then raced its own
# still-pending sanity tx for the same input in step 1).
EXISTING_FUNDING_UTXOS=$(jq -r 'keys | join(",")' "$WORKDIR/funding-utxo.json")

echo "=== step 0: sanity check -- a plain self-payment, no script, no datum ==="
SANITY_FEE=300000
SANITY_CHANGE=$((FUNDING_LOVELACE - SANITY_FEE))
$CLI transaction build-raw \
  --tx-in "$FUNDING_TXIN" \
  --tx-out "${FUNDING_ADDR}+${SANITY_CHANGE}" \
  --fee $SANITY_FEE \
  --out-file "$WORKDIR/sanity.txbody"

$CLI transaction sign \
  --tx-body-file "$WORKDIR/sanity.txbody" --signing-key-file "$FUNDING_SKEY" \
  --testnet-magic $MAGIC --out-file "$WORKDIR/sanity.tx"

$CLI transaction submit --tx-file "$WORKDIR/sanity.tx" \
  --socket-path "$NODE_SOCKET" --testnet-magic $MAGIC

echo "--- waiting for the sanity tx to land on-chain ---"
if ! FUNDING_TXIN=$(wait_for_new_utxo "$FUNDING_ADDR" "$EXISTING_FUNDING_UTXOS" "$WORKDIR/funding-utxo-sanity.json"); then
  echo "sanity tx never landed on-chain -- general problem (block production?), not specific to Plutus. Stopping here." >&2
  exit 1
fi
echo "sanity tx confirmed on-chain, new utxo: $FUNDING_TXIN"

# ---------------------------------------------------------------------------
echo
echo "############################################################"
echo "# step 1: a VALID Plutus spend (comfortably inside maxTxExUnits)"
echo "############################################################"
# Re-derive FUNDING_TXIN as the biggest current FUNDING_ADDR UTxO rather than
# trusting the value carried over from the previous step's wait_for_new_utxo
# call: after a *successful* Plutus spend, collateral inputs are never
# actually consumed (only forfeited on phase-2 failure), so the collateral
# UTxO excluded by that wait_for_new_utxo call is still sitting there --
# usually the biggest one -- and must be picked back up here, not skipped.
# Confirmed root cause of a "Value must be positive in UTxO" (negative
# change) failure on 2026-09-14 when this wasn't done before step 2.
$CLI query utxo --address "$FUNDING_ADDR" --socket-path "$NODE_SOCKET" \
  --testnet-magic $MAGIC --out-file "$WORKDIR/funding-utxo.json"
FUNDING_TXIN=$(jq -r 'to_entries | max_by(.value.value.lovelace) | .key' "$WORKDIR/funding-utxo.json")

if ! SCRIPT_TXIN=$(lock_at_script "$FUNDING_TXIN" 5000000 "bootstrap-valid"); then
  echo "bootstrap-valid never landed on-chain -- aborting" >&2
  exit 1
fi
echo "script utxo: $SCRIPT_TXIN"

$CLI query utxo --address "$FUNDING_ADDR" --socket-path "$NODE_SOCKET" \
  --testnet-magic $MAGIC --out-file "$WORKDIR/funding-utxo2.json"
COLLATERAL_TXIN=$(jq -r 'to_entries | max_by(.value.value.lovelace) | .key' "$WORKDIR/funding-utxo2.json")
echo "collateral utxo: $COLLATERAL_TXIN"
# Same reasoning as EXISTING_FUNDING_UTXOS above: snapshot everything at
# FUNDING_ADDR right before submitting, not just the one input used as
# collateral, so wait_for_new_utxo below can't mistake another leftover
# UTxO for genuine confirmation.
EXISTING_FUNDING_UTXOS=$(jq -r 'keys | join(",")' "$WORKDIR/funding-utxo2.json")

# Well inside maxTxExUnits (10,000,000,000 steps / 14,000,000 memory) --
# this MUST be accepted regardless of the #1077 patch, on any unpatched
# node too. Fee: base tx-size fee + tiny script cost, 500000 is generous.
VALID_FEE=500000
$CLI transaction build-raw \
  --tx-in "$SCRIPT_TXIN" \
  --tx-in-script-file "$SCRIPT" \
  --tx-in-datum-value 0 \
  --tx-in-redeemer-value 0 \
  --tx-in-execution-units "(1000000,100000)" \
  --tx-in-collateral "$COLLATERAL_TXIN" \
  --tx-out "${FUNDING_ADDR}+$((5000000 - VALID_FEE))" \
  --fee $VALID_FEE \
  --protocol-params-file "$PROTOCOL_PARAMS" \
  --out-file "$WORKDIR/spend-valid.txbody"

$CLI transaction sign \
  --tx-body-file "$WORKDIR/spend-valid.txbody" --signing-key-file "$FUNDING_SKEY" \
  --testnet-magic $MAGIC --out-file "$WORKDIR/spend-valid.tx"

$CLI transaction submit --tx-file "$WORKDIR/spend-valid.tx" \
  --socket-path "$NODE_SOCKET" --testnet-magic $MAGIC

echo "--- waiting for the valid Plutus spend to land on-chain ---"
if ! FUNDING_TXIN=$(wait_for_new_utxo "$FUNDING_ADDR" "$EXISTING_FUNDING_UTXOS" "$WORKDIR/funding-utxo-valid.json"); then
  echo "valid Plutus spend never landed on-chain -- basic Plutus pipeline is broken, stopping before attempting the oversized case." >&2
  exit 1
fi
echo "valid Plutus spend confirmed on-chain. Basic pipeline works -- proceeding to the actual #1077 test."

# ---------------------------------------------------------------------------
echo
echo "############################################################"
echo "# step 2: the OVERSIZED Plutus spend (the actual #1077 test)"
echo "############################################################"
# Old per-tx limit (maxTxExUnits): steps 10,000,000,000 / memory 14,000,000
# New EB limit    (maxBlockExUnits): steps 20,000,000,000 / memory 62,000,000
# Declared here:                    steps 15,000,000,000 / memory 30,000,000
# Same re-derivation as before step 1 above, and for the same reason: the
# valid spend's collateral UTxO was never consumed (phase-2 succeeded) and is
# still the biggest FUNDING_ADDR entry.
$CLI query utxo --address "$FUNDING_ADDR" --socket-path "$NODE_SOCKET" \
  --testnet-magic $MAGIC --out-file "$WORKDIR/funding-utxo.json"
FUNDING_TXIN=$(jq -r 'to_entries | max_by(.value.value.lovelace) | .key' "$WORKDIR/funding-utxo.json")

if ! SCRIPT_TXIN=$(lock_at_script "$FUNDING_TXIN" 5000000 "bootstrap-oversized"); then
  echo "bootstrap-oversized never landed on-chain -- aborting" >&2
  exit 1
fi
echo "script utxo: $SCRIPT_TXIN"

$CLI query utxo --address "$FUNDING_ADDR" --socket-path "$NODE_SOCKET" \
  --testnet-magic $MAGIC --out-file "$WORKDIR/funding-utxo3.json"
COLLATERAL_TXIN=$(jq -r 'to_entries | max_by(.value.value.lovelace) | .key' "$WORKDIR/funding-utxo3.json")
echo "collateral utxo: $COLLATERAL_TXIN"
# Same reasoning as EXISTING_FUNDING_UTXOS above (step 1): snapshot everything
# at FUNDING_ADDR right before submitting, so wait_for_new_utxo below can't
# mistake another leftover UTxO for genuine confirmation of this spend.
EXISTING_FUNDING_UTXOS=$(jq -r 'keys | join(",")' "$WORKDIR/funding-utxo3.json")

# Fee must cover the declared script execution cost (genesis executionPrices:
# priceSteps 0.0000721, priceMemory 0.0577 lovelace/unit -> ~1.08M + ~1.73M =
# ~2.81M lovelace for this budget) plus the base tx-size fee, or the tx gets
# rejected for underpaying -- unrelated to the #1077 ExUnits check we want to
# exercise.
SPEND_FEE=3500000
$CLI transaction build-raw \
  --tx-in "$SCRIPT_TXIN" \
  --tx-in-script-file "$SCRIPT" \
  --tx-in-datum-value 0 \
  --tx-in-redeemer-value 0 \
  --tx-in-execution-units "(15000000000,30000000)" \
  --tx-in-collateral "$COLLATERAL_TXIN" \
  --tx-out "${FUNDING_ADDR}+$((5000000 - SPEND_FEE))" \
  --fee $SPEND_FEE \
  --protocol-params-file "$PROTOCOL_PARAMS" \
  --out-file "$WORKDIR/spend-oversized.txbody"

$CLI transaction sign \
  --tx-body-file "$WORKDIR/spend-oversized.txbody" --signing-key-file "$FUNDING_SKEY" \
  --testnet-magic $MAGIC --out-file "$WORKDIR/spend-oversized.tx"

$CLI transaction submit --tx-file "$WORKDIR/spend-oversized.tx" \
  --socket-path "$NODE_SOCKET" --testnet-magic $MAGIC

echo "--- waiting for the oversized Plutus spend to land on-chain ---"
if ! FUNDING_TXIN=$(wait_for_new_utxo "$FUNDING_ADDR" "$EXISTING_FUNDING_UTXOS" "$WORKDIR/funding-utxo-oversized.json"); then
  echo "oversized Plutus spend never landed on-chain -- admitted to the mempool but not (yet) included in a block." >&2
  exit 1
fi
echo "oversized Plutus spend confirmed on-chain. #1077 patch validated end-to-end."
