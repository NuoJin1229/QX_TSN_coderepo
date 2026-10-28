// Complete-frame commit/rollback receiver for the forced-mode Merge prototype.
// Output includes original FCS; malformed fragments are never partially delivered.
module fp_merge_rx #(
    parameter MAX_FRAME_BYTES = 2048
)(
    input wire clk, rst, link_up, pmac_enable,
    input wire [7:0] gmii_rxd,
    input wire gmii_rx_dv, gmii_rx_er,
    output wire [7:0] out_data,
    output wire out_valid, out_sop, out_last, out_preemptable,
    input wire out_ready,
    output wire busy,
    output reg [31:0] rx_e_frames, rx_p_frames, rx_fragments,
    output reg [31:0] rx_errors, rx_overruns
);
    `include "fp_crc.vh"
    localparam PRE=0, FC=1, PAYLOAD=2, DROP=3;
    reg [1:0] state;
    reg in_packet, packet_p, packet_bad;
    reg [3:0] pre_count;
    reg [7:0] e_mem [0:2*MAX_FRAME_BYTES-1];
    reg [7:0] p_mem [0:2*MAX_FRAME_BYTES-1];
    reg [1:0] e_committed, p_committed;
    reg e_write_slot, p_write_slot, e_read_slot, p_read_slot, replay_slot;
    wire e_full = e_committed[e_write_slot];
    wire p_full = p_committed[p_write_slot];
    reg p_pending;
    reg [15:0] e_len [0:1];
    reg [15:0] p_len [0:1];
    reg [15:0] saved_len, work_len, packet_bytes;
    reg [31:0] work_crc, saved_crc, tail;
    reg [2:0] tail_count;
    reg [1:0] frame_no, expected_frag;
    reg replay, replay_p;
    reg [15:0] replay_pos;
    wire [2:0] start_symbol = fp_decode_start(gmii_rxd);
    wire [2:0] cont_symbol = fp_decode_cont(gmii_rxd);
    wire [31:0] normal_fcs = ~work_crc;
    wire is_mcrc = tail == (normal_fcs ^ 32'hffff0000);
    assign out_valid = replay;
    assign out_preemptable = replay_p;
    assign out_data = replay_p ? p_mem[replay_slot*MAX_FRAME_BYTES+replay_pos] : e_mem[replay_slot*MAX_FRAME_BYTES+replay_pos];
    assign out_sop = replay && replay_pos == 0;
    assign out_last = replay && (replay_pos + 16'd1 == (replay_p ? p_len[replay_slot] : e_len[replay_slot]));
    assign busy = in_packet || p_pending || (|e_committed) || (|p_committed) || replay;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= PRE; in_packet <= 0; packet_p <= 0; packet_bad <= 0;
            pre_count <= 0; e_committed <= 0; p_committed <= 0; p_pending <= 0;
            e_write_slot <= 0; p_write_slot <= 0; e_read_slot <= 0; p_read_slot <= 0; replay_slot <= 0;
            e_len[0] <= 0; e_len[1] <= 0; p_len[0] <= 0; p_len[1] <= 0; saved_len <= 0; work_len <= 0;
            packet_bytes <= 0; work_crc <= 32'hffffffff;
            saved_crc <= 32'hffffffff; tail <= 0; tail_count <= 0;
            frame_no <= 0; expected_frag <= 0;
            replay <= 0; replay_p <= 0; replay_pos <= 0;
            rx_e_frames <= 0; rx_p_frames <= 0; rx_fragments <= 0;
            rx_errors <= 0; rx_overruns <= 0;
        end else if (!link_up) begin
            state <= PRE; in_packet <= 0; e_committed <= 0; p_committed <= 0;
            e_write_slot <= 0; p_write_slot <= 0; e_read_slot <= 0; p_read_slot <= 0;
            p_pending <= 0; replay <= 0; pre_count <= 0;
        end else begin
            if (!replay) begin
                if (e_committed[e_read_slot] || p_committed[p_read_slot]) begin
                    replay <= 1; replay_p <= !e_committed[e_read_slot]; replay_pos <= 0;
                    replay_slot <= e_committed[e_read_slot] ? e_read_slot : p_read_slot;
                end
            end else if (out_ready) begin
                if (out_last) begin
                    replay <= 0;
                    if (replay_p) begin p_committed[replay_slot] <= 0; p_read_slot <= !p_read_slot; end
                    else begin e_committed[replay_slot] <= 0; e_read_slot <= !e_read_slot; end
                end else replay_pos <= replay_pos + 1'b1;
            end

            if (gmii_rx_dv) begin
                in_packet <= 1;
                if (!in_packet) begin
                    pre_count <= gmii_rxd == 8'h55 ? 1 : 0;
                    state <= gmii_rxd == 8'h55 ? PRE : DROP;
                    packet_bad <= gmii_rx_er || gmii_rxd != 8'h55;
                    packet_p <= 0; packet_bytes <= 0; tail_count <= 0;
                    tail <= 0; work_len <= 0; work_crc <= 32'hffffffff;
                end else begin
                    if (gmii_rx_er) packet_bad <= 1;
                    case (state)
                        PRE: begin
                            if (gmii_rxd == 8'h55) begin
                                if (pre_count < 8) pre_count <= pre_count + 1'b1;
                            end else if (gmii_rxd == 8'hd5 && pre_count == 7) begin
                                packet_p <= 0; state <= e_full ? DROP : PAYLOAD;
                                if (e_full) begin
                                    packet_bad <= 1; rx_overruns <= rx_overruns + 1'b1;
                                end
                            end else begin
                                state <= DROP; packet_bad <= 1;
                                // Unknown/missing SMD cannot safely retain a partial context.
                                p_pending <= 0;
                            end
                        end
                        PAYLOAD: begin
                            // Delay four bytes: never include CRC/mCRC in cumulative CRC.
                            tail <= {gmii_rxd, tail[31:8]};
                            if (packet_bytes != 16'hffff) packet_bytes <= packet_bytes + 1'b1;
                            if (tail_count < 4) tail_count <= tail_count + 1'b1;
                            else if (work_len < MAX_FRAME_BYTES-4) begin
                                if (packet_p) p_mem[p_write_slot*MAX_FRAME_BYTES+work_len] <= tail[7:0];
                                else e_mem[e_write_slot*MAX_FRAME_BYTES+work_len] <= tail[7:0];
                                work_crc <= fp_crc32_byte(work_crc, tail[7:0]);
                                work_len <= work_len + 1'b1;
                            end else begin state <= DROP; packet_bad <= 1; end
                        end
                        default: ;
                    endcase
                end
            end else if (in_packet) begin
                in_packet <= 0; state <= PRE;
                if (state != PAYLOAD || packet_bad || tail_count != 4 || packet_bytes < 64) begin
                    rx_errors <= rx_errors + 1'b1;
                    if (packet_p) p_pending <= 0;
                end else if (tail == normal_fcs) begin
                    // Commit FCS only for a validated final frame. No partial delivery.
                        e_mem[e_write_slot*MAX_FRAME_BYTES+work_len] <= tail[7:0]; e_mem[e_write_slot*MAX_FRAME_BYTES+work_len+1] <= tail[15:8];
                        e_mem[e_write_slot*MAX_FRAME_BYTES+work_len+2] <= tail[23:16]; e_mem[e_write_slot*MAX_FRAME_BYTES+work_len+3] <= tail[31:24];
                        e_len[e_write_slot] <= work_len + 16'd4; e_committed[e_write_slot] <= 1; e_write_slot <= !e_write_slot;
                        rx_e_frames <= rx_e_frames + 1'b1;
                end else begin
                    rx_errors <= rx_errors + 1'b1;
                    if (packet_p) p_pending <= 0;
                end
            end
        end
    end
endmodule
