`timescale 1ns/1ps
module tb_fp_merge;
    reg clk=0; always #4 clk=~clk;
    reg rst=1, link_up=1, enable=1, force_mode=1, hold_req=0;
    reg [1:0] add_size=0;
    reg [7:0] ed=0,pd=0;
    reg ev=0,el=0,ea=0,pv=0,pl=0,pa=0;
    wire er,pr,ten,active,busy; wire [7:0] td;
    wire [31:0] ec,pc,fc,errors;
    fp_merge_tx #(.MAX_FRAME_BYTES(2048)) dut(
        .clk(clk),.rst(rst),.link_up(link_up),.tx_enable(enable),.force_mode(force_mode),
        .hold_req(hold_req),.add_frag_size(add_size),
        .e_data(ed),.e_valid(ev),.e_last(el),.e_abort(ea),.e_ready(er),
        .p_data(pd),.p_valid(pv),.p_last(pl),.p_abort(pa),.p_ready(pr),
        .gmii_txd(td),.gmii_tx_en(ten),.tx_active(active),.busy(busy),
        .tx_e_frames(ec),.tx_p_frames(pc),.tx_fragments(fc),.tx_input_errors(errors));
    reg [7:0] vectors[0:65535];
    integer f,cycle=0,i,j,count,seed=32'h31287;
    reg [1023:0] vector_path,trace_path;
    task eframe(input integer offset,input integer length);
        integer n;
        begin
            for(n=0;n<length;n=n+1) begin
                @(negedge clk); while(!er) @(negedge clk);
                ev=1; ed=vectors[offset+n]; el=n==length-1;
            end
            @(negedge clk); ev=0; el=0;
        end
    endtask
    task pframe(input integer offset,input integer length);
        integer n;
        begin
            for(n=0;n<length;n=n+1) begin
                @(negedge clk); while(!pr) @(negedge clk);
                pv=1; pd=vectors[offset+n]; pl=n==length-1;
            end
            @(negedge clk); pv=0; pl=0;
        end
    endtask
    task drain;
        begin
            @(negedge clk);
            while(busy) @(negedge clk);
            repeat(20) @(negedge clk);
        end
    endtask
    always @(negedge clk) begin
        if(!rst) begin
            $fwrite(f,"%0d %0d %02x\n",cycle,ten,td); cycle=cycle+1;
        end
    end
    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"VECTORS missing");
        if(!$value$plusargs("TRACE=%s",trace_path)) $fatal(1,"TRACE missing");
        if(!$value$plusargs("COUNT=%d",count)) $fatal(1,"COUNT missing");
        $readmemh(vector_path,vectors,0,count-1); f=$fopen(trace_path,"w");
        repeat(5) @(negedge clk); rst=0;
        // Inactive preemption must emit normal Ethernet even for a p input.
        force_mode=0; pframe(0,64); drain(); force_mode=1;
        // Express may arrive while p is held, but p must never start under HOLD.
        hold_req=1; pframe(64,123); repeat(15) @(negedge clk);
        if(ten) $fatal(1,"p frame started while HOLD asserted");
        eframe(187,64); repeat(110) @(negedge clk);
        hold_req=0; drain();
        // Repeated express interruptions force continuation sequence wraparound.
        pframe(251,1800);
        for(i=0;i<8;i=i+1) begin
            wait(dut.state==4 && dut.selected_p && dut.frag_bytes==20);
            if(i==0) hold_req=1;
            eframe(2051+i*64,64);
            hold_req=0;
            wait(!ten); wait(ten);
        end
        drain();
        // Configured minimum sizes 124/188/252; final original FCS retained.
        for(j=1;j<4;j=j+1) begin
            add_size=j;
            pframe(2563+(j-1)*600,600);
            wait(dut.state==4 && dut.selected_p && dut.pos==10);
            eframe(4363+(j-1)*64,64); drain();
        end
        // Oversized, short and aborted frames must not become wire packets.
        pframe(4555,2050); eframe(6605,63);
        @(negedge clk); pv=1; pd=8'h12;
        @(negedge clk); pv=0; pa=1;
        @(negedge clk); pa=0; drain();
        // Recovery after bad inputs, all modulo-four frame numbers wrap.
        add_size=0;
        for(j=0;j<8;j=j+1) begin pframe(6668+j*64,64); drain(); end
        if(ec!=12 || pc!=14 || fc<10 || errors!=3)
            $fatal(1,"TX counters e=%0d p=%0d fragments=%0d errors=%0d",ec,pc,fc,errors);
        $display("PASS TX e=%0d p=%0d fragments=%0d input_errors=%0d",ec,pc,fc,errors);
        $fclose(f); $finish;
    end
    initial begin #2000000; $fatal(1,"TX watchdog timeout"); end
endmodule
