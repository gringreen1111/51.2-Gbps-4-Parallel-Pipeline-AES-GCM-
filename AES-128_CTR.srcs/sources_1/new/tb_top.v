`timescale 1ns / 1ps

module tb_aes_ctr_top;

    // --- 시뮬레이션 파라미터 ---
    localparam CLK_FREQ      = 100_000_000;
    localparam BAUD_RATE     = 115200;
    localparam CLK_PERIOD_NS = 10;
    localparam BIT_CYCLES    = CLK_FREQ / BAUD_RATE;
    localparam BIT_PERIOD_NS = BIT_CYCLES * CLK_PERIOD_NS;

    // --- DUT 연결 신호 ---
    reg  CLK100MHZ;
    reg  rst;
    reg  uart_rxd;
    wire uart_txd;

    // --- 테스트 벡터 (전송용) ---
    reg [127:0] tb_key   = 128'h2b7e151628aed2a6abf7158809cf4f3c;
    reg [127:0] tb_nonce = 128'hf0f1f2f3f4f5f6f7f8f9fafbfcfdfeff;
    reg [127:0] tb_pt1   = 128'h6bc1bee22e409f96e93d7e117393172a;
    reg [127:0] tb_pt2   = 128'hae2d8a571e03ac9c9eb76fac45af8e51;
    
    // --- 수신 데이터 저장용 ---
    reg [127:0] received_ct1;
    reg [127:0] received_ct2;

    // --- DUT 인스턴스 ---
    top uut (
        .CLK100MHZ(CLK100MHZ),
        .rst(rst),
        .uart_rxd(uart_rxd),
        .uart_txd(uart_txd)
    );
    
    // --- 1. 클럭 생성 ---
    always # (CLK_PERIOD_NS / 2) CLK100MHZ = ~CLK100MHZ;

    // --- 2. 메인 테스트 시퀀스 ---
    initial begin
        $display("\nDUT: 테스트 시작. 리셋...");
        // (initial 블록의 CLK100MHZ = 0; 라인 삭제됨)
        rst = 1; 
        uart_rxd = 1; // IDLE (High)
        # (CLK_PERIOD_NS * 20);
        rst = 0;
        # (CLK_PERIOD_NS * 100);

        // (PC) 1. 키 전송
        $display("DUT: [S_RECV_KEY] 16바이트 키 전송...");
        send_block(tb_key);
        
        // (PC) 2. Nonce 전송
        $display("DUT: [S_RECV_NONCE] 16바이트 Nonce 전송...");
        send_block(tb_nonce);
        
        // (PC) 3. 평문 1 전송
        $display("DUT: [S_RECV_PT] 16바이트 평문 1 전송...");
        send_block(tb_pt1);

        // (PC) 4. 암호문 1 수신
        $display("DUT: [S_SEND_CT] 16바이트 암호문 1 수신 대기...");
        receive_block(received_ct1);

        // (PC) 5. 평문 2 전송
        $display("DUT: [S_RECV_PT] 16바이트 평문 2 전송...");
        send_block(tb_pt2);

        // (PC) 6. 암호문 2 수신
        $display("DUT: [S_SEND_CT] 16바이트 암호문 2 수신 대기...");
        receive_block(received_ct2);
        
        # (BIT_PERIOD_NS * 2); // 여유 시간

        $display("\n--- 시뮬레이션 종료 ---");
        $display(" - 수신된 CT1: %h", received_ct1);
        $display(" - 수신된 CT2: %h", received_ct2);

        $finish;
    end

    // --- (태스크) 16바이트 블록 전송 ---
    task send_block;
        input [127:0] data_in;
        reg [7:0] temp_byte;
        integer i; // 👈 *** 수정: 변수 선언 위치 ***
    begin
        for (i = 0; i < 16; i = i + 1) begin // 👈 *** 수정 ***
            temp_byte = data_in >> (8 * (15 - i));
            send_byte(temp_byte);
        end
    end
    endtask

    // --- (태스크) 16바이트 블록 수신 ---
    task receive_block;
        output [127:0] data_out;
        reg [7:0] temp_byte;
        reg stop_error;
        integer i; // 👈 *** 수정: 변수 선언 위치 ***
    begin
        data_out = 0;
        for (i = 0; i < 16; i = i + 1) begin // 👈 *** 수정 ***
            receive_byte(temp_byte, stop_error);
            data_out = (data_out << 8) | temp_byte;
        end
    end
    endtask

    // --- (태스크) 1바이트 UART 전송 (시뮬레이션용) ---
    task send_byte;
        input [7:0] data_in;
        integer j; // 👈 *** 수정: 변수 선언 위치 ***
    begin
        uart_rxd = 1'b0; // Start Bit
        #(BIT_PERIOD_NS);
        for (j = 0; j < 8; j = j + 1) begin // LSB first // 👈 *** 수정 ***
            uart_rxd = data_in[j];
            #(BIT_PERIOD_NS);
        end
        uart_rxd = 1'b1; // Stop Bit
        #(BIT_PERIOD_NS);
    end
    endtask

    // --- (태스크) 1바이트 UART 수신 (시뮬레이션용) ---
    task receive_byte;
        output [7:0] data_out;
        output reg   stop_error;
        reg [7:0]    temp_data;
        integer j; // 👈 *** 수정: 변수 선언 위치 ***
    begin
        stop_error = 1'b0;
        @(negedge uart_txd); // Start Bit 감지
        #(BIT_PERIOD_NS / 2); // Start Bit 중앙
        
        if (uart_txd != 1'b0) $display("TB ERROR: Start bit 아님");

        for (j = 0; j < 8; j = j + 1) begin // LSB first // 👈 *** 수정 ***
            #(BIT_PERIOD_NS); // 다음 비트 중앙
            temp_data[j] = uart_txd;
        end
        
        #(BIT_PERIOD_NS); // Stop Bit 중앙
        if (uart_txd != 1'b1) begin
            stop_error = 1'b1;
            $display("TB ERROR: Stop bit 아님");
        end
        data_out = temp_data;
    end
    endtask

endmodule