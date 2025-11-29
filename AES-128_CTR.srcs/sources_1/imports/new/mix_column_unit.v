`timescale 1ns / 1ps

module mix_column_unit (
    input  [31:0] col_in,   // 입력 열 (4바이트)
    output [31:0] col_out  // 출력 열 (4바이트)
);

    // 각 바이트를 쉽게 다룰 수 있도록 분리
    // State Matrix (b0=MSB, b15=LSB)
    // [ in0 in1 in2 in3 ] (Coulumb 0) 127 119 111 103 각각 맵핑
    // [ b4  b5  b6  b7  ] (Coulumb 1)  95  87  79  71
    // [ b8  b9  b10 b11 ] (Coulumb 2)  63  55  47  39
    // [ b12 b13 b14 b15 ] (Coulumb 3)  31  23  15   7
    
    wire [7:0] in0, in1, in2, in3;
    assign in0 = col_in[31:24];
    assign in1 = col_in[23:16];
    assign in2 = col_in[15:8];
    assign in3 = col_in[7:0];

    // xtime: x • 0x02 연산
    function [7:0] xtime;
        input [7:0] x;
        begin
            xtime = {x[6:0], 1'b0} ^ (x[7] ? 8'h1B : 8'h00);
        end
    endfunction

    // 각 입력 바이트에 대해 x02 연산을 미리 계산
    wire [7:0] t0 = xtime(in0);
    wire [7:0] t1 = xtime(in1);
    wire [7:0] t2 = xtime(in2);
    wire [7:0] t3 = xtime(in3);

    // MixColumns 행렬 곱셈 수행 (덧셈은 XOR)
    // out[0] = (in[0]•2) + (in[1]•3) + (in[2]•1) + (in[3]•1)
    // out[1] = (in[0]•1) + (in[1]•2) + (in[2]•3) + (in[3]•1)
    // ...
    assign col_out[31:24] = t0 ^ (t1 ^ in1) ^ in2 ^ in3; // out0
    assign col_out[23:16] = in0 ^ t1 ^ (t2 ^ in2) ^ in3; // out1
    assign col_out[15:8]  = in0 ^ in1 ^ t2 ^ (t3 ^ in3); // out2
    assign col_out[7:0]   = (t0 ^ in0) ^ in1 ^ in2 ^ t3; // out3

endmodule