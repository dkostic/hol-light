#!/bin/bash
# Bootstrap script for HOL Light + s2n-bignum proof development environment.
# Installs everything from scratch on a fresh machine.
#
# Usage: bash setup-holctl.sh [workspace_dir]
#   workspace_dir defaults to ~/workspace

set -euo pipefail

WORKSPACE="${1:-$(pwd)}"
HOL_LIGHT_DIR="$WORKSPACE/hol-light"
S2N_BIGNUM_DIR="$WORKSPACE/s2n-bignum"
DMTCP_DIR="$WORKSPACE/dmtcp"
LOCAL="$HOME/.local"

echo "=== HOL Light + s2n-bignum Proof Development Setup ==="
echo "Workspace: $WORKSPACE"
echo ""

mkdir -p "$WORKSPACE" "$LOCAL/bin"
export PATH="$LOCAL/bin:$PATH"
export OPAMYES=1

# --- System dependencies ---
echo "--- Installing system dependencies ---"
OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
    brew install opam m4 python3 git
elif command -v dnf &>/dev/null; then
    # Amazon Linux 2023 / Fedora / RHEL
    sudo dnf install -y -q bubblewrap m4 gcc make python3 git diffutils patch
    if ! command -v opam &>/dev/null; then
        echo "  Installing opam..."
        yes "" | bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh)" -- --prefix="$LOCAL"
    fi
elif command -v apt-get &>/dev/null; then
    # Ubuntu / Debian
    sudo apt-get update -qq
    sudo apt-get install -y -qq opam bubblewrap m4 gcc make python3 git
else
    echo "ERROR: Unsupported package manager. Install manually: opam m4 gcc make python3 git" >&2
    exit 1
fi

# --- DMTCP (Linux only) ---
echo ""
echo "--- DMTCP ---"
if [ "$OS" = "Darwin" ]; then
    echo "  ⚠ DMTCP not available on macOS — checkpoints disabled, cold starts only (~3 min)"
elif command -v dmtcp_launch &>/dev/null; then
    echo "  ✓ DMTCP already installed ($(dmtcp_launch --version 2>&1 | head -1))"
else
    echo "  Building DMTCP from source..."
    git clone https://github.com/dmtcp/dmtcp.git "$DMTCP_DIR"
    cd "$DMTCP_DIR"
    ./configure --prefix="$LOCAL"
    make -j"$(nproc)"
    make install
    echo "  ✓ DMTCP installed"
fi

# --- HOL Light ---
echo ""
echo "--- HOL Light ---"
if [ -f "$HOL_LIGHT_DIR/hol.sh" ]; then
    echo "  ✓ HOL Light already built"
else
    if [ ! -d "$HOL_LIGHT_DIR" ]; then
        git clone https://github.com/jrh13/hol-light.git "$HOL_LIGHT_DIR"
    fi
    cd "$HOL_LIGHT_DIR"
    opam init --bare --no-setup --disable-sandboxing 2>/dev/null || true
    make switch-5
    eval $(opam env --switch "$HOL_LIGHT_DIR" --set-switch)
    make HOLLIGHT_USE_MODULE=1
    echo "  ✓ HOL Light built"
fi

# Ensure holctl tooling is available (lives on dkostic/hol-light holctl branch)
cd "$HOL_LIGHT_DIR"
if [ ! -f "$HOL_LIGHT_DIR/tools/holctl/holctl" ]; then
    if ! git remote | grep -q dkostic; then
        git remote add dkostic https://github.com/dkostic/hol-light.git
    fi
    git fetch dkostic holctl
    git merge --no-edit dkostic/holctl
    echo "  ✓ holctl tooling merged"
fi

# --- s2n-bignum ---
echo ""
echo "--- s2n-bignum ---"
if [ ! -d "$S2N_BIGNUM_DIR" ]; then
    git clone https://github.com/awslabs/s2n-bignum.git "$S2N_BIGNUM_DIR"
fi
echo "  ✓ s2n-bignum ready"

# --- holctl setup ---
echo ""
echo "--- holctl ---"
# Clone hol_server (TCP server for HOL Light)
REGISTRY_DIR="$HOME/.holctl"
HOL_SERVER_DIR="$REGISTRY_DIR/hol_server"
mkdir -p "$REGISTRY_DIR"
if [ ! -f "$HOL_SERVER_DIR/server2.ml" ]; then
    echo "  Cloning hol_server..."
    git clone -q -b vscode https://github.com/monadius/hol_server.git "$HOL_SERVER_DIR"
fi

ln -sf "$HOL_LIGHT_DIR/tools/holctl/holctl" "$LOCAL/bin/holctl"

# --- Checkpoints (Linux only) ---
echo ""
echo "--- Building DMTCP checkpoints ---"
if [ "$OS" = "Darwin" ]; then
    echo "  Skipped (DMTCP not available on macOS)"
else
cd "$HOL_LIGHT_DIR"
eval $(opam env --switch "$HOL_LIGHT_DIR" --set-switch)

if [ ! -f "$HOL_LIGHT_DIR/hol-base.ckpt/dmtcp_restart_script.sh" ]; then
    echo "  Building base checkpoint..."
    setsid bash make-checkpoint.sh hol-base </dev/null 2>&1 | tail -3
    echo "  ✓ Base checkpoint"
else
    echo "  ✓ Base checkpoint exists"
fi

for arch in arm x86; do
    ckpt="hol-s2n-${arch}"
    if [ ! -f "$HOL_LIGHT_DIR/${ckpt}.ckpt/dmtcp_restart_script.sh" ] || \
       ! ls "$HOL_LIGHT_DIR/${ckpt}.ckpt"/ckpt_ocamlrun_*.dmtcp 1>/dev/null 2>&1; then
        echo "  Building ${ckpt} checkpoint (~3-4 min)..."
        cd "$HOL_LIGHT_DIR"
        HOL_LIGHT_DIR="$HOL_LIGHT_DIR" S2N_BIGNUM_DIR="$S2N_BIGNUM_DIR" \
            bash "$HOL_LIGHT_DIR/tools/holctl/make-s2n-checkpoint.sh" "$arch" 2>&1 | tail -5
        if grep -q "SUCCESS" "/tmp/s2n-${arch}-ckpt-done" 2>/dev/null; then
            echo "  ✓ ${ckpt} checkpoint"
        else
            echo "  ✗ ${ckpt} checkpoint FAILED"
        fi
    else
        echo "  ✓ ${ckpt} checkpoint exists"
    fi
done
fi  # end Linux-only checkpoints

# --- Smoke test ---
echo ""
echo "--- Smoke test ---"
if [ "$OS" = "Darwin" ]; then
    holctl start --name setup-test 2>&1
else
    holctl start --name setup-test --checkpoint s2n-arm 2>&1
fi

# Test basic eval (raw REPL)
result=$(holctl eval setup-test 'ARITH_RULE `1 + 1 = 2`' 2>&1)
if echo "$result" | grep -q "|- 1 + 1 = 2"; then
    echo "  ✓ eval: $result"
else
    echo "  ✗ eval FAILED: $result"
    holctl stop setup-test 2>&1
    exit 1
fi

# Test structured JSON proof workflow
goal_result=$(holctl goal setup-test '!n. n + 0 = n' 2>&1)
if echo "$goal_result" | grep -q '"goals"'; then
    echo "  ✓ goal (JSON): goal set"
else
    echo "  ✗ goal (JSON) FAILED: $goal_result"
    holctl stop setup-test 2>&1
    exit 1
fi

tactic_result=$(holctl tactic setup-test 'ARITH_TAC' 2>&1)
if echo "$tactic_result" | grep -q '"proved":true'; then
    echo "  ✓ tactic (JSON): proof complete"
else
    echo "  ✗ tactic (JSON) FAILED: $tactic_result"
    holctl stop setup-test 2>&1
    exit 1
fi

# Test goal-state command
gs_result=$(holctl goal-state setup-test 2>&1)
if echo "$gs_result" | grep -q '"goals"'; then
    echo "  ✓ goal-state (JSON): ok"
else
    echo "  ✗ goal-state (JSON) FAILED: $gs_result"
    holctl stop setup-test 2>&1
    exit 1
fi

holctl stop setup-test 2>&1

echo ""
echo "=== Setup complete — SUCCESS ==="
echo ""
echo "Installed:"
echo "  - HOL Light (with all OCaml dependencies)"
if [ "$OS" != "Darwin" ]; then
echo "  - DMTCP (for checkpointing)"
fi
echo "  - holctl (from hol-light/tools/holctl/)"
echo ""
if [ "$OS" != "Darwin" ]; then
echo "DMTCP checkpoints created:"
holctl checkpoint-list 2>/dev/null | sed 's/^/  /'
echo ""
fi
echo "The setup is ready to use."
echo "  Run 'holctl --help' for usage information."
echo "  See hol-light/tools/holctl/AGENT_GUIDE.md for AI agent instructions."
echo ""
echo "Key features:"
echo "  - Structured JSON output from goal, tactic, back, search commands"
echo "  - Batch tactics: holctl tactics <server> 'tac1' 'tac2' ..."
echo "  - Goal inspection: holctl goal-state <server>"
echo "  - Use --raw for REPL text output, --full to disable truncation"
