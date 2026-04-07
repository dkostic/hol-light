#!/bin/bash
# Build a DMTCP checkpoint with s2n-bignum proof infrastructure pre-loaded.
#
# Usage: bash make-s2n-checkpoint.sh <arm|x86>
#    or: nohup bash make-s2n-checkpoint.sh arm &> /tmp/s2n-arm-ckpt.log &

set -euo pipefail

ARCH="${1:?Usage: make-s2n-checkpoint.sh <arm|x86>}"
case "$ARCH" in arm|x86) ;; *) echo "ERROR: arch must be arm or x86" >&2; exit 1;; esac

HOLDIR="${HOL_LIGHT_DIR:-$HOME/workspace/hol-light}"
S2NDIR="${S2N_BIGNUM_DIR:-$HOME/workspace/s2n-bignum}"
CKPT_NAME="hol-s2n-$ARCH"
CKPT_DIR="${HOLDIR}/${CKPT_NAME}.ckpt"
DONE_MARKER="/tmp/s2n-${ARCH}-ckpt-done"

export PATH="$HOME/.local/bin:$PATH"

echo "=== Starting $CKPT_NAME checkpoint build at $(date) ==="
rm -f "$DONE_MARKER"
rm -rf "$CKPT_DIR" "${HOLDIR}/${CKPT_NAME}"

cd "$HOLDIR"
eval $(opam env --switch . 2>/dev/null) || true

FIFO=$(mktemp -u --suffix=".hol_stdin")
mkfifo "$FIFO"

# Hold FIFO open until checkpoint files appear, then close to let everything exit
(
  exec 3>"$FIFO"
  while true; do
    if [ -f "$CKPT_DIR/dmtcp_restart_script.sh" ] && \
       ls "$CKPT_DIR"/ckpt_ocamlrun_*.dmtcp 1>/dev/null 2>&1; then
      sleep 2  # let dmtcp finish writing
      break
    fi
    sleep 2
  done
  exec 3>&-
) &
KEEPER_PID=$!

setsid bash make-checkpoint.sh "$CKPT_NAME" \
  "load_path := \"${S2NDIR}\" :: !load_path; needs \"${ARCH}/proofs/base.ml\"" \
  <"$FIFO" 2>&1

if [ -f "$CKPT_DIR/dmtcp_restart_script.sh" ] && \
   ls "$CKPT_DIR"/ckpt_ocamlrun_*.dmtcp 1>/dev/null 2>&1; then
  echo "SUCCESS" > "$DONE_MARKER"
  echo "=== Checkpoint created successfully at $(date) ==="
  ls -lh "$CKPT_DIR"
else
  echo "FAILED" > "$DONE_MARKER"
  echo "=== Checkpoint FAILED at $(date) ==="
  ls -lh "$CKPT_DIR" 2>/dev/null
  exit 1
fi

kill $KEEPER_PID 2>/dev/null || true
rm -f "$FIFO"
