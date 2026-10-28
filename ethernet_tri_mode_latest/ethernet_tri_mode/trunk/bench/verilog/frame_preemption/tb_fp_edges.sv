`timescale 1ns/1ps
// Boundary, HOLD-only interruption, link loss and reset tests.
module tb_fp_edges;
    reg clk=0; always #4 clk=~clk;
    reg rst=1, link=1, hold_req=0;
    reg [1:0] add_size=0;
    reg [7:0] pd=0;
    reg pv=0,pl=0,pa=0,ea=0;
    wire pr,er,ten,busy,active; wire [7:0] td;
    wire [31:0] ec,pc,fc,errors;
    fp_merge_tx dut(
        .clk(clk),.rst(rst),.link_up(link),.tx_enable(1'b1),.force_mode(1'b1),
        .hold_req(hold_req),.add_frag_size(add_size),
        .e_data(8'b0),.e_valid(1'b0),.e_last(1'b0),.e_abort(ea),.e_ready(er),
        .p_data(pd),.p_valid(pv),.p_last(pl),.p_abort(pa),.p_ready(pr),
        .gmii_txd(td),.gmii_tx_en(ten),.tx_active(active),.busy(busy),
        .tx_e_frames(ec),.tx_p_frames(pc),.tx_fragments(fc),.tx_input_errors(errors));
    reg [7:0] vectors[0:8191];
    reg trace_on=0;
    reg [1023:0] vector_path,trace_path;
    integer f,n,j,k,offset=0,length,min_data,oldf,oldp,cycle=0,count;
    task pframe(input integer start,input integer size);
        integer i;
        begin
            for(i=0;i<size;i=i+1) begin
                @(negedge clk); while(!pr) @(negedge clk);
                pv=1; pd=vectors[start+i]; pl=i==size-1;
            end
            @(negedge clk); pv=0; pl=0;
        end
    endtask
    task drain;
        begin
            @(negedge clk); while(busy) @(negedge clk);
            repeat(16) @(negedge clk);
        end
    endtask
    always @(negedge clk) if(trace_on) begin
        $fwrite(f,"%0d %0d %02x\n",cycle,ten,td); cycle=cycle+1;
    end
    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing vectors");
        if(!$value$plusargs("TRACE=%s",trace_path)) $fatal(1,"missing trace");
        if(!$value$plusargs("COUNT=%d",count)) $fatal(1,"missing vector count");
        $readmemh(vector_path,vectors,0,count-1); f=$fopen(trace_path,"w");
        repeat(5) @(negedge clk); rst=0;
        // Link loss while collecting must discard the incomplete input.
        for(n=0;n<10;n=n+1) begin @(negedge clk); pv=1; pd=n; end
        @(negedge clk); pv=0; link=0;
        @(negedge clk); if(ten || pr || er || active) $fatal(1,"link-down output");
        repeat(3) @(negedge clk); link=1;
        if(busy) $fatal(1,"link loss retained input context");
        // Reset in DATA must stop a transmitting frame and clear state/counters.
        pframe(0,123); wait(dut.state==4 && dut.pos==12);
        @(negedge clk); rst=1; #1;
        if(ten || busy) $fatal(1,"asynchronous reset did not abort TX");
        repeat(4) @(negedge clk); rst=0;
        trace_on=1;
        // At min_data+63 bytes the frame is indivisible; at +64 it may split.
        // HOLD alone requests the interruption, with no express frame present.
        for(j=0;j<4;j=j+1) begin
            add_size=j; min_data=60+64*j;
            for(k=0;k<2;k=k+1) begin
                length=min_data+63+k; oldf=fc; oldp=pc;
                pframe(offset,length); offset=offset+length;
                wait(dut.state==4 && dut.pos==3);
                @(negedge clk); hold_req=1;
                repeat(450) @(negedge clk);
                if(k==0) begin
                    if(fc!=oldf || pc!=oldp+1 || ten) $fatal(1,"indivisible boundary");
                end else begin
                    if(fc!=oldf+1 || pc!=oldp || ten) $fatal(1,"exact split boundary");
                    if(!dut.p_started || !dut.p_full) $fatal(1,"HOLD lost suspended p");
                end
                hold_req=0; drain();
            end
        end
        add_size=0;
        pframe(offset,2048); offset=offset+2048; drain();
        if(pc!=9) $fatal(1,"MAX_FRAME_BYTES was rejected");
        pframe(offset,2049); offset=offset+2049; drain();
        if(pc!=9 || errors!=1) $fatal(1,"oversize was not rejected");
        // Two independent aborts on the same clock must count as two errors.
        @(negedge clk); ea=1; pa=1;
        @(negedge clk); ea=0; pa=0;
        pframe(offset,64); drain();
        if(pc!=10 || fc!=4 || errors!=3) $fatal(1,"edge counters");
        $display("PASS EDGES frames=%0d fragments=%0d errors=%0d boundaries=8 link_reset=2",pc,fc,errors);
        $fclose(f); $finish;
    end
    initial begin #1000000; $fatal(1,"edge watchdog"); end
endmodule
