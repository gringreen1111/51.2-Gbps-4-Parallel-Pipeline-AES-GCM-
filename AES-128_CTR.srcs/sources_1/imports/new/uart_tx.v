`timescale 1ns / 1ps

module transmitter(
    input wire [7:0] din,
    input wire wr_en,
    input wire clk,
    input wire clken,
    input wire rst,
    output reg tx = 1'b1,
    output wire tx_busy
);

    parameter STATE_IDLE = 2'b00;
    parameter STATE_START = 2'b01;
    parameter STATE_DATA = 2'b10;
    parameter STATE_STOP = 2'b11;

    reg [7:0] data = 8'h00;
    reg [2:0] bitpos = 3'h0;
    reg [1:0] state = STATE_IDLE;

    // --- 수정된 부분 (START) ---
    always @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            tx <= 1'b1;
            bitpos <= 3'h0;
            data <= 8'h00;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (wr_en) begin
                        state <= STATE_START;
                        data <= din;
                        bitpos <= 3'h0;
                    end
                end
                STATE_START: begin
                    if (clken) begin
                        tx <= 1'b0; // 시작 비트
                        state <= STATE_DATA;
                    end
                end
                STATE_DATA: begin
                    if (clken) begin
                        if (bitpos == 3'h7)
                            state <= STATE_STOP;
                        else
                            bitpos <= bitpos + 3'h1;
                        tx <= data[bitpos];
                    end
                end
                STATE_STOP: begin
                    if (clken) begin
                        tx <= 1'b1; // 정지 비트
                        state <= STATE_IDLE;
                    end
                end
                default: begin
                    tx <= 1'b1;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

    assign tx_busy = (state != STATE_IDLE);

endmodule