# HOL Light Server Infrastructure for AI-Assisted Proof Development

## Overview

This directory contains `holctl`, a CLI tool for managing HOL Light TCP servers
for autonomous proof development with AI assistants (kiro-cli, claude, etc.).

### Why not MCP?

MCP (Model Context Protocol) has several limitations for this use case:

| Concern | MCP approach | holctl approach |
|---------|-------------|-----------------|
| Server lifecycle | Tied to MCP client process | Independent background processes |
| Multiple servers | Need multiple MCP server configs | `holctl start --name X` as many as needed |
| Session isolation | Complex, requires separate configs | Automatic via port ranges + registry |
| Output size | Full output hits context window | Truncated by default (60 lines) |
| Crash recovery | MCP server dies with client | Servers survive agent crashes |
| Long-running tactics | MCP timeout kills everything | Independent process + `holctl interrupt` |
| Multi-agent | Each agent needs own MCP config | Any agent can talk to any server by name |

### Architecture

```
┌─────────────────────┐     ┌─────────────────────┐
│  Agent Session A    │     │  Agent Session B    │
│  (kiro-cli)         │     │  (claude)           │
│                     │     │                     │
│  execute_bash:      │     │  execute_bash:      │
│    holctl eval      │     │    holctl tactic    │
│    arm1 '...'       │     │    x86-1 '...'      │
└────────┬────────────┘     └────────┬────────────┘
         │ TCP :12001                │ TCP :12003
         ▼                           ▼
┌─────────────────┐         ┌─────────────────┐
│ HOL Light       │         │ HOL Light       │
│ + hol_server    │         │ + hol_server    │
│ (arm1, pid=X)   │         │ (x86-1, pid=Y)  │
│ port 12001      │         │ port 12003      │
└─────────────────┘         └─────────────────┘
         ▲
         │ TCP :12002
┌────────┴────────────┐
│ HOL Light           │
│ + hol_server        │
│ (arm2, pid=Z)       │
│ port 12002          │
└─────────────────────┘
```

## Setup

```bash
# One-time setup (interactive, guides you through everything):
bash tools/holctl/setup-holctl.sh

# Or manual steps:
# 1. Build HOL Light
cd ~/workspace/hol-light
make switch && eval $(opam env) && make

# 2. Add holctl to PATH
ln -s ~/workspace/hol-light/tools/holctl/holctl ~/.local/bin/holctl

# 3. (Optional) Create DMTCP checkpoints for fast starts
cd ~/workspace/hol-light
bash make-checkpoint.sh hol-base
bash tools/holctl/make-s2n-checkpoint.sh arm
bash tools/holctl/make-s2n-checkpoint.sh x86
```

## Usage

```bash
# Start servers
holctl start --name arm1                        # Cold start (~75s)
holctl start --name arm1 --checkpoint base      # From checkpoint (~2s)
holctl start --name arm1 --checkpoint s2n-arm   # With s2n-bignum loaded (~2s)

# Interactive proof
holctl eval arm1 'needs "arm/proofs/base.ml"'
holctl goal arm1 '!n. n + 0 = n'
holctl tactic arm1 'INDUCT_TAC'
holctl tactic arm1 'ASM_REWRITE_TAC[ADD_CLAUSES]'
holctl back arm1                                 # Undo
holctl search arm1 'name "ADD"'                  # Find theorems

# Server management
holctl list                                      # All servers
holctl status arm1                               # Detailed status
holctl interrupt arm1                            # Cancel hung tactic
holctl stop arm1                                 # Stop one
holctl stop-all                                  # Stop all (this session)

# Output control
holctl --max-lines 100 eval arm1 '...'           # More output
holctl --full eval arm1 '...'                    # No truncation
holctl --timeout 7200 tactic arm1 '...'          # 2-hour timeout
```

## Session Isolation

Each agent session gets a unique session ID. `holctl stop-all` only stops
servers belonging to the current session. Servers from other sessions are
left alone. Port allocation avoids conflicts automatically.

To stop ALL servers (e.g., after a machine reboot):
```bash
holctl stop-all --all-sessions
```

## Files

- `holctl` — The main CLI tool (Python 3, no dependencies)
- `make-s2n-checkpoint.sh` — Builds DMTCP checkpoints for arm/x86
- `setup-holctl.sh` — Automated setup script (deps, build, checkpoints)
- `AGENT_GUIDE.md` — Reference guide included in agent context
- `hol_launcher.py` — Cold-start server launcher
- `hol_launcher_ckpt.py` — Checkpoint-based server launcher
- `~/.holctl/` — Runtime directory (registry, logs, hol_server source)
