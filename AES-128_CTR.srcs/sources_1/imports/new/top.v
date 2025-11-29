`timescale 1ns / 1ps

module top (
    input wire CLK100MHZ,   // FPGA의 100MHz 시스템 클럭
    input wire rst,         // FPGA의 리셋 버튼 (Active High)
    input wire uart_rxd,    // PC -> FPGA (UART RX 핀)
    output wire uart_txd    // FPGA -> PC (UART TX 핀)
);
    wire clk;
    assign clk = CLK100MHZ;
    
    // --- UART 모듈 연결 신호 ---
    wire        Rxclk_en;
    wire        Txclk_en;
    wire        rx_rdy;
    wire [7:0]  rx_data;
    wire        tx_busy;

    reg         rx_rdy_clr = 1'b0;
    reg         tx_wr_en = 1'b0;
    reg [7:0]   tx_din_data = 8'h00; 

    // --- AES Core 연결 신호 ---
    reg [127:0] aes_key_in_reg = 128'd0;
    reg key_check_reg = 1'b0;
    wire         key_done_wire;

    // --- 3개의 128비트(16바이트) 버퍼 ---
    reg [7:0]   pt_buffer [0:15];  // 1. 평문(Plaintext) 수신용
    reg [7:0]   key_buffer [0:15]; // 2. 키(Key) 수신용
    reg [7:0]   ct_buffer [0:15];  // 3. 암호문(Ciphertext) 전송용
    
    // ★ [NEW] 태그 전송용 버퍼 및 CT 저장용 레지스터 (병렬 Top에서 가져옴)
    reg [7:0]   tag_buffer [0:15]; 
    
    // --- CTR 모드용 Nonce+Counter 레지스터 ---
    reg [127:0] nonce_counter_reg = 128'd0;
    
    integer i;
    
    // --- FSM 상태 정의 (CTR 모드 + Tag 전송 추가) ---
    parameter S_RECV_KEY       = 4'd0; // 1. 키(16B) 수신
    parameter S_LOAD_KEY       = 4'd1; // 2. AES 코어에 키 로드
    parameter S_RECV_AAD       = 4'd2;
    parameter S_RECV_NONCE     = 4'd3; // 3. Nonce(16B) 수신
    parameter S_KEY_IV_CHECK   = 4'd4; // 4. 키 확장 완료 확인
    parameter S_RECV_PT        = 4'd5; // 5. 평문(16B) 수신
    parameter S_WAIT_PT        = 4'd6;
    parameter S_XOR_AND_LOAD   = 4'd7; // 8. 평문과 XOR 및 ct_buffer 로드 (GHASH 트리거 지점)
    parameter S_SEND_CT        = 4'd8; // 9. 암호문(16B) 전송
    parameter S_WAIT_FIFO      = 4'd9;
    
    parameter S_WAIT_TAG       = 4'd10; // 태그 계산 완료 대기
    parameter S_SEND_TAG       = 4'd11;// 태그 UART 전송

    reg [3:0]   state = S_RECV_KEY;
    reg [3:0] rx_byte_counter = 4'b0;
    reg [3:0] tx_byte_counter = 4'b0;
    reg [10:0] process_blk_cnt = 11'd0;
    
    //==================================================
    // 1. Baud Rate Generator
    //==================================================
    baud_rate_gen u_baud (
        .clk(clk), .rst(rst),
        .Rxclk_en(Rxclk_en), .Txclk_en(Txclk_en)
    );

    //==================================================
    // 2. Receiver
    //==================================================
    receiver u_rx (
        .rx(uart_rxd), .rdy(rx_rdy), .rdy_clr(rx_rdy_clr),
        .clk(clk), .clken(Rxclk_en), .rst(rst), .data(rx_data)
    );

    //==================================================
    // 3. Transmitter
    //==================================================
    transmitter u_tx (
        .din(tx_din_data), .wr_en(tx_wr_en), .clk(clk),
        .clken(Txclk_en), .rst(rst), .tx(uart_txd), .tx_busy(tx_busy)
    );
    
    // Ghash Core 연결 신호
    reg [127:0] ghash_data_in;
    reg         ghash_valid_in;
    wire [127:0] ghash_final_tag;
    wire        ghash_done;
    wire        ghash_tag_valid;
    
    // Ghash Control FSM 상태
    localparam G_IDLE   = 3'd0;
    localparam G_AAD    = 3'd1;
    localparam G_CT     = 3'd2;
    localparam G_LEN    = 3'd3;
    localparam G_DONE   = 3'd4;
    
    reg [2:0] g_state = G_IDLE;
    
    // AAD 및 Length 상수 (128비트)
    reg [127:0] aad_reg  = 128'hAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;
    wire [127:0] LEN_VAL = 128'h00000000000000800000000000020000;
    
    // GHASH Core 인스턴스
    ghash_core u_ghash_core (
        .clk(clk),
        .rst(rst),
        .h_key_in(aes_key_in_reg),    // AES 키를 H키로 사용
        .tag_mask_in(128'd0),         // 마스킹 없음
        .data_in(ghash_data_in),
        .valid_in(ghash_valid_in),
        .final_tag_out(ghash_final_tag),
        .done(ghash_done), // 연산 중
        .tag_valid(ghash_tag_valid)
    );

    // [Ghash Driver FSM]
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            g_state <= G_IDLE;
            ghash_valid_in <= 1'b0;
            ghash_data_in <= 128'd0;
            
            // 태그 버퍼 초기화
            for (i=0; i<16; i=i+1) tag_buffer[i] <= 8'h00;
            
        end else begin
            case(g_state)
                G_IDLE: begin
                    ghash_valid_in <= 1'b0;
                    // 메인 FSM이 암호문을 만들었을 때 트리거 (파이프라인 Top의 XOR 시점)
                    if (state == S_XOR_AND_LOAD) begin
                    // 처음 시작일 때
                        if (process_blk_cnt == 11'd0) begin
                            g_state <= G_AAD;
                        end
                        // [CASE 2] 중간 or 마지막 블록: 바로 CT 넣기
                        else begin
                            g_state <= G_CT;
                        end
                    end
                end
                
                G_AAD: begin
                    // 1. AAD 주입
                    ghash_data_in <= aad_reg;
                    ghash_valid_in <= 1'b1;
                    g_state <= G_CT; 
                end
                
                G_CT: begin
                    ghash_data_in <= { ct_buffer[0], ct_buffer[1], ct_buffer[2], ct_buffer[3], ct_buffer[4], ct_buffer[5],
                                        ct_buffer[6], ct_buffer[7], ct_buffer[8], ct_buffer[9], ct_buffer[10], ct_buffer[11],
                                        ct_buffer[12], ct_buffer[13], ct_buffer[14], ct_buffer[15]}; // 계산된 CT
                    ghash_valid_in <= 1'b1;
                    
                    // 마지막 블록(1023번)이라면 CT 넣은 후 Length 단계로
                    if (process_blk_cnt == 11'd1023) begin
                        g_state <= G_LEN;
                    end else begin
                        // 중간 블록이면 CT만 넣고 끝
                        g_state <= G_IDLE; 
                    end
                end
                
                G_LEN: begin
                    ghash_valid_in <= 1'b0;
                    
                    if (ghash_done) begin
                        // 3. Length 주입
                        ghash_data_in <= LEN_VAL;
                        ghash_valid_in <= 1'b1;
                        g_state <= G_DONE;
                    end
                end
                
                G_DONE: begin
                    ghash_valid_in <= 1'b0;
                    
                    // 최종 태그가 유효하면 버퍼에 저장
                    if (ghash_tag_valid) begin
                        tag_buffer[0]  <= ghash_final_tag[127:120];
                        tag_buffer[1]  <= ghash_final_tag[119:112];
                        tag_buffer[2]  <= ghash_final_tag[111:104];
                        tag_buffer[3]  <= ghash_final_tag[103:96];
                        tag_buffer[4]  <= ghash_final_tag[95:88];
                        tag_buffer[5]  <= ghash_final_tag[87:80];
                        tag_buffer[6]  <= ghash_final_tag[79:72];
                        tag_buffer[7]  <= ghash_final_tag[71:64];
                        tag_buffer[8]  <= ghash_final_tag[63:56];
                        tag_buffer[9]  <= ghash_final_tag[55:48];
                        tag_buffer[10] <= ghash_final_tag[47:40];
                        tag_buffer[11] <= ghash_final_tag[39:32];
                        tag_buffer[12] <= ghash_final_tag[31:24];
                        tag_buffer[13] <= ghash_final_tag[23:16];
                        tag_buffer[14] <= ghash_final_tag[15:8];
                        tag_buffer[15] <= ghash_final_tag[7:0];
                        
                        g_state <= G_IDLE; // 완료 후 대기
                    end
                end
            endcase
        end
    end
                                
    // ========================================================
    // Keystream Producer FSM & Pipeline AES Logic
    // ========================================================
    localparam KS_IDLE       = 4'd0;
    localparam KS_CHECK_FIFO = 4'd2;
    localparam KS_RUN        = 4'd3;
    
    reg [3:0] ks_state = KS_IDLE;
    reg [10:0] ks_gen_counter = 11'd0;
    
    wire         keystream_fifo_full;
    wire [127:0] keystream_fifo_rd_data;
    reg          keystream_fifo_rd_en;
    wire         keystream_fifo_empty;
    reg          fifo_rst = 1'b0;
    wire [127:0] wk0, wk1, wk2, wk3, wk4, wk5, wk6, wk7, wk8, wk9, wk10;
    
    reg  [127:0] pipe_in_data [0:3];    // 4개의 입력 데이터 (Counter)
    wire [127:0] pipe_out_data [0:3];   // 4개의 출력 데이터 (Ciphertext)
    wire         pipe_valid_out [0:3];  // 4개의 완료 신호 (Lockstep이므로 [0]만 써도 됨)
    reg          pipe_global_valid_in;  // 4개 공통 시작 신호
    reg  [127:0] current_pipeline;
    
    keystream_fifo u_keystream_fifo (
      .clk(clk),
      .rst(fifo_rst),
      .din({pipe_out_data[0], pipe_out_data[1], pipe_out_data[2], pipe_out_data[3]}),  // 입력 순서 유지
      .wr_en(pipe_valid_out[0]),     
      .full(keystream_fifo_full),    
      .dout(keystream_fifo_rd_data), 
      .rd_en(keystream_fifo_rd_en),  
      .empty(keystream_fifo_empty)   
    );
    
    // --- 1. 단일 Key Expansion 인스턴스 ---
    key_expansion U_Global_Key_Expansion (
        .clk(clk),
        .rst(rst),
        .start( state == S_LOAD_KEY),
        .master_key_in(aes_key_in_reg),
        .expand_done(key_done_wire),
        .round_key_0(wk0), .round_key_1(wk1), .round_key_2(wk2),
        .round_key_3(wk3), .round_key_4(wk4), .round_key_5(wk5),
        .round_key_6(wk6), .round_key_7(wk7), .round_key_8(wk8),
        .round_key_9(wk9), .round_key_10(wk10)
    );
    
    // AES 코어 4개 생성 (generate loop)
    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : AES_CORE_PIPELINE
            aes_core_pipeline u_aes_parallel (
                .clk(clk),
                .rst(rst),
                .valid_in(pipe_global_valid_in),
                .round_key_0(wk0), .round_key_1(wk1), .round_key_2(wk2),
                .round_key_3(wk3), .round_key_4(wk4), .round_key_5(wk5),
                .round_key_6(wk6), .round_key_7(wk7), .round_key_8(wk8),
                .round_key_9(wk9), .round_key_10(wk10),
                
                .plaintext_in(pipe_in_data[k]),
                .ciphertext_out(pipe_out_data[k]),
                .valid_out(pipe_valid_out[k])
            );
        end
    endgenerate
    
    // Keystream Generation Control FSM (수정 없음)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ks_state <= KS_IDLE;
            ks_gen_counter <= 11'd0;
            fifo_rst <= 1'b0;
            pipe_global_valid_in <= 1'b0;
            current_pipeline <= 128'd0;
            pipe_in_data[0] <= 128'd0;
            pipe_in_data[1] <= 128'd0;
            pipe_in_data[2] <= 128'd0;
            pipe_in_data[3] <= 128'd0;
        end else begin
            // 기본값
            pipe_global_valid_in <= 1'b0;
            fifo_rst <= 1'b0;
    
            case (ks_state)
                KS_IDLE: begin
                    ks_gen_counter <= 11'd0;
                    if (key_check_reg && state == S_KEY_IV_CHECK) begin 
                        fifo_rst <= 1'b1; 
                        ks_state <= KS_CHECK_FIFO;
                        current_pipeline <= nonce_counter_reg;
                    end
                end
                
                KS_CHECK_FIFO: begin
                   if (!keystream_fifo_full) begin
                       ks_state <= KS_RUN;
                   end
                end
                
                KS_RUN: begin
                    if (ks_gen_counter >= 11'd1024) begin
                        ks_state <= KS_IDLE;
                    end else if(!keystream_fifo_full) begin
                        pipe_global_valid_in <= 1'b1;
                        
                        pipe_in_data[0] <= current_pipeline + 0;
                        pipe_in_data[1] <= current_pipeline + 1;
                        pipe_in_data[2] <= current_pipeline + 2;
                        pipe_in_data[3] <= current_pipeline + 3;
                        
                        current_pipeline <= current_pipeline + 4;
                        ks_gen_counter <= ks_gen_counter + 4;
                    end
                end
                
                default: ks_state <= KS_IDLE;
            endcase
        end
    end

    //==================================================
    // 5-1. Top FSM (제어 로직 - Control Path)
    //==================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_RECV_KEY;
            rx_byte_counter <= 4'd0;
            tx_byte_counter <= 4'd0;
            rx_rdy_clr <= 1'b0;
            tx_wr_en <= 1'b0;
            keystream_fifo_rd_en <= 1'b0;
            key_check_reg <= 1'b0;
            process_blk_cnt <= 11'd0;
        end else begin
            
            tx_wr_en <= 1'b0;
            rx_rdy_clr <= 1'b0;
            keystream_fifo_rd_en <= 1'b0;
            
            if(key_done_wire) begin
                key_check_reg <= 1'b1;
            end
            
            case (state)
                // --- 1. 키(16B) 수신 ---
                S_RECV_KEY: begin
                    if (rx_rdy && !rx_rdy_clr) begin
                        rx_rdy_clr <= 1'b1;
                        if (rx_byte_counter == 4'd15) begin
                            state <= S_LOAD_KEY; 
                            rx_byte_counter <= 4'd0;
                        end else begin
                            rx_byte_counter <= rx_byte_counter + 1;
                        end
                    end 
                    else if (!rx_rdy) begin
                        rx_rdy_clr <= 1'b0;
                    end
                end

                // --- 2. AES 코어에 키 로드 ---
                S_LOAD_KEY: begin
                    state <= S_RECV_AAD;
                end
                
                S_RECV_AAD: begin
                    if (rx_rdy && !rx_rdy_clr) begin
                        rx_rdy_clr <= 1'b1;
                        if (rx_byte_counter == 4'd15) begin
                            state <= S_RECV_NONCE; 
                            rx_byte_counter <= 4'd0;
                        end else begin
                            rx_byte_counter <= rx_byte_counter + 1;
                        end
                    end 
                    else if (!rx_rdy) begin
                        rx_rdy_clr <= 1'b0;
                    end
                end
                
                // --- 3. Nonce(16B) 수신 ---
                S_RECV_NONCE: begin
                    if (rx_rdy && !rx_rdy_clr) begin
                        rx_rdy_clr <= 1'b1;
                        if (rx_byte_counter == 4'd15) begin
                            state <= S_KEY_IV_CHECK;
                            rx_byte_counter <= 4'd0;
                            process_blk_cnt <= 11'd0;
                        end else begin
                            rx_byte_counter <= rx_byte_counter + 1;
                        end
                    end 
                    else if (!rx_rdy) begin
                        rx_rdy_clr <= 1'b0;
                    end
                end
                
                // --- 4. KEY CHECK ---
                S_KEY_IV_CHECK: begin
                    if (key_check_reg) begin
                        state <= S_RECV_PT;
                    end
                end
                
                // --- 5. 평문(16B) 수신 ---
                S_RECV_PT: begin
                    if (rx_rdy && !rx_rdy_clr) begin
                        rx_rdy_clr <= 1'b1;
                        if (rx_byte_counter == 4'd15) begin
                            state <= S_WAIT_PT;
                            rx_byte_counter <= 4'd0;
                        end else begin
                            rx_byte_counter <= rx_byte_counter + 1;
                        end
                    end 
                    else if (!rx_rdy) begin
                        rx_rdy_clr <= 1'b0;
                    end
                end
                
                S_WAIT_PT: begin
                    if (!keystream_fifo_empty) begin 
                        keystream_fifo_rd_en <= 1'b1;
                        state <= S_WAIT_FIFO;
                    end
                end

                S_WAIT_FIFO: begin
                    // fifo에서 데이터 출력 대기
                    state <= S_XOR_AND_LOAD;
                end
                
                // --- 8. 평문과 XOR 및 ct_buffer 로드 ---
                S_XOR_AND_LOAD: begin
                    // 여기서 GHASH FSM도 트리거 됨 (g_state <= G_AAD)
                    state <= S_SEND_CT;
                    tx_byte_counter <= 4'd0;
                end

                // --- 9. 암호문(16B) 전송 ---
                S_SEND_CT: begin
                    if (!tx_busy && !tx_wr_en) begin 
                        tx_wr_en <= 1'b1;
                        if (tx_byte_counter == 4'd15) begin
                            if (process_blk_cnt == 11'd1023) begin
                                // 마지막 블록이면 태그 대기 상태로
                                state <= S_WAIT_TAG;
                            end else begin
                                // 아직 남았으면 카운트 증가 후 평문 수신으로 복귀
                                process_blk_cnt <= process_blk_cnt + 1;
                                state <= S_RECV_PT;
                            end
                        end else begin
                            tx_byte_counter <= tx_byte_counter + 1;
                        end
                    end
                end

                S_WAIT_TAG: begin
                    // GHASH 계산이 완료되어 G_IDLE 상태로 돌아오면 태그 준비 완료
                    // (G_DONE에서 태그 버퍼에 쓰고 G_IDLE로 옴)
                    if (g_state == G_IDLE) begin
                        state <= S_SEND_TAG;
                        tx_byte_counter <= 4'd0;
                    end
                    // 아니면 대기 (GHASH가 UART보다 빠르므로 보통 바로 통과함)
                end
                
                // --- ★ [NEW] 11. 태그(16B) 전송 ---
                S_SEND_TAG: begin
                    if (!tx_busy && !tx_wr_en) begin
                        tx_wr_en <= 1'b1;
                        if (tx_byte_counter == 4'd15) begin
                            // 태그까지 다 보냈으므로 다음 블록 처리 여부 결정
                            process_blk_cnt <= 11'd0;
                            state <= S_RECV_AAD; // 전체 종료
                        end else begin
                            tx_byte_counter <= tx_byte_counter + 1;
                        end
                    end
                end

                default: begin
                    state <= S_RECV_KEY;
                end
            endcase
        end
    end
    
    //==================================================
    // 5-2. Top Datapath (데이터 로직)
    //==================================================
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            for (i = 0; i < 16; i = i + 1) begin
                key_buffer[i] <= 8'h00;
            end
            for (i = 0; i < 16; i = i + 1) begin
                pt_buffer[i] <= 8'h00;
                ct_buffer[i] <= 8'h00;
            end
            aes_key_in_reg <= 128'd0;
            nonce_counter_reg <= 128'd0;
            tx_din_data <= 8'h00;
            aad_reg <= 128'd0;
        end
        else begin
            // --- 1. 평문 버퍼 쓰기 ---
            if (state == S_RECV_PT && rx_rdy && !rx_rdy_clr) begin
                pt_buffer[rx_byte_counter] <= rx_data;
            end
    
            // --- 2. 키 버퍼 쓰기 ---
            if (state == S_RECV_KEY && rx_rdy && !rx_rdy_clr) begin
                key_buffer[rx_byte_counter] <= rx_data;
            end
            
            if (state == S_RECV_AAD && rx_rdy && !rx_rdy_clr) begin
                case (rx_byte_counter)
                    4'd0:  aad_reg[127:120] <= rx_data;
                    4'd1:  aad_reg[119:112] <= rx_data;
                    4'd2:  aad_reg[111:104] <= rx_data;
                    4'd3:  aad_reg[103:96]  <= rx_data;
                    4'd4:  aad_reg[95:88]   <= rx_data;
                    4'd5:  aad_reg[87:80]   <= rx_data;
                    4'd6:  aad_reg[79:72]   <= rx_data;
                    4'd7:  aad_reg[71:64]   <= rx_data;
                    4'd8:  aad_reg[63:56]   <= rx_data;
                    4'd9:  aad_reg[55:48]   <= rx_data;
                    4'd10: aad_reg[47:40]   <= rx_data;
                    4'd11: aad_reg[39:32]   <= rx_data;
                    4'd12: aad_reg[31:24]   <= rx_data;  
                    4'd13: aad_reg[23:16]   <= rx_data;  
                    4'd14: aad_reg[15:8]    <= rx_data;  
                    4'd15: aad_reg[7:0]     <= rx_data;  
                    default: aad_reg[127:0] <= 128'd0;
                endcase
            end
            
            // --- 2. AES 키 레지스터 쓰기 ---
            if (state == S_LOAD_KEY) begin
                 aes_key_in_reg <= {key_buffer[0], key_buffer[1], key_buffer[2], key_buffer[3], 
                                   key_buffer[4], key_buffer[5], key_buffer[6], key_buffer[7], 
                                   key_buffer[8], key_buffer[9], key_buffer[10], key_buffer[11], 
                                   key_buffer[12], key_buffer[13], key_buffer[14], key_buffer[15]};
            end
            
            // --- 3. Nonce 레지스터 쓰기 ---
            if (state == S_RECV_NONCE && rx_rdy && !rx_rdy_clr) begin
                case (rx_byte_counter)
                    4'd0:  nonce_counter_reg[127:120] <= rx_data;
                    4'd1:  nonce_counter_reg[119:112] <= rx_data;
                    4'd2:  nonce_counter_reg[111:104] <= rx_data;
                    4'd3:  nonce_counter_reg[103:96]  <= rx_data;
                    4'd4:  nonce_counter_reg[95:88]   <= rx_data;
                    4'd5:  nonce_counter_reg[87:80]   <= rx_data;
                    4'd6:  nonce_counter_reg[79:72]   <= rx_data;
                    4'd7:  nonce_counter_reg[71:64]   <= rx_data;
                    4'd8:  nonce_counter_reg[63:56]   <= rx_data;
                    4'd9:  nonce_counter_reg[55:48]   <= rx_data;
                    4'd10: nonce_counter_reg[47:40]   <= rx_data;
                    4'd11: nonce_counter_reg[39:32]   <= rx_data;
                    4'd12: nonce_counter_reg[31:24]   <= rx_data;  
                    4'd13: nonce_counter_reg[23:16]   <= rx_data;  
                    4'd14: nonce_counter_reg[15:8]    <= rx_data;  
                    4'd15: nonce_counter_reg[7:0]     <= rx_data;  
                    default: nonce_counter_reg[127:0] <= 128'd0;
                endcase
            end

            // --- 8. XOR 및 암호문 버퍼 쓰기 + [NEW] CT 저장 ---
            if (state == S_XOR_AND_LOAD) begin
                // Keystream과 평문을 XOR
                ct_buffer[0]  <= pt_buffer[0]  ^ keystream_fifo_rd_data[127:120];
                ct_buffer[1]  <= pt_buffer[1]  ^ keystream_fifo_rd_data[119:112];
                ct_buffer[2]  <= pt_buffer[2]  ^ keystream_fifo_rd_data[111:104];
                ct_buffer[3]  <= pt_buffer[3]  ^ keystream_fifo_rd_data[103:96];
                ct_buffer[4]  <= pt_buffer[4]  ^ keystream_fifo_rd_data[95:88];
                ct_buffer[5]  <= pt_buffer[5]  ^ keystream_fifo_rd_data[87:80];
                ct_buffer[6]  <= pt_buffer[6]  ^ keystream_fifo_rd_data[79:72];
                ct_buffer[7]  <= pt_buffer[7]  ^ keystream_fifo_rd_data[71:64];
                ct_buffer[8]  <= pt_buffer[8]  ^ keystream_fifo_rd_data[63:56];
                ct_buffer[9]  <= pt_buffer[9]  ^ keystream_fifo_rd_data[55:48];
                ct_buffer[10] <= pt_buffer[10] ^ keystream_fifo_rd_data[47:40];
                ct_buffer[11] <= pt_buffer[11] ^ keystream_fifo_rd_data[39:32];
                ct_buffer[12] <= pt_buffer[12] ^ keystream_fifo_rd_data[31:24];
                ct_buffer[13] <= pt_buffer[13] ^ keystream_fifo_rd_data[23:16];
                ct_buffer[14] <= pt_buffer[14] ^ keystream_fifo_rd_data[15:8];
                ct_buffer[15] <= pt_buffer[15] ^ keystream_fifo_rd_data[7:0];
            end
    
            // --- 9. 송신 데이터 레지스터 쓰기 (MUX) ---
            if (!tx_busy && !tx_wr_en) begin
                if (state == S_SEND_CT) begin
                    tx_din_data <= ct_buffer[tx_byte_counter];
                end
                // ★ [NEW] 태그 전송 상태일 때 태그 버퍼 내용 전송
                else if (state == S_SEND_TAG) begin
                    tx_din_data <= tag_buffer[tx_byte_counter];
                end
            end
        end
    end

endmodule