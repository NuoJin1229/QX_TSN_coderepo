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

