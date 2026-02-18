# SHA Timing Fix README

## Issue Observed

After adding SHA logic, Vivado synthesis/implementation reported setup timing failures on `sys_clk`:

- `WNS = -2.121 ns`
- `TNS = -93.759 ns`
- `Failing endpoints = 92`

The top failing paths were inside SHA, for example:

- From `.../sha_core_inst/w_mem_inst/w_mem_reg[11][19]/C`
- To `.../sha_core_inst/a_reg_reg[31]/D`

This means timing was failing in the SHA round datapath, not due to syntax errors.

## Root Cause

In `sha256_core`, one round update had a long same-cycle combinational path:

- message schedule output (`w_data` from `sha256_w_mem`)
- `t1` and `t2` arithmetic (rotates/xor/adders/ch/maj)
- direct write into SHA state registers (`a_reg`, `e_reg`, etc.)

At 100 MHz (10 ns period), this path was too deep and caused setup violations.

## Resolution Implemented

File changed:

- `Sha-Code/sha-core.v`

Fix strategy: split each SHA round into 2 internal phases (pipeline the critical path).

### 1. Added pipeline registers

- `t1_reg`, `t2_reg` to store computed round terms
- `round_phase_reg` to control two-phase round execution

### 2. Updated state datapath

- `state_update` now uses `t1_reg` and `t2_reg` (registered values)
- removed dependence on same-cycle `t1/t2` in state writeback

### 3. Modified FSM behavior in `CTRL_ROUNDS`

- Phase 0: compute and latch `t1/t2`
- Phase 1: update SHA state registers, then advance round counter and `w_mem`

This breaks the original long combinational path into shorter timing-friendly stages.

## Functional Impact

- SHA interface behavior remains the same (`init`, `next`, `ready`, `digest_valid`).
- SHA block latency increases (roughly 2x round-cycle count), because each round now uses 2 cycles.
- This is a timing-for-latency tradeoff to close timing safely at target clock.

## Quick Verification

### RTL syntax check

```powershell
iverilog -g2005-sv -tnull Sha-Code/sha-constants.v Sha-Code/sha-memory.v Sha-Code/sha-core.v Sha-Code/sha.v
```

### Vivado re-check

1. Reset synthesis/implementation runs.
2. Re-run synthesis and implementation.
3. Open timing summary and confirm setup slack improved (target: no failing endpoints).

## Summary

The issue was a SHA round critical path (`w_mem -> t1/t2 -> state regs`) violating 10 ns timing.  
It was resolved by adding internal pipelining in `sha256_core` (two-phase round execution with registered `t1/t2`), reducing combinational depth per cycle.
