// Strip a legacy MAC's 7x55,D5 and retain its last byte until EN falls.
// Connect frame_grant to a MAC_tx with FRAME_GRANT_ENABLE=1.
module fp_mac_capture (
    input wire clk, rst,
    input wire [7:0] mac_data, input wire mac_en,
    output wire [7:0] out_data,
    output wire out_valid, out_last, out_abort,
    input wire out_ready
);
    reg active, bad, pending;
    reg [3:0] pre_count;
    reg [7:0] last_data;
    reg header_done;
    assign out_data = last_data;
    assign out_valid = pending && header_done && !bad && (mac_en || active);
    assign out_last = out_valid && !mac_en;
    assign out_abort = active && !mac_en && (bad || !header_done);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active <= 0; bad <= 0; pending <= 0; pre_count <= 0;
            last_data <= 0; header_done <= 0;
        end else begin
            if (mac_en) begin
                active <= 1;
                if (!active) begin
                    pre_count <= mac_data == 8'h55 ? 1 : 0;
                    bad <= mac_data != 8'h55 || !out_ready;
                    header_done <= 0; pending <= 0;
                end else if (!header_done) begin
                    if (mac_data == 8'h55 && pre_count < 7) pre_count <= pre_count + 1'b1;
                    else if (mac_data == 8'hd5 && pre_count == 7) header_done <= 1;
                    else bad <= 1;
                end else begin
                    pending <= 1; last_data <= mac_data;
                    if (!out_ready) bad <= 1;
                end
            end else begin
                active <= 0; pending <= 0; header_done <= 0;
            end
        end
    end
endmodule
