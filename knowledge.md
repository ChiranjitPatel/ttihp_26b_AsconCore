# Tile Area Optimization: 4 tiles -> 2 tiles

## Current architecture (as of `e82a9da`, info.yaml requesting `1x2`)

`src/project.v` wraps `src/ascon_round.v` in a byte-serial I/O shell:

- **State register**: `state_flat` is a single 320-bit register (`reg [319:0]`). This
  is the minimum possible storage for the Ascon state and is not reducible — the
  wrapper already loads/reads it byte-serially over the 8-pin `ui_in`/`uo_out` bus,
  so there's no way to hold less than the full state between load and permute.
- **Round datapath**: `ascon_round` is fully combinational and computes an *entire*
  round (S-box + linear diffusion layer) across all 320 bits in parallel, in one
  clock. The FSM in `project.v` just re-registers this combinational output once
  per cycle, `rounds_left` times (12 / 8 / 6 / 1 depending on `round_sel`).

## Where the area actually goes (rough 2-input-gate-equivalent count)

Estimated by hand from the gate-level structure of `ascon_round.v` (no local
OpenLane/PDK access in this environment, so these are estimates, not a synthesis
report — see "Validating this" below):

| Block | Gate-equivalent count | Notes |
|---|---|---|
| State register (320 FF) | ~1100 GE | 1 FF ~= 3.5x a 2-input gate; fixed cost, not reducible |
| S-box logic (`t0..t4`, `s*a/b/c`) | ~1100 GE | Bitsliced 5-input S-box, instantiated once per bit position x 64 positions x 5 words |
| Diffusion logic (`x*_o` XORs) | ~650 GE | 3-way XOR (rotate is free wiring) per output bit, x 320 bits |
| Control (FSM, counters, round-const ROM) | negligible | < 50 GE |
| **Total** | **~2850 GE** | |

So the **combinational round logic (~1750 GE) is a bigger contributor than the
register (~1100 GE)**, and it's all duplicated 64x/320x wider than it needs to be
for a design that only needs to finish a round every 20+ cycles anyway (the I/O
shell already spends ~80 cycles per operation loading/reading 40 bytes each way,
against only 12 cycles for the permutation itself). That mismatch — a fast,
wide datapath serving a slow, narrow I/O protocol — is the actual optimization
opportunity.

## Recommended approach: serialize the round datapath

Trade permutation latency (cheap, since I/O already dominates cycle count) for
combinational area (expensive, since it's the tile budget).

### Phase A — serialize the S-box (moderate effort, ~30% total area cut)

The S-box is applied bitsliced: bit `i` of the output only depends on bit `i` of
`x0..x4`. There is *no* dependency between different bit positions in the S-box
step, so it can be computed a few bit-lanes at a time instead of all 64 at once:

- Add a `post_sbox` 320-bit register (or reuse `state_flat` in place, see Phase B).
- Add a bit-lane counter `lane` (0..63, stepping by k, e.g. k=8).
- Each cycle, feed bit-lanes `[lane +: k]` of `x0..x4` into a *k-bit-wide* instance
  of the S-box logic (`t0..t4`, `s*a/b/c`), and write the result into the same
  lanes of `post_sbox`.
- After 64/k cycles, the S-box step for the whole round is done; run the (still
  fully parallel) diffusion layer for 1 cycle as today.
- With k=8: S-box logic shrinks ~8x (~1100 GE -> ~140 GE), diffusion is untouched
  (~650 GE). New total: register (1100) + sbox (140) + diffusion (650) + control
  (~50) = **~1940 GE (~32% smaller)**. Round latency: 8 (S-box lanes) + 1
  (diffusion) = 9 cycles instead of 1 -> a 12-round permutation goes from 12 to
  ~108 cycles. Still trivial next to the ~80-cycle I/O overhead.

### Phase B — also serialize diffusion (if Phase A isn't enough)

Diffusion (`x_o[j] = sb[j] ^ sb[(j+r1)%64] ^ sb[(j+r2)%64]`) needs bits from other
positions *within the same word*, so it can't be sliced the same trivial way. To
shrink it too, turn the state register into a rotate-capable shift register
(reuses the existing 320 FFs — no new storage) and accumulate `x_o` bit-serially
as the register rotates past the two tap offsets (`r1`, `r2`) for each word. This
is the standard technique lightweight/bit-serial crypto cores (PRESENT, GIFT,
bit-serial Ascon papers) use to get diffusion down to a handful of gates. Cost:
significantly more control complexity (per-word tap counters/comparators) and
more cycles (bounded by the largest rotation amount, 61, per word) — this is
real, riskier design work and should only be taken on if Phase A alone doesn't
get under the 2-tile budget.

Rotation amounts needed, for reference (from `ascon_round.v`): x0: 19,28 ·
x1: 61,39 · x2: 1,6 · x3: 10,17 · x4: 7,41.

### What NOT to bother with

- Shrinking the 320-bit state register itself — not possible without changing
  the I/O protocol (would need a smaller external state representation, which
  isn't compatible with running the real 320-bit Ascon permutation).
- Config-only tweaks (`PL_TARGET_DENSITY_PCT`, margins in `src/config.json`) —
  already at 80% density as of `e82a9da`; more floorplan squeezing won't recover
  a 2x area deficit, only a modest percentage.

## Validating this

This environment has no local OpenLane/PDK install and `gh` isn't authenticated,
so none of the GE estimates above are grounded in an actual synthesis report —
they're hand counts from the RTL structure. Before/after implementing Phase A,
check the actual cell count / die area from the project's `gds.yaml` GitHub
Actions run (Actions tab on the repo, or the OpenLane `reports/` area summary it
produces) rather than trusting the estimates here.

## Status

**Phase A implemented** (this environment has no local iverilog/cocotb, so
verification here was a bit-accurate Python re-implementation of the new FSM
— `state_flat` layout, lane offsets, in-place lane updates, round-constant
gating — cross-checked against 88 random/fixed vectors across all round
counts; 88/88 matched the reference. The real cocotb suite in `test/test.py`
should still be run via the project's CI (`test.yaml`) to confirm — it
already polls `busy` in a loop rather than assuming a fixed cycle count, so
it needed no changes for the new 9-cycles/round timing).

What changed:
- `src/ascon_round.v`: replaced the single fully-parallel `ascon_round`
  module with `ascon_sbox_slice #(WIDTH=8)` (S-box only, reusable at any
  width) and `ascon_diffusion` (full-width linear layer, unchanged math).
- `src/project.v`: FSM gained a `DIFF` state; `RUN` became `SBOX` (loops 8
  times, one 8-bit lane per cycle, updating `state_flat` in place) followed
  by one `DIFF` cycle per round. `busy` is now `fsm_state != IDLE`.

Not yet done: Phase B (serializing diffusion too). Only take this on if the
actual CI area report after Phase A still doesn't fit 2 tiles — check
`gds.yaml`'s run output / OpenLane area report before deciding.
