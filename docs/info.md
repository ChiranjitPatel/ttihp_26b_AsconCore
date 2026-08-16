<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A byte-serial hardware implementation of the Ascon permutation — the core
building block of Ascon, the NIST-standardized lightweight AEAD cipher and
hash function (NIST SP 800-232).

The 320-bit Ascon permutation state (five 64-bit words `x0..x4`) is stored
in a single register. Each round is split into a **bit-serial S-box phase**
(64 cycles, reusing one 1-bit-wide S-box instance across all 64 bit
positions of each word — the S-box has no dependency between bit
positions, so this is bit-for-bit equivalent to computing it in one shot)
followed by **one full-width diffusion cycle**, for 65 cycles per round.
This trades a bit of permutation latency for tile area versus computing
the whole 320-bit-wide S-box in parallel. The host I/O is also serialized,
since TinyTapeout gives us just 8 dedicated inputs, 8 dedicated outputs,
and 8 bidirectional pins — nowhere near enough for a 320-bit parallel
interface.

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


## How to test

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
3. Wait for `busy` to fall (65 cycles per round — 64 S-box lanes + 1
   diffusion cycle — times 12, 8, 6, or 1 rounds after `start`).
4. Pulse `shift_out` 40 times, reading `uo_out` each time, to read the
   result out in the same byte order. The read pointer auto-resets after
   a run completes, or can be reset manually with `rst_rdptr` to re-read.

## External hardware

List external hardware used in your project (e.g. PMOD, LED display, etc), if any- need to update
