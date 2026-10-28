// Asynchronous assertion, two-local-clock synchronous deassertion.
module fp_reset_sync(input wire clk, async_reset, output wire reset_out);
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_ff;
    always @(posedge clk or posedge async_reset)
        if (async_reset) sync_ff <= 2'b11;
        else sync_ff <= {sync_ff[0],1'b0};
    assign reset_out = sync_ff[1];
endmodule
