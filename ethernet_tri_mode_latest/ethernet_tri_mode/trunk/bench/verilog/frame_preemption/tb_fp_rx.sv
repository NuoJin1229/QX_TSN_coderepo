`timescale 1ns/1ps
module tb_fp_rx;
    reg clk=0; always #4 clk=~clk;
    reg rst=1, link_up=1, pmac=1;
    reg [7:0] rd=0;
    reg dv=0,err=0,ready=1;
    wire [7:0] od;
    wire ov,os,ol,op,busy;
    wire [31:0] ec,pc,fc,errors,overruns;
    fp_merge_rx #(.MAX_FRAME_BYTES(2048)) dut(
        .clk(clk),.rst(rst),.link_up(link_up),.pmac_enable(pmac),
        .gmii_rxd(rd),.gmii_rx_dv(dv),.gmii_rx_er(err),
        .out_data(od),.out_valid(ov),.out_sop(os),.out_last(ol),.out_preemptable(op),
        .out_ready(ready),.busy(busy),.rx_e_frames(ec),.rx_p_frames(pc),
        .rx_fragments(fc),.rx_errors(errors),.rx_overruns(overruns));
    // bit12 pulses reset; other bits retain ready/ER/DV/data stimulus format.
    reg [12:0] stimuli[0:131071];
    reg [1023:0] vector_path,trace_path;
    integer n,count,f;
    reg held=0; reg [11:0] held_word;
    wire [11:0] current_word = {ov,op,os,ol,od};
    always @(posedge clk) if(rst) held <= 0; else begin
        if(held && current_word!==held_word) $fatal(1,"RX output changed under backpressure");
        held <= ov && !ready; held_word <= current_word;
        if(ov && ready) $fwrite(f,"%0d %0d %0d %02x\n",op,os,ol,od);
    end
    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing vectors");
        if(!$value$plusargs("TRACE=%s",trace_path)) $fatal(1,"missing trace");
        if(!$value$plusargs("COUNT=%d",count)) $fatal(1,"missing count");
        $readmemh(vector_path,stimuli,0,count-1); f=$fopen(trace_path,"w");
        repeat(5) @(negedge clk); rst=0;
        for(n=0;n<count;n=n+1) begin
            @(negedge clk);
            rst=stimuli[n][12];
            ready=stimuli[n][11]; err=stimuli[n][9]; dv=stimuli[n][8]; rd=stimuli[n][7:0];
        end
        @(negedge clk); dv=0; err=0; ready=1;
        repeat(5000) @(negedge clk);
        if(errors<7 || overruns<1) $fatal(1,"RX error coverage missing errors=%0d overruns=%0d",errors,overruns);
        $display("PASS RX e=%0d p=%0d fragments=%0d errors=%0d overruns=%0d",ec,pc,fc,errors,overruns);
        $fclose(f); $finish;
    end
    initial begin #2000000; $fatal(1,"RX watchdog timeout"); end
endmodule
