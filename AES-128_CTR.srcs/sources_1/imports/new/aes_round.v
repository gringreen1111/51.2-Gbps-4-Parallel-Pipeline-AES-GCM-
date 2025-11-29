`timescale 1ns / 1ps

module aes_round (
    input [127:0] state_in,
    input [127:0] round_key_in,
    input is_final_round,
    output [127:0] state_out
);

    // --- 내부 신호 선언 ---
    wire [127:0] subbytes_out;  // SubBytes 단계의 출력을 저장할 와이어
    wire [127:0] shiftrows_out;
    wire [127:0] mixcolumns_out;


    // ====================================================================
    // 1. SubBytes 단계
    // ====================================================================
    // Verilog의 generate for-loop를 사용하여 aes_sbox 모듈 16개를 생성합니다.
    genvar i; // generate 루프에서 사용할 인덱스 변수
    generate
        for (i = 0; i < 16; i = i + 1) begin : SBOX_INSTANCES
            // state_in의 각 바이트를 sbox의 입력으로 연결하고,
            // 그 출력을 subbytes_out의 해당 바이트 위치에 연결합니다.
            aes_sbox u_sbox (
                .in_byte(state_in[i*8 + 7 : i*8]),
                .out_byte(subbytes_out[i*8 + 7 : i*8])
            );
        end
    endgenerate


// ====================================================================
    // 2. ShiftRows 단계 [Big-Endian 선형 매핑 기준 수정]
    // ====================================================================
    // State Matrix (b0=MSB, b15=LSB)
    // left-side
    // [ b0  b1  b2  b3  ] (Coulumb 0) 127 119 111 103
    // [ b4  b5  b6  b7  ] (Coulumb 1)  95  87  79  71
    // [ b8  b9  b10 b11 ] (Coulumb 2)  63  55  47  39
    // [ b12 b13 b14 b15 ] (Coulumb 3)  31  23  15   7
    // right-side
    
    // Row 0 (b0, b4, b8, b12): No change
    assign shiftrows_out[127:120] = subbytes_out[127:120]; // b0
    assign shiftrows_out[95:88]   = subbytes_out[95:88];   // b4
    assign shiftrows_out[63:56]   = subbytes_out[63:56];   // b8
    assign shiftrows_out[31:24]   = subbytes_out[31:24];   // b12

    // Row 1 (b1, b5 ,b9, b13) -> (b5, b9, b13, b1) (1 shift left)
    assign shiftrows_out[119:112] = subbytes_out[87:80];   // b1 <- b5
    assign shiftrows_out[87:80]   = subbytes_out[55:48];   // b5 <- b9
    assign shiftrows_out[55:48]   = subbytes_out[23:16];   // b9 <- b13
    assign shiftrows_out[23:16]   = subbytes_out[119:112]; // b13 <- b1

    // Row 2 (b2, b6, b10, b14) -> (b10, b14, b2, b6) (2 shifts left)
    assign shiftrows_out[111:104] = subbytes_out[47:40];   // b8 <- b10
    assign shiftrows_out[79:72]   = subbytes_out[15:8];    // b9 <- b11
    assign shiftrows_out[47:40]   = subbytes_out[111:104];  // b10 <- b8
    assign shiftrows_out[15:8]    = subbytes_out[79:72];   // b11 <- b9

    // Row 3 (b3, b7, b11, b15) -> (b15, b3, b7, b11) (3 shifts left)
    assign shiftrows_out[103:96]   = subbytes_out[7:0];     // b12 <- b15
    assign shiftrows_out[71:64]    = subbytes_out[103:96];  // b13 <- b12
    assign shiftrows_out[39:32]    = subbytes_out[71:64];   // b14 <- b13
    assign shiftrows_out[7:0]      = subbytes_out[39:32];    // b15 <- b14

    // ====================================================================
    // 3. MixColumns 단계 [Big-Endian 선형 매핑 기준 수정]
    // ====================================================================
    // "열"을 입력으로 사용하도록 수정합니다.
    // State Matrix (b0=MSB, b15=LSB)
    // [ b0  b1  b2  b3  ] (Coulumb 0) 127 119 111 103
    // [ b4  b5  b6  b7  ] (Coulumb 1)  95  87  79  71
    // [ b8  b9  b10 b11 ] (Coulumb 2)  63  55  47  39
    // [ b12 b13 b14 b15 ] (Coulumb 3)  31  23  15   7
    
    // Column 0 (b0, b1, b2, b3)
    mix_column_unit u_mix_col_0 (
        .col_in(  {shiftrows_out[127:120], shiftrows_out[119:112], shiftrows_out[111:104], shiftrows_out[103:96]} ), 
        .col_out( {mixcolumns_out[127:120], mixcolumns_out[119:112], mixcolumns_out[111:104], mixcolumns_out[103:96]} )
    );
    
    // Column 1 (b4, b5, b6, b7)
    mix_column_unit u_mix_col_1 (
        .col_in(  {shiftrows_out[95:88], shiftrows_out[87:80], shiftrows_out[79:72], shiftrows_out[71:64]} ),
        .col_out( {mixcolumns_out[95:88], mixcolumns_out[87:80], mixcolumns_out[79:72], mixcolumns_out[71:64]} )
    );
    
    // Column 2 (b8, b9, b10, b11)
    mix_column_unit u_mix_col_2 (
        .col_in(  {shiftrows_out[63:56], shiftrows_out[55:48], shiftrows_out[47:40], shiftrows_out[39:32]} ),
        .col_out( {mixcolumns_out[63:56], mixcolumns_out[55:48], mixcolumns_out[47:40], mixcolumns_out[39:32]} )
    );
    
    // Column 3 (b12, b13, b14, b15)
    mix_column_unit u_mix_col_3 (
        .col_in(  {shiftrows_out[31:24], shiftrows_out[23:16], shiftrows_out[15:8], shiftrows_out[7:0]} ),
        .col_out( {mixcolumns_out[31:24], mixcolumns_out[23:16], mixcolumns_out[15:8], mixcolumns_out[7:0]} )
    );

    // ====================================================================
    // 4. AddRoundKey 단계
    // ====================================================================

    assign state_out = (is_final_round ? shiftrows_out : mixcolumns_out) ^ round_key_in;

endmodule