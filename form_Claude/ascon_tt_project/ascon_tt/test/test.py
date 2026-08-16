"""
Cocotb testbench for tt_um_ascon_permutation.

Verifies the RTL byte-serial interface against:
  1. Fixed known-answer vectors (all-zero state and a non-trivial state,
     for p^12 / p^8 / p^6 / single-round debug mode).
  2. Randomized cross-checks against a from-spec Python reference
     implementation of the Ascon permutation (self-contained here, no
     external `ascon` package dependency, so this test runs anywhere).

The Python reference below is written directly from the Ascon v1.2 /
NIST SP 800-232 specification and has been cross-checked against the
`ascon` PyPI reference package during development.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

# Icarus Verilog's cocotb VPI callbacks can resume a coroutine fractionally
# before a same-edge non-blocking (register) update has fully propagated to
# combinational logic that reads it (e.g. our read-pointer -> uo_out mux).
# A 1ns settle after every clock step sidesteps that race without affecting
# the DUT, which only ever samples inputs at the rising edge itself.
async def tick(dut):
    await ClockCycles(dut.clk, 1)
    await Timer(1, unit="ns")


# -----------------------------------------------------------------------
# Python reference implementation of the Ascon permutation (from spec)
# -----------------------------------------------------------------------
MASK64 = (1 << 64) - 1


def rotr(x, n):
    return ((x >> n) | (x << (64 - n))) & MASK64


def ascon_permutation_ref(state, rounds):
    """state: list of 5 64-bit ints [x0..x4]; rounds: 1, 6, 8, or 12."""
    s = list(state)
    for r in range(12 - rounds, 12):
        rc = (0xF0 - r * 0x10 + r * 0x1) & 0xFF
        s[2] ^= rc

        s[0] ^= s[4]
        s[4] ^= s[3]
        s[2] ^= s[1]
        t = [((~s[i]) & MASK64) & s[(i + 1) % 5] for i in range(5)]
        for i in range(5):
            s[i] ^= t[(i + 1) % 5]
        s[1] ^= s[0]
        s[0] ^= s[4]
        s[3] ^= s[2]
        s[2] ^= MASK64

        s[0] = s[0] ^ rotr(s[0], 19) ^ rotr(s[0], 28)
        s[1] = s[1] ^ rotr(s[1], 61) ^ rotr(s[1], 39)
        s[2] = s[2] ^ rotr(s[2], 1) ^ rotr(s[2], 6)
        s[3] = s[3] ^ rotr(s[3], 10) ^ rotr(s[3], 17)
        s[4] = s[4] ^ rotr(s[4], 7) ^ rotr(s[4], 41)
    return s


def state_to_bytes(words):
    out = bytearray()
    for w in words:
        out += w.to_bytes(8, "big")
    return bytes(out)


def bytes_to_state(b):
    assert len(b) == 40
    return [int.from_bytes(b[i * 8:(i + 1) * 8], "big") for i in range(5)]


# round_sel encoding used by uio_in[3:2]
ROUND_SEL = {12: 0b00, 8: 0b01, 6: 0b10, 1: 0b11}

LOAD_BYTE = 1 << 0
SHIFT_OUT = 1 << 1
START = 1 << 4
RST_RDPTR = 1 << 5


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await tick(dut)


async def load_state(dut, state_bytes):
    assert len(state_bytes) == 40
    for b in state_bytes:
        dut.ui_in.value = b
        dut.uio_in.value = LOAD_BYTE
        await tick(dut)
    dut.uio_in.value = 0


async def run_permutation(dut, rounds):
    sel = ROUND_SEL[rounds]
    dut.uio_in.value = (sel << 2) | START
    await tick(dut)
    dut.uio_in.value = 0
    # busy (uio_out[0]) stays high while the permutation runs
    while int(dut.uio_out.value) & 0x1:
        await tick(dut)


async def read_state(dut):
    out = bytearray()
    dut.uio_in.value = RST_RDPTR
    await tick(dut)
    dut.uio_in.value = 0
    for _ in range(40):
        out.append(int(dut.uo_out.value))
        dut.uio_in.value = SHIFT_OUT
        await tick(dut)
        dut.uio_in.value = 0
    return bytes(out)


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def permute_and_check(dut, state_words, rounds):
    expected = ascon_permutation_ref(state_words, rounds)
    await load_state(dut, state_to_bytes(state_words))
    await run_permutation(dut, rounds)
    got_bytes = await read_state(dut)
    got_words = bytes_to_state(got_bytes)
    assert got_words == expected, (
        f"rounds={rounds}: got={[hex(w) for w in got_words]} "
        f"expected={[hex(w) for w in expected]}"
    )


@cocotb.test()
async def test_allzero_p12(dut):
    """p^12 permutation of the all-zero state."""
    await start_clock(dut)
    await reset_dut(dut)
    await permute_and_check(dut, [0, 0, 0, 0, 0], 12)


@cocotb.test()
async def test_allzero_p8(dut):
    """p^8 permutation of the all-zero state (Ascon-128a rounds)."""
    await start_clock(dut)
    await reset_dut(dut)
    await permute_and_check(dut, [0, 0, 0, 0, 0], 8)


@cocotb.test()
async def test_allzero_p6(dut):
    """p^6 permutation of the all-zero state (Ascon-128 rounds)."""
    await start_clock(dut)
    await reset_dut(dut)
    await permute_and_check(dut, [0, 0, 0, 0, 0], 6)


@cocotb.test()
async def test_iv_like_p12(dut):
    """p^12 permutation starting from a non-trivial, IV-like state."""
    await start_clock(dut)
    await reset_dut(dut)
    state = [
        0x80400C0600000000,
        0x1122334455667788,
        0x0011223344556677,
        0xAABBCCDDEEFF0011,
        0x1234567890ABCDEF,
    ]
    await permute_and_check(dut, state, 12)


@cocotb.test()
async def test_single_round_debug(dut):
    """Single-round debug mode (round_sel = 11)."""
    await start_clock(dut)
    await reset_dut(dut)
    state = [
        0x0123456789ABCDEF,
        0xFEDCBA9876543210,
        0xDEADBEEFCAFEBABE,
        0x0011223344556677,
        0x8899AABBCCDDEEFF,
    ]
    await permute_and_check(dut, state, 1)


@cocotb.test()
async def test_readback_passthrough(dut):
    """Loading a state and reading it back (no run) should be identity."""
    await start_clock(dut)
    await reset_dut(dut)
    state = [
        0x0011223344556677,
        0x8899AABBCCDDEEFF,
        0xFFEEDDCCBBAA9988,
        0x7766554433221100,
        0xDEADBEEFCAFEBABE,
    ]
    data = state_to_bytes(state)
    await load_state(dut, data)
    got = await read_state(dut)
    assert got == data, f"passthrough mismatch: got={got.hex()} exp={data.hex()}"


@cocotb.test()
async def test_random_vectors(dut):
    """Randomized cross-check against the Python reference, all round counts."""
    await start_clock(dut)
    await reset_dut(dut)
    random.seed(0xA5C0)
    for rounds in (12, 8, 6, 1):
        for _ in range(3):
            words = [random.getrandbits(64) for _ in range(5)]
            await permute_and_check(dut, words, rounds)
