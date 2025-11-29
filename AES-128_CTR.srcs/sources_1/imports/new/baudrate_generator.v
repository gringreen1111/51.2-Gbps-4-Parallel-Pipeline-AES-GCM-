`timescale 1ns / 1ps

module baud_rate_gen(
    input wire clk,         // 100 MHz
    input wire rst,
    output wire Rxclk_en,
    output wire Txclk_en
);

    // Parameters
    parameter RX_ACC_MAX = 100_000_000 / (115200 * 16);
    parameter TX_ACC_MAX = 100_000_000 / 115200;
    parameter RX_ACC_WIDTH = $clog2(RX_ACC_MAX);
    parameter TX_ACC_WIDTH = $clog2(TX_ACC_MAX);

    reg [RX_ACC_WIDTH - 1:0] rx_acc = 0;
    reg [TX_ACC_WIDTH - 1:0] tx_acc = 0;

    assign Rxclk_en = (rx_acc == 0);
    assign Txclk_en = (tx_acc == 0);

    // Rx 카운터
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_acc <= 0;
        end else begin
            if (rx_acc == RX_ACC_MAX - 1)
                rx_acc <= 0;
            else
                rx_acc <= rx_acc + 1;
        end
    end

    // Tx 카운터
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_acc <= 0;
        end else begin
            if (tx_acc == TX_ACC_MAX - 1)
                tx_acc <= 0;
            else
                tx_acc <= tx_acc + 1;
        end
    end

endmodule