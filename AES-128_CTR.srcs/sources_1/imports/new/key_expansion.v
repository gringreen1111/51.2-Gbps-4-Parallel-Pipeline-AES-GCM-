`timescale 1ns / 1ps

module key_expansion (
    input clk,
    input rst,
    input start,                  // 키 확장 시작 신호
    input [127:0] master_key_in,
    output reg  expand_done,              // 계산 완료 신호
    output reg [127:0] round_key_0,
    output reg [127:0] round_key_1,
    output reg [127:0] round_key_2,
    output reg [127:0] round_key_3,
    output reg [127:0] round_key_4,
    output reg [127:0] round_key_5,
    output reg [127:0] round_key_6,
    output reg [127:0] round_key_7,
    output reg [127:0] round_key_8,
    output reg [127:0] round_key_9,
    output reg [127:0] round_key_10
);

    // --- 상태 정의 ---
    localparam S_IDLE         = 3'b000; // 시작 대기
    localparam S_LOAD_KEY     = 3'b001; // 마스터 키 로드
    localparam S_PREP_SUBWORD = 3'b010; // S-Box 입력 준비 (i % 4 == 0)
    localparam S_CALC_SUBWORD = 3'b011; // S-Box 출력 대기 (1클럭)
    localparam S_CALC_W_SPEC  = 3'b100; // 특별 계산 (i % 4 == 0)
    localparam S_CALC_W_NORM  = 3'b101; // 일반 계산 (i % 4 != 0)
    localparam S_FINISH       = 3'b110; // 결과 복사 및 완료

    reg [2:0] state = S_IDLE;

    // 11개의 128비트 키(총 44개의 32비트 워드)를 저장할 레지스터
    reg [31:0] w [0:43];
    reg [5:0] i; // 워드 인덱스 카운터 (4 ~ 44)

    // --- 라운드 상수 (Rcon) ROM ---
    reg [7:0] rcon_lookup;

    always @(*) begin
        case (i / 4) 
            1:  rcon_lookup = 8'h01;
            2:  rcon_lookup = 8'h02;
            3:  rcon_lookup = 8'h04;
            4:  rcon_lookup = 8'h08;
            5:  rcon_lookup = 8'h10;
            6:  rcon_lookup = 8'h20;
            7:  rcon_lookup = 8'h40;
            8:  rcon_lookup = 8'h80;
            9:  rcon_lookup = 8'h1B;
            10: rcon_lookup = 8'h36;
            default: rcon_lookup = 8'h00;
        endcase
    end

    // --- SubWord 연산을 위한 S-Box 4개 인스턴스화 ---
    wire [31:0] subword_out;
    reg  [31:0] subword_in_reg; // S-Box 입력을 잡아줄 레지스터

    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : SBOX_KEY_INST
            aes_sbox u_sbox_key (
                .in_byte(subword_in_reg[ (3-k)*8 + 7 : (3-k)*8 ]),
                .out_byte(subword_out[ (3-k)*8 + 7 : (3-k)*8 ])
            );
        end
    endgenerate

    // --- 중간 계산값 저장 레지스터 ---
    reg [31:0] temp_subword_result;

    // --- 키 확장 FSM ---
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            expand_done <= 0;
            i <= 0;
            
            round_key_0  <= 128'b0;
            round_key_1  <= 128'b0;
            round_key_2  <= 128'b0;
            round_key_3  <= 128'b0;
            round_key_4  <= 128'b0;
            round_key_5  <= 128'b0;
            round_key_6  <= 128'b0;
            round_key_7  <= 128'b0;
            round_key_8  <= 128'b0;
            round_key_9  <= 128'b0;
            round_key_10 <= 128'b0;
            
        end else begin
            // done 신호는 1클럭만 유지
            expand_done <= 0;
            
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_LOAD_KEY;
                    end
                end

                S_LOAD_KEY: begin
                    // 마스터 키를 처음 4개 워드에 로드
                    w[0] <= master_key_in[127:96];
                    w[1] <= master_key_in[95:64];
                    w[2] <= master_key_in[63:32];
                    w[3] <= master_key_in[31:0];
                             
                    i <= 4; // 다음 계산할 워드 인덱스
                    state <= S_PREP_SUBWORD; // i=4는 특별 계산이므로
                end

                S_PREP_SUBWORD: begin
                    // i % 4 == 0 일 때, S-Box 입력을 준비 (RotWord)
                    subword_in_reg <= {w[i-1][23:0], w[i-1][31:24]};
                    state <= S_CALC_SUBWORD;
                end

                S_CALC_SUBWORD: begin
                    // BRAM S-Box의 1클럭 지연 대기
                    // S-Box 출력이 subword_out에 나타남
                    state <= S_CALC_W_SPEC;
                end

                S_CALC_W_SPEC: begin
                    // t = SubWord(RotWord(w[i-1])) ^ Rcon[i/4]
                    w[i] <= w[i-4] ^ subword_out ^ {rcon_lookup, 24'b0};
                    i <= i + 1;
                    state <= S_CALC_W_NORM; // 다음은 일반 계산
                end

                S_CALC_W_NORM: begin
                    // w[i] = w[i-1] ^ w[i-4]
                    w[i] <= w[i-1] ^ w[i-4];
                    i <= i + 1;
                    
                    if (i == 43) begin // 마지막 워드 계산 완료
                        state <= S_FINISH;
                    end else if ((i + 1) % 4 == 0) begin // 다음이 특별 계산 차례
                        state <= S_PREP_SUBWORD;
                    end
                    // 그 외에는 S_CALC_W_NORM 상태 유지
                end
                
                S_FINISH: begin         

                    round_key_0  <= {w[0],  w[1],  w[2],  w[3]};
                    round_key_1  <= {w[4],  w[5],  w[6],  w[7]};
                    round_key_2  <= {w[8],  w[9],  w[10], w[11]};
                    round_key_3  <= {w[12], w[13], w[14], w[15]};
                    round_key_4  <= {w[16], w[17], w[18], w[19]};
                    round_key_5  <= {w[20], w[21], w[22], w[23]};
                    round_key_6  <= {w[24], w[25], w[26], w[27]};
                    round_key_7  <= {w[28], w[29], w[30], w[31]};
                    round_key_8  <= {w[32], w[33], w[34], w[35]};
                    round_key_9  <= {w[36], w[37], w[38], w[39]};
                    round_key_10 <= {w[40], w[41], w[42], w[43]};
                    
                    expand_done <= 1;
                    state <= S_IDLE;
                end
                
                default:
                    state <= S_IDLE;
            endcase
        end
    end

endmodule