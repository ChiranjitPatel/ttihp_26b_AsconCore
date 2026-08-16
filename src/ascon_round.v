`default_nettype none

// -----------------------------------------------------------------------------
// ascon_sbox_slice
//
// The Ascon 5-bit S-box, bitsliced across all 5 state words, applied to a
// WIDTH-bit lane instead of a full 64-bit word. The S-box has no dependency
// between different bit positions within a word, so this is bit-for-bit
// identical to running the full 64-bit version and only keeping WIDTH bits
// of the result: it lets project.v reuse one small instance of this logic
// across multiple bit-lanes per round instead of paying for all 64 bits of
// S-box logic at once (which is the dominant contributor to tile area for
// this design).
//
// c2_i is expected to already have the round constant XORed in by the
// caller, for whichever lane contains the round-constant byte.
//
// Matches the Ascon v1.2 reference specification exactly:
//   t_i = (~x_i) & x_{i+1}   for i in 0..4 (mod 5), on the state AFTER
//                            x0^=x4; x4^=x3; x2^=x1
//   x_i ^= t_{i+1}           for i in 0..4 (mod 5)
//   x1 ^= x0;  x0 ^= x4;  x3 ^= x2;  x2 = ~x2;
// -----------------------------------------------------------------------------
module ascon_sbox_slice #(
    parameter WIDTH = 8
) (
    input  wire [WIDTH-1:0] c0_i,
    input  wire [WIDTH-1:0] c1_i,
    input  wire [WIDTH-1:0] c2_i,  // round constant already XORed in by caller
    input  wire [WIDTH-1:0] c3_i,
    input  wire [WIDTH-1:0] c4_i,
    output wire [WIDTH-1:0] y0_o,
    output wire [WIDTH-1:0] y1_o,
    output wire [WIDTH-1:0] y2_o,
    output wire [WIDTH-1:0] y3_o,
    output wire [WIDTH-1:0] y4_o
);

    wire [WIDTH-1:0] s0a = c0_i ^ c4_i;
    wire [WIDTH-1:0] s4a = c4_i ^ c3_i;
    wire [WIDTH-1:0] s2a = c2_i ^ c1_i;
    wire [WIDTH-1:0] s1a = c1_i;
    wire [WIDTH-1:0] s3a = c3_i;

    wire [WIDTH-1:0] t0 = (~s0a) & s1a;
    wire [WIDTH-1:0] t1 = (~s1a) & s2a;
    wire [WIDTH-1:0] t2 = (~s2a) & s3a;
    wire [WIDTH-1:0] t3 = (~s3a) & s4a;
    wire [WIDTH-1:0] t4 = (~s4a) & s0a;

    wire [WIDTH-1:0] s0b = s0a ^ t1;
    wire [WIDTH-1:0] s1b = s1a ^ t2;
    wire [WIDTH-1:0] s2b = s2a ^ t3;
    wire [WIDTH-1:0] s3b = s3a ^ t4;
    wire [WIDTH-1:0] s4b = s4a ^ t0;

    wire [WIDTH-1:0] s1c = s1b ^ s0b;
    wire [WIDTH-1:0] s0c = s0b ^ s4b;
    wire [WIDTH-1:0] s3c = s3b ^ s2b;
    wire [WIDTH-1:0] s2c = ~s2b;

    assign y0_o = s0c;
    assign y1_o = s1c;
    assign y2_o = s2c;
    assign y3_o = s3c;
    assign y4_o = s4b;

endmodule

// -----------------------------------------------------------------------------
// ascon_diffusion
//
// The Ascon linear diffusion layer (word-wise rotate + XOR), applied to the
// full post-S-box state. Unlike the S-box, this needs all 64 bits of each
// word at once (each output bit mixes several bit positions of the same
// word), so it stays fully combinational and full-width; only the S-box
// step is time-multiplexed by the caller.
// -----------------------------------------------------------------------------
module ascon_diffusion (
    input  wire [63:0] sb0_i,
    input  wire [63:0] sb1_i,
    input  wire [63:0] sb2_i,
    input  wire [63:0] sb3_i,
    input  wire [63:0] sb4_i,
    output wire [63:0] x0_o,
    output wire [63:0] x1_o,
    output wire [63:0] x2_o,
    output wire [63:0] x3_o,
    output wire [63:0] x4_o
);

    function [63:0] rotr;
        input [63:0] w;
        input [6:0]  n;
        begin
            rotr = (w >> n) | (w << (64 - n));
        end
    endfunction

    assign x0_o = sb0_i ^ rotr(sb0_i, 19) ^ rotr(sb0_i, 28);
    assign x1_o = sb1_i ^ rotr(sb1_i, 61) ^ rotr(sb1_i, 39);
    assign x2_o = sb2_i ^ rotr(sb2_i,  1) ^ rotr(sb2_i,  6);
    assign x3_o = sb3_i ^ rotr(sb3_i, 10) ^ rotr(sb3_i, 17);
    assign x4_o = sb4_i ^ rotr(sb4_i,  7) ^ rotr(sb4_i, 41);

endmodule
