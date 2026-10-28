// Verification-only technology replacement: synchronous one-cycle read RAM.
// Does not model mixed-port same-address collisions or physical macro timing.
// Never add this file alongside TECH/duram.v in a synthesis manifest.
module duram #(
    parameter DATA_WIDTH=32, ADDR_WIDTH=5,
    parameter BLK_RAM_TYPE="AUTO", DURAM_MODE="BIDIR_DUAL_PORT",
    parameter ADDR_DEPTH=2**ADDR_WIDTH
)(
    input [DATA_WIDTH-1:0] data_a,data_b,
    input wren_a,wren_b,
    input [ADDR_WIDTH-1:0] address_a,address_b,
    input clock_a,clock_b,
    output reg [DATA_WIDTH-1:0] q_a,q_b
);
    reg [DATA_WIDTH-1:0] mem[0:ADDR_DEPTH-1];
    always @(posedge clock_a) begin
        if(wren_a) mem[address_a]<=data_a;
        q_a<=mem[address_a];
    end
    always @(posedge clock_b) begin
        if(wren_b) mem[address_b]<=data_b;
        q_b<=mem[address_b];
    end
endmodule
