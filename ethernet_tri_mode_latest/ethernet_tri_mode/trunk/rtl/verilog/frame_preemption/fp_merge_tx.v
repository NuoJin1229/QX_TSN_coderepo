// Experimental, forced-mode MAC Merge transmitter; see design document.
// All inputs/outputs are synchronous to clk. Streams contain DA through FCS.
module fp_merge_tx #(
    parameter MAX_FRAME_BYTES = 2048
)(
    input wire clk, rst, link_up,
    input wire tx_enable, force_mode, hold_req,
    input wire [1:0] add_frag_size,
    input wire [7:0] e_data, input wire e_valid, e_last, e_abort,
    output wire e_ready,
    input wire [7:0] p_data, input wire p_valid, p_last, p_abort,
    output wire p_ready,
    output reg [7:0] gmii_txd,
    output reg gmii_tx_en,
    output wire tx_active,
    output wire busy,
    output reg [31:0] tx_e_frames, tx_p_frames, tx_fragments, tx_input_errors
);
    `include "fp_crc.vh"
    localparam IDLE=0, PREAMBLE=1, DELIM=2, FRAG_COUNT=3,
               DATA=4, MCRC=5, IFG=6;
    reg [2:0] state;
    reg [7:0] e_mem [0:MAX_FRAME_BYTES-1];
    reg [7:0] p_mem [0:MAX_FRAME_BYTES-1];
    reg e_full, p_full, e_bad, p_bad;
    reg [15:0] e_wr, p_wr, e_len, p_len;
    reg selected_p, p_started, p_encoded, continuation;
    reg [15:0] pos, p_pos, frag_bytes, min_data;
    reg [3:0] pre_left, gap_left;
    reg [1:0] frame_no, frag_no, crc_byte;
    reg [31:0] p_crc, mcrc;
    wire [31:0] p_crc_next = fp_crc32_byte(p_crc, p_mem[pos]);
    wire [15:0] next_pos = pos + 16'd1;
    wire cut_allowed = p_encoded && (e_full || hold_req) &&
                       (frag_bytes + 16'd1 >= min_data) &&
                       (p_len - next_pos >= 16'd64);
    assign e_ready = link_up && !e_full;
    assign p_ready = link_up && !p_full;
    assign tx_active = link_up && tx_enable && force_mode;
    assign busy = state != IDLE || e_full || p_full || e_wr != 0 || p_wr != 0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE; gmii_tx_en <= 0; gmii_txd <= 0;
            e_full <= 0; p_full <= 0; e_bad <= 0; p_bad <= 0;
            e_wr <= 0; p_wr <= 0; e_len <= 0; p_len <= 0;
            selected_p <= 0; p_started <= 0; p_encoded <= 0;
            continuation <= 0; pos <= 0; p_pos <= 0; frag_bytes <= 0;
            min_data <= 60; pre_left <= 0; gap_left <= 0;
            frame_no <= 0; frag_no <= 0; crc_byte <= 0;
            p_crc <= 32'hffffffff; mcrc <= 0;
            tx_e_frames <= 0; tx_p_frames <= 0;
            tx_fragments <= 0; tx_input_errors <= 0;
        end else if (!link_up) begin
            // Link loss invalidates complete and partial frames and sequence context.
            state <= IDLE; gmii_tx_en <= 0; gmii_txd <= 0;
            e_full <= 0; p_full <= 0; e_bad <= 0; p_bad <= 0;
            e_wr <= 0; p_wr <= 0; p_started <= 0;
            frame_no <= 0; frag_no <= 0;
        end else begin
            // Keep ready asserted while draining an oversized input until LAST.
            // Simultaneous e/p failures are counted separately.
            if ((e_abort && e_ready) || (p_abort && p_ready) ||
                (e_valid && e_ready && e_last && (e_bad || e_wr >= MAX_FRAME_BYTES || e_wr < 63)) ||
                (p_valid && p_ready && p_last && (p_bad || p_wr >= MAX_FRAME_BYTES || p_wr < 63)))
                tx_input_errors <= tx_input_errors +
                    ((e_abort && e_ready) || (e_valid && e_ready && e_last &&
                      (e_bad || e_wr >= MAX_FRAME_BYTES || e_wr < 63))) +
                    ((p_abort && p_ready) || (p_valid && p_ready && p_last &&
                      (p_bad || p_wr >= MAX_FRAME_BYTES || p_wr < 63)));
            if (e_abort && e_ready) begin e_wr <= 0; e_bad <= 0; end
            else if (e_valid && e_ready) begin
                if (e_wr < MAX_FRAME_BYTES) e_mem[e_wr] <= e_data;
                else e_bad <= 1;
                if (e_last) begin
                    e_wr <= 0; e_bad <= 0;
                    if (!e_bad && e_wr < MAX_FRAME_BYTES && e_wr >= 63) begin
                        e_len <= e_wr + 16'd1; e_full <= 1;
                    end
                end else if (e_wr < MAX_FRAME_BYTES) e_wr <= e_wr + 16'd1;
            end
            if (p_abort && p_ready) begin p_wr <= 0; p_bad <= 0; end
            else if (p_valid && p_ready) begin
                if (p_wr < MAX_FRAME_BYTES) p_mem[p_wr] <= p_data;
                else p_bad <= 1;
                if (p_last) begin
                    p_wr <= 0; p_bad <= 0;
                    if (!p_bad && p_wr < MAX_FRAME_BYTES && p_wr >= 63) begin
                        p_len <= p_wr + 16'd1; p_full <= 1;
                    end
                end else if (p_wr < MAX_FRAME_BYTES) p_wr <= p_wr + 16'd1;
            end
            gmii_tx_en <= 0; gmii_txd <= 0;
            case (state)
                IDLE: begin
                    if (e_full) begin
                        selected_p <= 0; pos <= 0; continuation <= 0;
                        pre_left <= 7; state <= PREAMBLE;
                    end else if (p_full && !hold_req) begin
                        selected_p <= 1; frag_bytes <= 0;
                        if (!p_started) begin
                            pos <= 0; p_crc <= 32'hffffffff;
                            p_encoded <= tx_active;
                            min_data <= 16'd60 + {8'b0,add_frag_size,6'b0};
                            continuation <= 0; frag_no <= 0; pre_left <= 7;
                            p_started <= 1;
                        end else begin
                            pos <= p_pos; continuation <= 1; pre_left <= 6;
                        end
                        state <= PREAMBLE;
                    end
                end
                PREAMBLE: begin
                    gmii_tx_en <= 1; gmii_txd <= 8'h55;
                    pre_left <= pre_left - 1'b1;
                    if (pre_left == 1) state <= DELIM;
                end
                DELIM: begin
                    gmii_tx_en <= 1;
                    gmii_txd <= !selected_p || !p_encoded ? 8'hd5 :
                                continuation ? fp_smd_cont(frame_no) : fp_smd_start(frame_no);
                    state <= selected_p && continuation ? FRAG_COUNT : DATA;
                end
                FRAG_COUNT: begin
                    gmii_tx_en <= 1; gmii_txd <= fp_smd_start(frag_no);
                    frag_no <= frag_no + 1'b1; state <= DATA;
                end
                DATA: begin
                    gmii_tx_en <= 1;
                    gmii_txd <= selected_p ? p_mem[pos] : e_mem[pos];
                    pos <= next_pos;
                    if (selected_p) begin
                        p_crc <= p_crc_next;
                        frag_bytes <= frag_bytes + 1'b1;
                        if (next_pos == p_len) begin
                            p_full <= 0; p_started <= 0;
                            if (p_encoded) frame_no <= frame_no + 1'b1;
                            tx_p_frames <= tx_p_frames + 1'b1;
                            gap_left <= 10; state <= IFG;
                        end else if (cut_allowed) begin
                            // Cumulative CRC context remains at the original-frame prefix.
                            // Wire bytes of mCRC: FCS[0],FCS[1],~FCS[2],~FCS[3].
                            mcrc <= (~p_crc_next) ^ 32'hffff0000;
                            p_pos <= next_pos; crc_byte <= 0; state <= MCRC;
                        end
                    end else if (next_pos == e_len) begin
                        e_full <= 0; tx_e_frames <= tx_e_frames + 1'b1;
                        gap_left <= 10; state <= IFG;
                    end
                end
                MCRC: begin
                    gmii_tx_en <= 1; gmii_txd <= mcrc[7:0]; mcrc <= mcrc >> 8;
                    crc_byte <= crc_byte + 1'b1;
                    if (crc_byte == 3) begin
                        tx_fragments <= tx_fragments + 1'b1;
                        gap_left <= 10; state <= IFG;
                    end
                end
                IFG: begin
                    // Eleven IFG-state clocks plus selection in IDLE = twelve idle bytes.
                    if (gap_left == 0) state <= IDLE;
                    else gap_left <= gap_left - 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
