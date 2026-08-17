# Ascon Permutation Core — TinyTapeout IHP26b

A byte-serial hardware implementation of the Ascon permutation — the core
building block of Ascon, the NIST-standardized lightweight AEAD cipher and
hash function (NIST SP 800-232).

## What's implemented

The 320-bit Ascon permutation state (five 64-bit words `x0..x4`) is stored
in a single register. Both the S-box and the linear diffusion layer are
bit-serialized to minimize combinational area: each round is a
**bit-serial S-box phase** (64 cycles, reusing one 1-bit-wide S-box
instance across all 64 bit positions of each word — the S-box has no
dependency between bit positions, so this is bit-for-bit equivalent to
computing it in one shot) followed by a **word-sequential diffusion
phase** (5 words x 65 cycles, reusing one shared accumulator — each word
rotates while 3 fixed bit positions are tapped and XORed each cycle),
for 389 cycles per round total.
This trades a bit of permutation latency (12 rounds = 108 cycles for
`p^12`, still small next to the I/O time below) to avoid paying tile area
for 64 bits' worth of S-box logic running in parallel. The host I/O is
also serialized, since TinyTapeout gives us just 8 dedicated inputs, 8
dedicated outputs, and 8 bidirectional pins — nowhere near enough for a
320-bit parallel interface.

Supported permutation variants (selected via `round_sel`):
| `round_sel` | Rounds | Corresponds to |
|---|---|---|
| `00` | 12 | `p^12` — Ascon initialization/finalization |
| `01` | 8  | `p^8`  — Ascon-128a message processing |
| `10` | 6  | `p^6`  — Ascon-128 message processing |
| `11` | 1  | Single-round debug/step mode |

This is a **permutation-only** core (no key/nonce storage, padding, or
AEAD framing) — it exposes `p^r(state)` as a function. That keeps it as
small as practical while still being a genuine, verifiable hardware
implementation of Ascon's core primitive. A full AEAD wrapper is a natural
follow-up project once this is proven on silicon.

## Protocol

All control lives on `uio_in` / `uio_out`; data moves 1 byte at a time on
`ui_in` / `uo_out`.

```
uio_in[0]   load_byte   - pulse 1 cycle to shift ui_in into the state
uio_in[1]   shift_out   - pulse 1 cycle to advance the read pointer
uio_in[3:2] round_sel   - 00=12 rounds, 01=8, 10=6, 11=1 (debug)
uio_in[4]   start       - pulse 1 cycle to launch the permutation
uio_in[5]   rst_rdptr   - pulse 1 cycle to reset the read pointer to 0

uio_out[0]  busy        - high while the permutation is running
uio_out[1]  done        - 1-cycle pulse when the permutation finishes
```

Usage:
1. Pulse `load_byte` 40 times with the state on `ui_in`, most-significant
   byte of `x0` first, down to the least-significant byte of `x4` last
   (matches the spec's `State = x0 || x1 || x2 || x3 || x4` layout).
2. Set `round_sel`, pulse `start` for 1 cycle.
3. Wait for `busy` to fall (389 cycles per round — 64 S-box lanes + 5
   words x 65 diffusion cycles — times 12, 8, 6, or 1 rounds after
   `start`).
4. Pulse `shift_out` 40 times, reading `uo_out` each time, to read the
   result out in the same byte order. The read pointer auto-resets after
   a run completes, or can be reset manually with `rst_rdptr` to re-read.

## Verification

- `src/ascon_round.v` was checked bit-for-bit against the `ascon` PyPI
  reference implementation (itself an implementation of the Ascon v1.2
  spec) for the round constants, S-box, and diffusion layer.
- `test/test.py` (cocotb) verifies the full RTL against:
  - Fixed known-answer vectors for the all-zero state under `p^12`,
    `p^8`, and `p^6`.
  - A non-trivial (IV-like) state under `p^12`.
  - Single-round debug mode.
  - Load/readback passthrough (no permutation run).
  - 12 randomized vectors (3 per round count) cross-checked against a
    self-contained from-spec Python reference embedded in the test file.
- All of the above pass under Icarus Verilog + cocotb (`cd test && make`).

## Area / tile budget

No multiplier and no memory array beyond the 320-bit state register and a
12-entry x 8-bit round-constant ROM, but a fully-parallel one-round-per-cycle
round function (the whole S-box and diffusion layer built at full 320-bit
width, computed once per cycle) was initially the single largest
contributor to area — comparable to or larger than the 320-bit state
register itself. Both are now bit-serialized instead: `ascon_round.v`
provides the S-box as a narrow, reusable `ascon_sbox_slice` (instantiated
1 bit wide, driven across 64 lanes per round), and `project.v` computes
diffusion word-by-word using a single shared 64-bit accumulator rather
than a full parallel copy. See [`knowledge.md`](../knowledge.md) at the
repo root for the full area analysis and hardening-run history.
