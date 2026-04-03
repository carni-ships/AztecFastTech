#!/usr/bin/env bash
# Fetch and compile real Aztec protocol circuits from aztec-packages
# Requires: nargo (1.0.0-beta.18+), ~2GB disk for monorepo clone
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AZTEC_TAG="v4.1.2"
AZTEC_DIR="${SCRIPT_DIR}/.aztec-packages"
CIRCUIT_DIR="${AZTEC_DIR}/noir-projects/noir-protocol-circuits"

echo "=== Fetching Aztec Protocol Circuits (${AZTEC_TAG}) ==="

# Clone aztec-packages if not already present
if [ ! -d "$AZTEC_DIR" ]; then
    echo "Cloning aztec-packages at ${AZTEC_TAG} (shallow, ~2GB)..."
    git clone --depth 1 --branch "$AZTEC_TAG" --no-recurse-submodules \
        https://github.com/AztecProtocol/aztec-packages.git "$AZTEC_DIR"
else
    echo "Using existing aztec-packages at ${AZTEC_DIR}"
fi

# Generate Nargo.toml from template
cd "$CIRCUIT_DIR"
if [ ! -f Nargo.toml ]; then
    cp Nargo.template.toml Nargo.toml
    echo "Created Nargo.toml from template"
fi

# Create Prover.toml for parity-base (256 sequential messages + vk_tree_root)
PARITY_DIR="${CIRCUIT_DIR}/crates/parity-base"
if [ ! -f "${PARITY_DIR}/Prover.toml" ]; then
    echo "Generating parity-base witness inputs..."
    python3 -c "
msgs = ', '.join(['\"' + str(i) + '\"' for i in range(256)])
print('[inputs]')
print(f'msgs = [{msgs}]')
print('vk_tree_root = \"42\"')
" > "${PARITY_DIR}/Prover.toml"
fi

# Compile and execute parity-base
echo "Compiling parity-base..."
nargo compile --package parity_base --skip-brillig-constraints-check

echo "Generating witness..."
nargo execute --package parity_base

# Copy artifacts to aztec-bench target/
mkdir -p "${SCRIPT_DIR}/target"
cp "${CIRCUIT_DIR}/target/parity_base.json" "${SCRIPT_DIR}/target/"
cp "${CIRCUIT_DIR}/target/parity_base.gz" "${SCRIPT_DIR}/target/"

echo ""
echo "=== Setup Complete ==="
echo "Artifacts copied to target/:"
ls -lh "${SCRIPT_DIR}/target/parity_base.json" "${SCRIPT_DIR}/target/parity_base.gz"
echo ""
echo "Run ./bench.sh to benchmark (includes parity-base automatically)"
