`timescale 1ns / 1ps

module ghash_core (
    input wire clk,
    input wire rst,
    input wire [127:0] h_key_in,
    input wire [127:0] tag_mask_in,
    
    // 128비트 입력 (기존 Serial 인터페이스 유지)
    input wire [127:0] data_in,
    input wire         valid_in,
    
    output wire [127:0] final_tag_out,
    output reg          done,
    output reg          tag_valid
);

    reg [127:0] current_tag;
    reg [10:0]  step_cnt;

    // ========================================================================
    // [Helper Function 1] 64-bit Polynomial Multiplier (Carry-less)
    // 64비트 두 개를 곱해서 127비트 결과를 만듭니다. (기본 연산 단위)
    // ========================================================================
    function [126:0] pmul_64;
        input [63:0] A, B;
        reg [126:0] p;
        integer i;
        begin
            p = 0;
            for (i = 0; i < 64; i = i + 1) begin
                if (A[i]) p = p ^ (B << i);
            end
            pmul_64 = p;
        end
    endfunction

    // ========================================================================
    // [Helper Function 2] Bit Reversal (128-bit)
    // GCM은 LSB가 x^127이므로, 일반 수학 연산을 위해 비트를 뒤집어줍니다.
    // ========================================================================
    function [127:0] bit_reverse;
        input [127:0] in;
        integer i;
        begin
            for (i = 0; i < 128; i = i + 1) begin
                bit_reverse[i] = in[127-i];
            end
        end
    endfunction

    // ========================================================================
    // [Main Function] 128-bit Karatsuba Multiplier
    // 128비트를 64비트로 쪼개서 계산 후 합칩니다.
    // ========================================================================
    function [127:0] gf_mult_128;
        input [127:0] X_raw; // GCM Format
        input [127:0] Y_raw; // GCM Format
        
        reg [127:0] X, Y;
        reg [63:0]  xh, xl, yh, yl;
        reg [126:0] M1, M2, M3;     // Partial Products
        reg [254:0] P_raw;          // 255-bit Raw Product
        reg [127:0] rem;            // Reduction Result
        integer i;
        
        begin
            // 1. 비트 순서 뒤집기 (GCM -> Normal Polynomial)
            X = bit_reverse(X_raw);
            Y = bit_reverse(Y_raw);

            // 2. 상위/하위 64비트 분할
            xh = X[127:64]; xl = X[63:0];
            yh = Y[127:64]; yl = Y[63:0];

            // 3. Karatsuba Multiplication (64-bit 곱셈 3번)
            // M1 = High * High
            M1 = pmul_64(xh, yh); 
            // M2 = Low * Low
            M2 = pmul_64(xl, yl); 
            // M3 = (High + Low) * (High + Low)
            M3 = pmul_64(xh ^ xl, yh ^ yl); 

            // 4. 결과 합치기 (Reconstruction)
            // P = (M1 << 128) + ((M3 - M1 - M2) << 64) + M2
            // GF(2)에서 뺄셈(-)은 XOR(^)과 같음
            P_raw = {M1, 128'd0} ^ {64'd0, (M3 ^ M1 ^ M2), 64'd0} ^ {128'd0, M2};

            // 5. Modular Reduction (GCM Polynomial: x^128 + x^7 + x^2 + x + 1)
            // 255비트 결과를 128비트로 줄임
            for (i = 254; i >= 128; i = i - 1) begin
                if (P_raw[i]) begin
                    // P(x)를 해당 위치에 맞춰 XOR (Polynomial: 1_0000...0000_10000111)
                    // 상위 비트는 제거하고, 하위 비트(x^7+x^2+x+1 = 0x87)만 XOR
                    P_raw[i] = 0; // Clear current bit
                    P_raw[i-121] = P_raw[i-121] ^ 1'b1; // x^7
                    P_raw[i-126] = P_raw[i-126] ^ 1'b1; // x^2
                    P_raw[i-127] = P_raw[i-127] ^ 1'b1; // x^1
                    P_raw[i-128] = P_raw[i-128] ^ 1'b1; // 1
                end
            end
            
            rem = P_raw[127:0];

            // 6. 결과 다시 뒤집기 (Normal Polynomial -> GCM)
            gf_mult_128 = bit_reverse(rem);
        end
    endfunction

    // ========================================================================
    // Main Logic (FSM 및 Datapath)
    // ========================================================================
    reg [127:0] feedback_xor;
    reg [127:0] next_tag_val;

    always @* begin
        if (step_cnt == 11'd0) begin
            feedback_xor = data_in; 
        end else begin
            feedback_xor = current_tag ^ data_in;
        end
        
        // 여기서 64비트로 쪼개진 함수 호출
        next_tag_val = gf_mult_128(feedback_xor, h_key_in);
    end

    assign final_tag_out = current_tag ^ tag_mask_in;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            current_tag <= 128'd0;
            step_cnt    <= 11'd0;
            tag_valid   <= 1'b0;
            done        <= 1'b0;
        end else begin
            done      <= 1'b0;
            tag_valid <= 1'b0;

            if (valid_in) begin
                current_tag <= next_tag_val;
                done        <= 1'b1;

                // 카운터: 1024(CT) + 1(AAD) = 1025번째에 태그 출력
                if (step_cnt == 11'd1025) begin
                    tag_valid <= 1'b1; 
                    step_cnt  <= 11'd0;
                end else begin
                    step_cnt <= step_cnt + 1;
                end
            end
        end
    end

endmodule