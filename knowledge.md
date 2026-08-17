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

## Ground truth from the real hardening flow (corrects the estimates above)

Phase A (8-bit S-box lanes) was pushed and hardened against a `1x2` (2-tile)
target. Result from `gds.yaml`:

```
[GPL-0301] Utilization 113.671 % exceeds 100%.
```

i.e. still ~14% too much cell area to even place (let alone route) at 2
tiles, despite Phase A's 8x S-box reduction. This means the hand-estimated
GE counts above materially *understated* how much the fully-parallel S-box
was costing relative to the register — real standard-cell area clearly
didn't shrink as cleanly as the naive "2-input-gate-equivalent" model
predicted. Treat the GE table above as directionally useful (S-box+diffusion
> register) but not quantitatively reliable; only the CI area/utilization
numbers are ground truth from here on.

## Status

**Phase A2 implemented**: pushed the S-box lane width from 8 bits down to
1 bit (fully bit-serial S-box, `ascon_sbox_slice #(.WIDTH(1))`), same
mechanical in-place-update technique as Phase A, just narrower and looping
64 times instead of 8. No new registers added. Round latency: 64 (S-box
lanes) + 1 (diffusion) = 65 cycles/round (was 9); a `p^12` permutation is
now 780 cycles, still trivial against a 10 MHz clock and the ~80-cycle I/O
overhead. Verified via the same bit-accurate Python FSM model (generalized
to arbitrary lane width) against 176 vectors across widths {1, 8} and all
round counts (12/8/6/1) — 176/176 matched. No local iverilog/cocotb in this
environment, so the real `test/test.py` suite still needs to run in CI to
confirm (unchanged from before — it polls `busy` rather than assuming a
fixed cycle count, so no test changes are needed for the new timing).

**Yosys syntax gap found by CI**: the first width=1 push failed synthesis
(not placement) — `round_const(r_idx)[lane_off[2:0]]` (bit-selecting a
function call's return value directly) is rejected by yosys's Verilog
frontend (`syntax error, unexpected '['`), even though Icarus Verilog
accepts it. This is exactly the kind of tool-specific syntax gap the local
Python-model verification in this environment *cannot* catch, since it
only checks logical equivalence, not real Verilog parsing — there's no
local yosys/iverilog here to compile against. Fixed by binding the
function result to an intermediate wire (`rc_cur`) before indexing it.
Worth remembering for any future serialization work in this file: avoid
indexing expressions directly off a function call's result; always go
through a wire first.

**Regression found and fixed**: the width=1 push (after fixing the yosys
syntax error) actually made things *worse* — utilization went from 113.67%
to **116%**. Root cause: `state_flat[256 + lane_off] <= y0_slice;` writes
to a *runtime-computed* bit index, which forces the synthesizer to build a
decoder + a compare/mux on every one of the 320 flip-flops to decide
whether `lane_off` currently points at them. At width=8 that only needed
an 8-way decode (3 bits); narrowing to width=1 turned it into a 64-way
decode (6 bits) — the decode overhead almost certainly outgrew the savings
from shrinking the S-box itself.

Fixed by dropping addressed writes entirely: since the S-box needs no
cross-bit-position data, each word is now a genuine **rotate-and-inject
shift register** during the SBOX phase — `state_flat[319:256] <= {y0_slice,
state_flat[319:257]}` etc. Every cycle rotates the word right by 1 (pure
wiring, identical in cost to `rotr` — zero gates) except the top bit, which
takes the freshly computed S-box output instead of the bit that would have
naturally rotated in. Reading is always at a fixed position (bit 0) too, so
there's no decoder or per-flop comparator anywhere. Proved mathematically
and confirmed by literal simulation (not just the earlier logical-
equivalence check) that this produces the bit-for-bit identical final state
after 64 steps as the addressed-write version — 264/264 vectors matched,
including a direct rotate-vs-addressed-vs-reference cross-check.

Note this rotate trick only works for the S-box because it has zero
dependency between bit positions (every tap is "my own bit, position 0").
Diffusion's `rotr(sb, r1)`/`rotr(sb, r2)` taps are *not* at position 0, and
a single shared rotating register develops wraparound corruption for those
offset taps once enough cycles have passed (verified this fails
algebraically) — so Phase B (if still needed) still requires either a
second buffer or the word-sequential accumulator approach described above,
not this same trick.

What changed since Phase A:
- `src/project.v`: `lane_idx` widened 3→6 bits (0..63), `lane_off` is now
  `lane_idx` directly (no `{lane_idx,3'b000}` byte-shift), S-box slice
  wires narrowed to 1 bit, round-constant gating generalized from
  "`lane_off==0`, XOR whole byte" to "`lane_off<8`, XOR the matching rc bit".
  `ascon_sbox_slice` instantiated with `.WIDTH(1)`.
- `src/ascon_round.v`: unchanged from Phase A (already parameterized by
  `WIDTH`, so no edits needed to shrink further).

## Real hardening result after the rotate-and-inject fix

Pushed and hardened again. Real ground truth from `28-openroad-globalplacement`:

```
[INFO GPL-0016] Core area:                   60109.258 um^2
[INFO GPL-0019] Utilization:                    93.358 %
[WARNING GPL-0302] Target density 0.8000 is too low for the available free area.
Automatically adjusting to uniform density 0.9400.
```

**116% -> 93.36%** raw cell utilization — the rotate-and-inject fix was a
huge win and confirms the earlier addressed-write decoder really was the
regression's cause. Global placement, detailed placement, and CTS all
completed. But 93.36% is still razor-thin: OpenROAD had to auto-bump its
placement density target to 94% just to legalize the initial placement at
all, leaving ~0 slack. The flow then failed later, in
`37-openroad-resizertimingpostcts`: post-CTS hold-violation repair found
348 endpoints and inserted 615 buffers (+18.8% area) to fix them, and
detailed placement couldn't legalize 183 of those new cells (`DPL-0036`)
because there was no room left.

**Why so many hold violations**: this is a direct side effect of the
rotate-and-inject S-box. Most of `state_flat`'s 320 bits, during the SBOX
phase, do nothing but `bit[k] <= bit[k+1]` — near-zero logic delay between
adjacent flops. After CTS introduces real clock skew across the physical
layout, that near-zero data delay is exactly the classic hold-violation
setup (skew can exceed the data path delay). This is a known tradeoff for
shift-register-heavy designs (e.g. scan chains have the same issue) — the
optimization that shrank the S-box is *also* what's now generating the
hold-fix buffer bloat.

**Two responses taken together**, since raw utilization has enough margin
now (93.36% -> plenty of room if the post-CTS buffer bloat can be tamed)
that a full re-architecture didn't seem justified before trying cheaper
options:

1. `src/config.json`: `CLOCK_PERIOD` was `20` (50 MHz) but the real target
   per `info.yaml` (`clock_hz: 10000000`) is 10 MHz (100ns). Fixed to
   `100`. Free, no RTL risk, gives the resizer much more setup slack
   (though hold violations are period-independent in principle, so this
   alone probably isn't sufficient — included mainly because it's
   nearly-free to fix a genuine mismatch either way).
2. **Diffusion now also bit-serialized**, using the *same* free-wiring
   principle that worked for the S-box, but avoiding the earlier
   decoder mistake entirely: diffusion needs 3 taps per output bit
   (`sb[j] ^ sb[(j+r1)%64] ^ sb[(j+r2)%64]`), not 1, and those taps are
   *not* all at position 0 — a single shared rotating register develops
   wraparound corruption for the offset taps (verified this algebraically
   earlier). The fix: process one word at a time. That word's `state_flat`
   slice does a **pure rotate** (no injection — it self-restores to its
   original value after 64 steps, verified in simulation), while 3 *fixed*
   fixed bit positions (0, r1, r2 — all compile-time constants, selected
   only by a small 5-way mux on `word_idx`) are read each cycle and their
   XOR is shifted into one shared 64-bit accumulator (`diff_acc`, reused
   across all 5 words sequentially, not one accumulator per word). After
   64 cycles the accumulator holds the fully diffused word, written back
   in 1 more cycle. Cost: **+64 flip-flops total** (not +320), and the
   diffusion combinational logic drops from ~650 GE (fully parallel) to 2
   XOR gates + three small 5-way muxes (reused for the whole pass).
   Verified via literal simulation against the reference: 352/352 vectors
   matched across all round counts, including an explicit self-restore
   assertion on the source word after its 64 rotations.

Latency cost: diffusion goes from 1 cycle/round to 5 words x 65 cycles =
325 cycles/round. Round total: 64 (S-box) + 325 (diffusion) = 389
cycles/round (was 65). A `p^12` permutation is now ~4.7k cycles (was
~780) — still trivial for a non-realtime demonstrator chip at 10 MHz
(~470 us).

## Real hardening result after diffusion serialization + CLOCK_PERIOD fix

Pushed and hardened again. Real ground truth from `28-openroad-globalplacement`:

```
[INFO GPL-0019] Utilization:                    81.350 %
[WARNING GPL-0302] Target density 0.8000 is too low for the available free area.
Automatically adjusting to uniform density 0.8200.
```

**93.36% -> 81.35%** raw utilization — diffusion serialization worked as
predicted, and the design now has real (not razor-thin) placement margin;
density only needed a tiny auto-bump (80% -> 82%) versus the previous
huge jump (80% -> 94%).

Still failed at the same stage though (`37-openroad-resizertimingpostcts`,
`DPL-0036`), but with much better numbers:

| | Before (93.36% raw) | After (81.35% raw) |
|---|---|---|
| Hold-violation endpoints found | 348 | 414 |
| Hold buffers inserted | 615 (+18.8% area) | 679 (+23.2% area) |
| Instances that failed to legalize | 183 | **51** |

Two things worth noting:
- **More hold violations after diffusion serialization, not fewer.** This
  confirms the earlier hypothesis: the word-sequential diffusion rotate
  (`state_flat[wordslice] <= {tap0, wordslice[63:1]}`, pure wiring) is
  *another* near-zero-delay shift structure, same failure mode as the
  S-box rotate. Serializing more of the datapath this way keeps adding
  more such paths even as it shrinks combinational area — the two effects
  pull in opposite directions for hold-violation count specifically, even
  though they still net out to less total area and far fewer unlegalizable
  instances (183 -> 51) because of the much larger placement margin.
- The final hold-repair iteration overshot to **+0.102ns positive slack**
  against a requested `hold_margin` of only 0.1ns — buffer-size granularity
  means the repair can't land exactly on the margin, so some of those 679
  buffers are larger/more numerous than strictly required.

**Response**: `src/config.json`'s `PL_RESIZER_HOLD_SLACK_MARGIN` (0.1 ->
0.05) and `GRT_RESIZER_HOLD_SLACK_MARGIN` (0.05 -> 0.025) halved. This is
exactly the config file's own documented purpose for these two variables
("increase in case of hold violations" implies decrease when over-fixing),
and directly targets the observed overshoot — fewer/smaller buffers needed
to clear a smaller required margin. This is a config-only change with no
RTL risk, but it is a real (if modest) reduction in hold-timing safety
margin against process/voltage/temperature variation on actual silicon;
0.05ns / 0.025ns are still non-trivial cushions for this process, not zero.

**Not yet known**: whether the margin reduction is enough to clear the
remaining 51-instance gap. If it's still failing at the same stage after
this, the config lever is probably exhausted and the next options are (a)
further RTL area reduction to widen placement margin further (only the
320-bit register + minor control logic remain, both hard to shrink further
without changing the I/O protocol or genuinely new tricks), or (b)
accepting 4 tiles (`2x2`) as the practical answer for this architecture —
worth weighing against further engineering effort at that point, since
returns are visibly diminishing (large effort for the S-box/diffusion work
already spent, most of the "easy" area is gone).
