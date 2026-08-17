`default_nettype none

// -----------------------------------------------------------------------------
// tt_um_ascon_permutation
//
// A byte-serial wrapper around the 320-bit Ascon permutation (p^12 / p^8 /
// p^6, plus a single-round debug mode), sized for a TinyTapeout tile.
//
// Both the S-box and the diffusion (linear) layer are bit-serialized to
// keep combinational area minimal, at the cost of permutation latency
// (still trivial next to the byte-serial I/O time, and next to nothing
// for a non-realtime demonstrator chip). Each round:
//   1. S-box phase (64 cycles): each word is a rotate-right-by-1-per-cycle
//      shift register; the S-box has no dependency between bit positions,
//      so reading/writing a fixed position (bit 0 in, bit 63 out) each
//      cycle is bit-for-bit equivalent to computing it in one shot, with
//      no address decoder needed anywhere.
//   2. Diffusion phase (5 x 65 = 325 cycles): processes one word at a time.
//      For 64 cycles, that word rotates (read-only, no injection this
//      time) while a shared accumulator reads 3 *fixed* taps of the
//      rotating word (bit 0, and the word's two constant rotation
//      amounts) each cycle and shifts the XOR of them in — the same
//      "rotate exposes every needed bit at a fixed physical position over
//      time" trick as the S-box, just with 3 taps instead of 1. After 64
//      cycles the accumulator holds the fully diffused word (proved
//      algebraically and by direct simulation to match the reference
//      rotr-based formula), which is written back in 1 more cycle. This
//      needs only one extra 64-bit accumulator (reused across all 5
//      words), not a second full 320-bit buffer.
// 389 cycles/round total (64 + 325); a p^12 permutation is ~4.7k cycles.
// (Two earlier, cheaper attempts are documented in knowledge.md: a
// byte-lane S-box wasn't enough to fit a 1x2 tile, and a runtime-addressed
// bit-serial S-box wasn't wired this way and cost more in write-decoder
// area than it saved.)
//
// ---------------------------------------------------------------------------
// Host protocol (all control bits live on uio_in / uio_out)
// ---------------------------------------------------------------------------
//   ui_in[7:0]    : data byte in (used by load_byte)
//   uo_out[7:0]   : data byte out (selected by the read pointer)
//
//   uio_in[0]     : load_byte   - pulse 1 cycle to shift ui_in into the state
//   uio_in[1]     : shift_out   - pulse 1 cycle to advance the read pointer
//   uio_in[3:2]   : round_sel   - 00 = 12 rounds (p^a)
//                                 01 = 8  rounds (p^b, Ascon-128a)
//                                 10 = 6  rounds (p^b, Ascon-128)
//                                 11 = 1  round  (debug: single-round step)
//   uio_in[4]     : start       - pulse 1 cycle to launch the permutation
//   uio_in[5]     : rst_rdptr   - pulse 1 cycle to reset the read pointer to 0
//   uio_in[7:6]   : unused
//
//   uio_out[0]    : busy        - high while the permutation is running
//   uio_out[1]    : done        - 1-cycle pulse when the permutation finishes
//   uio_out[7:2]  : 0
//
// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------
//   1. With load_byte pulsed once per cycle, present the 320-bit state on
//      ui_in as 40 bytes, most-significant byte of x0 first, down to the
//      least-significant byte of x4 last (big-endian, matches the Ascon
//      spec's word layout State = x0 || x1 || x2 || x3 || x4).
//   2. Set round_sel, pulse start for 1 cycle.
//   3. Wait for busy to fall / done to pulse (389 clock cycles per round: 64
//      S-box lanes + 5 words x 65 diffusion cycles, x 12/8/6/1 rounds
//      depending on round_sel).
//   4. Pulse shift_out 40 times, reading uo_out after each pulse, to shift
//      the resulting state out in the same big-endian byte order. The read
//      pointer auto-resets to 0 when a permutation completes, and can also
//      be reset manually with rst_rdptr (e.g. to re-read without re-running).
// -----------------------------------------------------------------------------
module tt_um_ascon_permutation (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---- control signal aliases ----
    wire       load_byte  = uio_in[0];
    wire       shift_out  = uio_in[1];
    wire [1:0] round_sel  = uio_in[3:2];
    wire       start      = uio_in[4];
    wire       rst_rdptr  = uio_in[5];

    // ---- state register: 320 bits = x0[319:256] || x1 || x2 || x3 || x4[63:0]
    reg [319:0] state_flat;

    // ---- read pointer (which of the 40 bytes is presented on uo_out) ----
    reg [5:0] read_cnt;

    // ---- round-constant ROM (Ascon v1.2, p^12 constants 0xf0..0x4b) ----
    function [7:0] round_const;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  round_const = 8'hf0;
                4'd1:  round_const = 8'he1;
                4'd2:  round_const = 8'hd2;
                4'd3:  round_const = 8'hc3;
                4'd4:  round_const = 8'hb4;
                4'd5:  round_const = 8'ha5;
                4'd6:  round_const = 8'h96;
                4'd7:  round_const = 8'h87;
                4'd8:  round_const = 8'h78;
                4'd9:  round_const = 8'h69;
                4'd10: round_const = 8'h5a;
                default: round_const = 8'h4b; // idx 11
            endcase
        end
    endfunction

    // ---- FSM ----
    localparam IDLE     = 2'd0;
    localparam SBOX     = 2'd1;  // bit-serial S-box: 64 cycles, 1 bit/word/cycle
    localparam DIFF_ROT = 2'd2;  // diffuse one word: 64 rotate+accumulate cycles
    localparam DIFF_WB  = 2'd3;  // write that word's diffused result back, 1 cycle

    reg [1:0]  fsm_state;
    reg [3:0]  r_idx;        // index into round-constant table, 0..11
    reg [3:0]  rounds_left;  // rounds remaining in current run
    reg        done_pulse;
    reg [5:0]  lane_idx;     // sub-cycle counter (0..63): S-box bit lane, or
                              // diffusion rotate step within the active word
    reg [2:0]  word_idx;     // which word (0..4) diffusion is currently on
    reg [63:0] diff_acc;     // shared accumulator, reused across all 5 words

    // ---- word views of the state register ----
    wire [63:0] x0_cur = state_flat[319:256];
    wire [63:0] x1_cur = state_flat[255:192];
    wire [63:0] x2_cur = state_flat[191:128];
    wire [63:0] x3_cur = state_flat[127:64];
    wire [63:0] x4_cur = state_flat[63:0];

    // ---- S-box: bit 0 of each word, reused across the round ----
    // Each word is treated as a rotate-right-by-1-per-cycle shift register
    // during the SBOX phase (see the SBOX case below), so the "current
    // lane" is always at the same fixed position (bit 0) — no runtime
    // address/decoder needed, unlike indexing state_flat at a
    // lane-counter-derived offset (which was tried first and costs a
    // 64-way decoder + a compare/mux per flop, more than it saved).
    wire [7:0] rc_cur = round_const(r_idx);
    wire       rc_bit = rc_cur[lane_idx[2:0]];

    wire c0_slice = x0_cur[0];
    wire c1_slice = x1_cur[0];
    // round constant only touches byte 0 (bits 7:0) of x2
    wire c2_slice = x2_cur[0] ^ ((lane_idx < 6'd8) ? rc_bit : 1'b0);
    wire c3_slice = x3_cur[0];
    wire c4_slice = x4_cur[0];

    wire y0_slice, y1_slice, y2_slice, y3_slice, y4_slice;

    ascon_sbox_slice #(.WIDTH(1)) u_sbox_slice (
        .c0_i (c0_slice),
        .c1_i (c1_slice),
        .c2_i (c2_slice),
        .c3_i (c3_slice),
        .c4_i (c4_slice),
        .y0_o (y0_slice),
        .y1_o (y1_slice),
        .y2_o (y2_slice),
        .y3_o (y3_slice),
        .y4_o (y4_slice)
    );

    // ---- diffusion: 3 fixed taps (bit 0, and the word's two constant
    // rotation amounts) of whichever word is currently rotating, selected
    // by a small 5-way mux on word_idx — all the tap positions themselves
    // are compile-time constants, so this costs nothing like the 64-way
    // decoder that would be needed for a runtime-addressed version.
    wire diff_tap0 = (word_idx == 3'd0) ? x0_cur[0] :
                      (word_idx == 3'd1) ? x1_cur[0] :
                      (word_idx == 3'd2) ? x2_cur[0] :
                      (word_idx == 3'd3) ? x3_cur[0] : x4_cur[0];

    wire diff_tap1 = (word_idx == 3'd0) ? x0_cur[19] :
                      (word_idx == 3'd1) ? x1_cur[61] :
                      (word_idx == 3'd2) ? x2_cur[1]  :
                      (word_idx == 3'd3) ? x3_cur[10] : x4_cur[7];

    wire diff_tap2 = (word_idx == 3'd0) ? x0_cur[28] :
                      (word_idx == 3'd1) ? x1_cur[39] :
                      (word_idx == 3'd2) ? x2_cur[6]  :
                      (word_idx == 3'd3) ? x3_cur[17] : x4_cur[41];

    wire diff_bit = diff_tap0 ^ diff_tap1 ^ diff_tap2;

    always @(posedge clk) begin
        if (!rst_n) begin
            state_flat  <= 320'd0;
            read_cnt    <= 6'd0;
            fsm_state   <= IDLE;
            r_idx       <= 4'd0;
            rounds_left <= 4'd0;
            done_pulse  <= 1'b0;
            lane_idx    <= 6'd0;
            word_idx    <= 3'd0;
            diff_acc    <= 64'd0;
        end else if (ena) begin
            done_pulse <= 1'b0;

            case (fsm_state)
                IDLE: begin
                    if (load_byte) begin
                        // shift the incoming byte in at the LSB; after 40
                        // pulses the first byte loaded ends up at the MSB
                        state_flat <= {state_flat[311:0], ui_in};
                    end

                    if (rst_rdptr) begin
                        read_cnt <= 6'd0;
                    end else if (shift_out) begin
                        if (read_cnt != 6'd39)
                            read_cnt <= read_cnt + 6'd1;
                    end

                    if (start) begin
                        case (round_sel)
                            2'b00: begin r_idx <= 4'd0;  rounds_left <= 4'd12; end // p^12
                            2'b01: begin r_idx <= 4'd4;  rounds_left <= 4'd8;  end // p^8
                            2'b10: begin r_idx <= 4'd6;  rounds_left <= 4'd6;  end // p^6
                            default: begin r_idx <= 4'd11; rounds_left <= 4'd1; end // debug: 1 round
                        endcase
                        read_cnt  <= 6'd0;
                        lane_idx  <= 6'd0;
                        fsm_state <= SBOX;
                    end
                end

                SBOX: begin
                    // rotate each word right by 1 (pure wiring, like rotr)
                    // and inject the freshly computed S-box bit at the top
                    // instead of the bit that would naturally rotate in —
                    // no address decoder needed, just a fixed-position
                    // read (bit 0) and a fixed-position write (bit 63)
                    state_flat[319:256] <= {y0_slice, state_flat[319:257]};
                    state_flat[255:192] <= {y1_slice, state_flat[255:193]};
                    state_flat[191:128] <= {y2_slice, state_flat[191:129]};
                    state_flat[127:64]  <= {y3_slice, state_flat[127:65]};
                    state_flat[63:0]    <= {y4_slice, state_flat[63:1]};

                    if (lane_idx == 6'd63) begin
                        fsm_state <= DIFF_ROT;
                        word_idx  <= 3'd0;
                        lane_idx  <= 6'd0;
                    end else begin
                        lane_idx <= lane_idx + 6'd1;
                    end
                end

                DIFF_ROT: begin
                    // rotate only the word currently being diffused (pure
                    // wiring, no injection this time — it self-restores to
                    // its original value after 64 steps); meanwhile shift
                    // this cycle's tap XOR into the shared accumulator
                    case (word_idx)
                        3'd0: state_flat[319:256] <= {x0_cur[0], x0_cur[63:1]};
                        3'd1: state_flat[255:192] <= {x1_cur[0], x1_cur[63:1]};
                        3'd2: state_flat[191:128] <= {x2_cur[0], x2_cur[63:1]};
                        3'd3: state_flat[127:64]  <= {x3_cur[0], x3_cur[63:1]};
                        default: state_flat[63:0] <= {x4_cur[0], x4_cur[63:1]};
                    endcase

                    diff_acc <= {diff_bit, diff_acc[63:1]};

                    if (lane_idx == 6'd63) begin
                        fsm_state <= DIFF_WB;
                    end else begin
                        lane_idx <= lane_idx + 6'd1;
                    end
                end

                DIFF_WB: begin
                    case (word_idx)
                        3'd0: state_flat[319:256] <= diff_acc;
                        3'd1: state_flat[255:192] <= diff_acc;
                        3'd2: state_flat[191:128] <= diff_acc;
                        3'd3: state_flat[127:64]  <= diff_acc;
                        default: state_flat[63:0] <= diff_acc;
                    endcase

                    lane_idx <= 6'd0;

                    if (word_idx == 3'd4) begin
                        // all 5 words diffused: this round is done
                        r_idx    <= r_idx + 4'd1;
                        word_idx <= 3'd0;

                        if (rounds_left == 4'd1) begin
                            fsm_state  <= IDLE;
                            done_pulse <= 1'b1;
                        end else begin
                            fsm_state <= SBOX;
                        end
                        rounds_left <= rounds_left - 4'd1;
                    end else begin
                        word_idx  <= word_idx + 3'd1;
                        fsm_state <= DIFF_ROT;
                    end
                end
            endcase
        end
    end

    // ---- output byte selection: byte 0 = MSB of x0, byte 39 = LSB of x4 ----
    assign uo_out = state_flat[(39 - read_cnt) * 8 +: 8];

    assign uio_out = {6'd0, done_pulse, (fsm_state != IDLE)};
    assign uio_oe  = 8'b0000_0011;

    // unused-signal lint helper (keeps synthesis tools quiet about ui_in bits
    // that are only sampled during IDLE/load, not structurally "unused")
    wire _unused = &{1'b0, ui_in[7:0], uio_in[7:6]};

endmodule
