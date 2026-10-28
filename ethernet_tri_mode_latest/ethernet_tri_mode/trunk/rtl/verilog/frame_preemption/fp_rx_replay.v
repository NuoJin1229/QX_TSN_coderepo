// Convert a committed frame stream (DA..FCS) to an uninterrupted classic GMII
// stream for the existing MAC_rx. Source retains frame RAM until LAST handshake.
module fp_rx_replay (
    input wire clk, rst,
    input wire [7:0] in_data,
    input wire in_valid, in_last,
    output wire in_ready,
    output reg [7:0] mac_data,
    output reg mac_dv
);
    localparam IDLE=0, PRE=1, SFD=2, DATA=3, GAP=4;
    reg [2:0] state;
    reg [3:0] count;
    assign in_ready = state == DATA;
    always @(posedge clk or posedge rst) begin
        if (rst) begin state <= IDLE; count <= 0; mac_data <= 0; mac_dv <= 0; end
        else begin
            mac_dv <= 0; mac_data <= 0;
            case (state)
                IDLE: if (in_valid) begin state <= PRE; count <= 7; end
                PRE: begin
                    mac_dv <= 1; mac_data <= 8'h55; count <= count - 1'b1;
                    if (count == 1) state <= SFD;
                end
                SFD: begin mac_dv <= 1; mac_data <= 8'hd5; state <= DATA; end
                DATA: begin
                    mac_dv <= in_valid; mac_data <= in_data;
                    if (in_valid && in_last) begin state <= GAP; count <= 11; end
                end
                GAP: if (count == 0) state <= IDLE; else count <= count - 1'b1;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
