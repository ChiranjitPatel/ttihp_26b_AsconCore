# Ascon Permutation Core — TinyTapeout IHP26b

A byte-serial hardware implementation of the Ascon permutation — the core
building block of Ascon, the NIST-standardized lightweight AEAD cipher and
hash function (NIST SP 800-232).

## What's implemented

The 320-bit Ascon permutation state (five 64-bit words `x0..x4`) is stored
in a single register and updated **one full round per clock cycle** using
fully combinational round logic (substitution layer + linear diffusion
layer). Only the host I/O is serialized, since TinyTapeout gives us just
8 dedicated inputs, 8 dedicated outputs, and 8 bidirectional pins — nowhere
near enough for a 320-bit parallel interface.

Supported permutation variants (selected via `round_sel`):
| `round_sel` | Rounds | Corresponds to |
|---|---|---|
| `00` | 12 | `p^12` — Ascon initialization/finalization |
| `01` | 8  | `p^8`  — Ascon-128a message processing |
| `10` | 6  | `p^6`  — Ascon-128 message processing |
| `11` | 1  | Single-round debug/step mode |

This is a **permutation-only** core (no key/nonce storage, padding, or
AEAD framing) — it exposes `p^r(state)` as a function. That keeps it small
enough for a 1x1 tile while still being a genuine, verifiable hardware
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
3. Wait for `busy` to fall (12, 8, 6, or 1 cycles after `start`).
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

The round function itself is small: five 64-bit XOR/AND/NOT networks for
the S-box layer plus fixed-wiring rotations for diffusion — no multiplier,
no memory array beyond the 320-bit state register and a 12-entry x 8-bit
round-constant ROM. The dominant cost is the 320-bit state register itself
plus the 40-byte serial load/unload control logic, which should comfortably
fit a 1x1 tile on `ihp-sg13g2`.
