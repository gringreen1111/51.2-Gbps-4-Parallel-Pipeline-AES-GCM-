`timescale 1ns / 1ps

module aes_core_pipeline (
    input wire clk,
    // rst는 파이프라인 데이터 클리어 용도 (필수 아님, valid 신호로 제어)
    input wire rst, 
    // 입력 데이터
    input wire [127:0] plaintext_in,
    input wire valid_in, // 입력 데이터가 유효함을 알림
    
    // 미리 확장된 키 입력 (11개)
    input wire [127:0] round_key_0,
    input wire [127:0] round_key_1,
    input wire [127:0] round_key_2,
    input wire [127:0] round_key_3,
    input wire [127:0] round_key_4,
    input wire [127:0] round_key_5,
    input wire [127:0] round_key_6,
    input wire [127:0] round_key_7,
    input wire [127:0] round_key_8,
    input wire [127:0] round_key_9,
    input wire [127:0] round_key_10,
    
    // 출력 데이터
    output reg [127:0] ciphertext_out,
    output reg valid_out // 출력 데이터가 유효함을 알림
);

    // --- 파이프라인 스테이지 레지스터 정의 ---
    // r0_reg: 초기 AddRoundKey 결과
    // r1_reg ~ r9_reg: 각 라운드(1~9)의 결과 저장
    // r10_reg: 최종 라운드 결과 (ciphertext_out에 바로 연결 가능하지만 타이밍 위해 둠)
    
    reg [127:0] state_r0;
    reg [127:0] state_r1, state_r2, state_r3, state_r4, state_r5;
    reg [127:0] state_r6, state_r7, state_r8, state_r9;
    
    // 각 라운드 모듈의 출력 와이어
    wire [127:0] round_out_w1, round_out_w2, round_out_w3, round_out_w4, round_out_w5;
    wire [127:0] round_out_w6, round_out_w7, round_out_w8, round_out_w9, round_out_w10;

    // Valid 신호 파이프라인 (데이터와 함께 흐름)
    reg [9:0] valid_pipe; 

    // ============================================================
    // Stage 0: Initial AddRoundKey (Combinational + Register)
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            state_r0 <= 128'd0;
        end else begin
            // Plaintext ^ Key0
            state_r0 <= plaintext_in ^ round_key_0;
        end
    end

    // ============================================================
    // Stages 1 ~ 9: Standard Rounds
    // ============================================================
    // 각 라운드 인스턴스화 (파이프라인이므로 병렬로 9개 배치)
    
    aes_round U_Round_1 (.state_in(state_r0), .round_key_in(round_key_1), .is_final_round(1'b0), .state_out(round_out_w1));
    aes_round U_Round_2 (.state_in(state_r1), .round_key_in(round_key_2), .is_final_round(1'b0), .state_out(round_out_w2));
    aes_round U_Round_3 (.state_in(state_r2), .round_key_in(round_key_3), .is_final_round(1'b0), .state_out(round_out_w3));
    aes_round U_Round_4 (.state_in(state_r3), .round_key_in(round_key_4), .is_final_round(1'b0), .state_out(round_out_w4));
    aes_round U_Round_5 (.state_in(state_r4), .round_key_in(round_key_5), .is_final_round(1'b0), .state_out(round_out_w5));
    aes_round U_Round_6 (.state_in(state_r5), .round_key_in(round_key_6), .is_final_round(1'b0), .state_out(round_out_w6));
    aes_round U_Round_7 (.state_in(state_r6), .round_key_in(round_key_7), .is_final_round(1'b0), .state_out(round_out_w7));
    aes_round U_Round_8 (.state_in(state_r7), .round_key_in(round_key_8), .is_final_round(1'b0), .state_out(round_out_w8));
    aes_round U_Round_9 (.state_in(state_r8), .round_key_in(round_key_9), .is_final_round(1'b0), .state_out(round_out_w9));

    // 파이프라인 레지스터 업데이트 (데이터 이동)
    always @(posedge clk) begin
        state_r1 <= round_out_w1;
        state_r2 <= round_out_w2;
        state_r3 <= round_out_w3;
        state_r4 <= round_out_w4;
        state_r5 <= round_out_w5;
        state_r6 <= round_out_w6;
        state_r7 <= round_out_w7;
        state_r8 <= round_out_w8;
        state_r9 <= round_out_w9;
    end

    // ============================================================
    // Stage 10: Final Round
    // ============================================================
    aes_round U_Round_10 (
        .state_in(state_r9), 
        .round_key_in(round_key_10), 
        .is_final_round(1'b1),
        .state_out(round_out_w10)
    );

    // 최종 출력 레지스터
    always @(posedge clk) begin
        if (rst) begin
            ciphertext_out <= 128'd0;
        end else begin
            ciphertext_out <= round_out_w10;
        end
    end

    // ============================================================
    // Valid Signal Pipeline (Shift Register)
    // 데이터가 10~11클럭 후에 나오므로 유효 신호도 같이 지연시킴
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            valid_pipe <= 10'd0;
            valid_out <= 1'b0;
        end else begin
            // Shift Left: valid_in이 들어오면 한 칸씩 이동
            // 파이프라인 깊이에 맞춰서 비트 수 조정 필요 (여기선 11단계로 가정)
            valid_pipe <= {valid_pipe[8:0], valid_in};
            valid_out  <= valid_pipe[9];
        end
    end

endmodule