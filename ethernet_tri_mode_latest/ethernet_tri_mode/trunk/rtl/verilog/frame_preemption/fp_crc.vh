// Reflected Ethernet CRC32, byte bit 0 first; no final complement here.
// Caller initializes to ffffffff. Wire FCS is ~state, least significant byte first.
function [31:0] fp_crc32_byte;
    input [31:0] crc;
    input [7:0] data;
    reg [31:0] c;
    integer k;
    begin
        c = crc ^ {24'b0, data};
        for (k = 0; k < 8; k = k + 1)
            c = c[0] ? ((c >> 1) ^ 32'hedb88320) : (c >> 1);
        fp_crc32_byte = c;
    end
endfunction

function [7:0] fp_smd_start;
    input [1:0] n;
    begin
        case (n)
            0: fp_smd_start = 8'he6;
            1: fp_smd_start = 8'h4c;
            2: fp_smd_start = 8'h7f;
            3: fp_smd_start = 8'hb3;
        endcase
    end
endfunction

function [7:0] fp_smd_cont;
    input [1:0] n;
    begin
        case (n)
            0: fp_smd_cont = 8'h61;
            1: fp_smd_cont = 8'h52;
            2: fp_smd_cont = 8'h9e;
            3: fp_smd_cont = 8'had;
        endcase
    end
endfunction

