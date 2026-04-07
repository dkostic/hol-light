# HOL Light Proof Development — Agent Guide

## Architecture

You interact with HOL Light through **TCP servers** managed by the `holctl` CLI tool.
Each server is an independent process that survives agent restarts.

```
Agent (kiro-cli / claude)
  └── execute_bash: holctl <command>
        └── TCP connection to hol_server on localhost:PORT
              └── HOL Light OCaml process (possibly DMTCP-checkpointed)
```

## Quick Reference

```bash
# Server lifecycle
holctl start --name arm1                    # Start a new server
holctl start --name arm1 --checkpoint s2n-arm   # Start from DMTCP checkpoint
holctl list                                 # List all servers
holctl status arm1                          # Show server status + current goal
holctl stop arm1                            # Stop a server
holctl stop-all                             # Stop all servers in this session

# Interactive proof development
holctl eval arm1 'needs "arm/proofs/base.ml"'     # Load a file
holctl goal arm1 '!n. n + 0 = n'                  # Set a goal
holctl goal-state arm1                             # Inspect current goal state
holctl tactic arm1 'INDUCT_TAC'                    # Apply a tactic
holctl tactic arm1 'ASM_REWRITE_TAC[ADD_CLAUSES]'  # Apply another tactic
holctl tactics arm1 'GEN_TAC' 'STRIP_TAC' 'ASM_REWRITE_TAC[]'  # Batch tactics
holctl back arm1                                    # Undo last tactic
holctl back arm1 3                                  # Undo 3 steps
holctl search arm1 'name "ADD"'                     # Search theorems
holctl eval arm1 'type_of `word_add:N word->N word->N word`'  # Check types
holctl interrupt arm1                               # Cancel hung tactic

# Output control
holctl --max-lines 100 tactic arm1 'SIMP_TAC[...]'  # More output
holctl --full eval arm1 '...'                        # Full output (careful!)
holctl --raw tactic arm1 '...'                       # Raw REPL text (no JSON)
holctl --timeout 3600 tactic arm1 'CONV_TAC ...'     # Long-running tactic

# Checkpointing
holctl checkpoint-list                               # List checkpoints
holctl checkpoint-create base                        # Create base checkpoint
holctl checkpoint-create s2n-arm 'needs "arm/proofs/base.ml"'  # With s2n-bignum
```

## Structured JSON Output

By default, `goal`, `goal-state`, `tactic`, `tactics`, `back`, and `search`
return structured JSON instead of raw REPL text. This makes it easy to
programmatically detect proof completion, inspect goals, and implement
backtracking strategies.

Examples:
```json
# After holctl goal arm1 '!n. n + 0 = n'
{"goals":[{"hypotheses":[],"conclusion":"!n. n + 0 = n"}],"num_subgoals":1,"total_goals":1}

# After holctl tactic arm1 'ARITH_TAC'
{"proved":true,"theorem":"|- !n. n + 0 = n"}

# After a tactic that creates subgoals
{"goals":[{"hypotheses":[{"label":"","term":"P n"}],"conclusion":"P (SUC n)"}],"num_subgoals":1,"total_goals":2}

# On error
{"error":"no applicable tactic"}

# After holctl tactics arm1 'GEN_TAC' 'ARITH_TAC'
{"proved":true,"theorem":"|- !n. n + 0 = n","steps":2}

# After holctl search arm1 'name "ADD_SYM"'
[{"name":"ADD_SYM","statement":"|- !m n. m + n = n + m"}]
```

Use `--raw` to get the old REPL text output when needed.

## Proof Workflow

1. Start a server: `holctl start --name <descriptive-name>`
2. Load required theories: `holctl eval <name> 'needs "arm/proofs/base.ml"'`
3. Set the goal: `holctl goal <name> '<goal_term>'`
4. Apply tactics one at a time: `holctl tactic <name> '<tactic>'`
5. Or batch multiple tactics: `holctl tactics <name> 'tac1' 'tac2' 'tac3'`
6. Read the goal state after each tactic — check JSON for `"proved":true` or remaining subgoals
7. Inspect goals at any time: `holctl goal-state <name>`
8. If stuck, backtrack: `holctl back <name>`
9. Search for useful theorems: `holctl search <name> 'name "WORD"'`
10. When all subgoals are proved, extract the theorem: `holctl eval <name> 'top_thm()'`

## Key Principles

- **Output is structured JSON by default**. Commands like `goal`, `tactic`, `back`,
  and `search` return JSON with goal states, proof completion status, and errors.
  Use `--raw` for the old REPL text output.
- **Output is truncated by default** (60 lines). This is intentional — HOL Light
  output can be enormous. When truncated, the full output is saved to a temp file
  (path shown in the truncation message). Use `--max-lines N` or `--full` when you need more.
- **Check for `"proved":true`** in tactic responses to detect proof completion.
- **One server per proof task**. Don't share a server between unrelated proofs.
- **Servers are independent processes**. They survive if the agent session dies.
- **Use descriptive names**: `arm-bignum-add`, `x86-p256-montmul`, etc.
- **Long tactics**: Some tactics (especially `CONV_TAC` on large terms) can take
  minutes or hours. Use `--timeout 3600` and `holctl interrupt` if needed.

## s2n-bignum Proof Patterns

s2n-bignum proofs verify ARM/x86 assembly against functional specs. Typical structure:

```
needs "arm/proofs/base.ml";;   (* Load ARM proof infrastructure *)

let my_mc = define_assert_from_elf "my_mc" "arm/generic/my_func.o" [...];;
let MY_EXEC = ARM_MK_EXEC_RULE my_mc;;

(* The correctness theorem *)
let MY_FUNC_CORRECT = prove(
  `!args... . ensures arm ...`,
  ... tactics ...
);;
```

Common s2n-bignum tactics:
- `ARM_SIM_TAC MY_EXEC [1;2;3]` — simulate ARM instructions
- `ENSURES_INIT_TAC "s0"` — initialize ensures proof
- `ARM_STEPS_TAC MY_EXEC (1--N) THEN ...` — step through instructions
- `ENSURES_FINAL_STATE_TAC` — finish ensures proof
- `CONV_TAC(LAND_CONV BIGNUM_EXPAND_CONV)` — expand bignum representations
- `ASM_REWRITE_TAC[word_add; ...]` — rewrite with word arithmetic

## Multi-Server Usage

You can run multiple servers in parallel for different proof tasks:

```bash
holctl start --name arm-add
holctl start --name arm-mul
holctl eval arm-add 'needs "arm/proofs/base.ml"'
holctl eval arm-mul 'needs "arm/proofs/base.ml"'
# Now work on both proofs independently
```

## Troubleshooting

- Server won't start: Check `holctl status <name>` and the log file
- Connection refused: Server may still be loading HOL Light (~75s cold, ~2s checkpoint)
- Tactic hangs: Use `holctl interrupt <name>` then `holctl back <name>`
- Server died: `holctl start --name <same-name>` to restart
