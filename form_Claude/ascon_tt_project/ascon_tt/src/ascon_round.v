`default_nettype none

// -----------------------------------------------------------------------------
// ascon_round
//
// One round of the Ascon permutation, applied to the 320-bit state
// (five 64-bit words x0..x4), fully combinational.
//
// Matches the Ascon v1.2 reference specification exactly:
//   1. Add round constant (XOR into x2)
//   2. 5-bit S-box, applied bitsliced across all 5 words
//   3. Linear diffusion layer (word-wise rotate + XOR)
//
// Verified bit-for-bit against the Python reference implementation
// (ascon_permutation() from the `ascon` PyPI reference package,
// which itself implements the NIST SP 800-232 / Ascon v1.2 spec).
// -----------------------------------------------------------------------------
module ascon_round (
    input  wire [63:0] x0_i,
    input  wire [63:0] x1_i,
    input  wire [63:0] x2_i,
    input  wire [63:0] x3_i,
    input  wire [63:0] x4_i,
    input  wire [7:0]  rc_i,      // round constant for this round
    output wire [63:0] x0_o,
    output wire [63:0] x1_o,
    output wire [63:0] x2_o,
    output wire [63:0] x3_o,
    output wire [63:0] x4_o
);

    // ---- add round constant ----
    wire [63:0] c0 = x0_i;
    wire [63:0] c1 = x1_i;
    wire [63:0] c2 = x2_i ^ {56'd0, rc_i};
    wire [63:0] c3 = x3_i;
    wire [63:0] c4 = x4_i;

    // ---- substitution layer (bitsliced 5-bit S-box) ----
    // Directly follows the Ascon reference pseudocode:
    //   x0 ^= x4;  x4 ^= x3;  x2 ^= x1;
    //   t_i = (~x_i) & x_{i+1}   for i in 0..4 (mod 5), on the state AFTER the line above
    //   x_i ^= t_{i+1}           for i in 0..4 (mod 5)
    //   x1 ^= x0;  x0 ^= x4;  x3 ^= x2;  x2 = ~x2;
    wire [63:0] s0a = c0 ^ c4;
    wire [63:0] s4a = c4 ^ c3;
    wire [63:0] s2a = c2 ^ c1;
    // s1a, s3a unchanged at this point
    wire [63:0] s1a = c1;
    wire [63:0] s3a = c3;

    wire [63:0] t0 = (~s0a) & s1a;
    wire [63:0] t1 = (~s1a) & s2a;
    wire [63:0] t2 = (~s2a) & s3a;
    wire [63:0] t3 = (~s3a) & s4a;
    wire [63:0] t4 = (~s4a) & s0a;

    wire [63:0] s0b = s0a ^ t1;
    wire [63:0] s1b = s1a ^ t2;
    wire [63:0] s2b = s2a ^ t3;
    wire [63:0] s3b = s3a ^ t4;
    wire [63:0] s4b = s4a ^ t0;

    wire [63:0] s1c = s1b ^ s0b;
    wire [63:0] s0c = s0b ^ s4b;
    wire [63:0] s3c = s3b ^ s2b;
    wire [63:0] s2c = ~s2b;

    wire [63:0] sb0 = s0c;
    wire [63:0] sb1 = s1c;
    wire [63:0] sb2 = s2c;
    wire [63:0] sb3 = s3c;
    wire [63:0] sb4 = s4b;

    // ---- linear diffusion layer ----
    function [63:0] rotr;
        input [63:0] w;
        input [6:0]  n;
        begin
            rotr = (w >> n) | (w << (64 - n));
        end
    endfunction

    assign x0_o = sb0 ^ rotr(sb0, 19) ^ rotr(sb0, 28);
    assign x1_o = sb1 ^ rotr(sb1, 61) ^ rotr(sb1, 39);
    assign x2_o = sb2 ^ rotr(sb2,  1) ^ rotr(sb2,  6);
    assign x3_o = sb3 ^ rotr(sb3, 10) ^ rotr(sb3, 17);
    assign x4_o = sb4 ^ rotr(sb4,  7) ^ rotr(sb4, 41);

endmodule
