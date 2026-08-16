`default_nettype none

// -----------------------------------------------------------------------------
// tt_um_ascon_permutation
//
// A byte-serial wrapper around the 320-bit Ascon permutation (p^12 / p^8 /
// p^6, plus a single-round debug mode), sized for a TinyTapeout tile.
//
// The permutation itself runs fully in parallel (one full round per clock),
// so the round-function logic is tiny; the only serialization is at the I/O
// boundary, since TT only gives us 8+8+8 pins.
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
//   3. Wait for busy to fall / done to pulse (12, 8, 6, or 1 clock cycles
//      after start, one cycle per round).
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
    localparam IDLE = 1'b0;
    localparam RUN  = 1'b1;

    reg       fsm_state;
    reg [3:0] r_idx;        // index into round-constant table, 0..11
    reg [3:0] rounds_left;  // rounds remaining in current run
    reg       done_pulse;

    // ---- combinational round function on the current state ----
    wire [63:0] x0_cur = state_flat[319:256];
    wire [63:0] x1_cur = state_flat[255:192];
    wire [63:0] x2_cur = state_flat[191:128];
    wire [63:0] x3_cur = state_flat[127:64];
    wire [63:0] x4_cur = state_flat[63:0];

    wire [63:0] x0_nxt, x1_nxt, x2_nxt, x3_nxt, x4_nxt;

    ascon_round u_round (
        .x0_i (x0_cur),
        .x1_i (x1_cur),
        .x2_i (x2_cur),
        .x3_i (x3_cur),
        .x4_i (x4_cur),
        .rc_i (round_const(r_idx)),
        .x0_o (x0_nxt),
        .x1_o (x1_nxt),
        .x2_o (x2_nxt),
        .x3_o (x3_nxt),
        .x4_o (x4_nxt)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            state_flat  <= 320'd0;
            read_cnt    <= 6'd0;
            fsm_state   <= IDLE;
            r_idx       <= 4'd0;
            rounds_left <= 4'd0;
            done_pulse  <= 1'b0;
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
                        fsm_state <= RUN;
                    end
                end

                RUN: begin
                    state_flat <= {x0_nxt, x1_nxt, x2_nxt, x3_nxt, x4_nxt};
                    r_idx      <= r_idx + 4'd1;

                    if (rounds_left == 4'd1) begin
                        fsm_state  <= IDLE;
                        done_pulse <= 1'b1;
                    end
                    rounds_left <= rounds_left - 4'd1;
                end
            endcase
        end
    end

    // ---- output byte selection: byte 0 = MSB of x0, byte 39 = LSB of x4 ----
    assign uo_out = state_flat[(39 - read_cnt) * 8 +: 8];

    assign uio_out = {6'd0, done_pulse, (fsm_state == RUN)};
    assign uio_oe  = 8'b0000_0011;

    // unused-signal lint helper (keeps synthesis tools quiet about ui_in bits
    // that are only sampled during IDLE/load, not structurally "unused")
    wire _unused = &{1'b0, ui_in[7:0], uio_in[7:6]};

endmodule
