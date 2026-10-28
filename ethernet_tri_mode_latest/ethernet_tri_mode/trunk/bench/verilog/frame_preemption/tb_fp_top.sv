`timescale 1ns/1ps
module tb_fp_top;
    reg c125=0,cu=0,cr=0,rxclk=0;
    always #4 c125=~c125;
    always #5 cu=~cu;
    always #7 cr=~cr;
    initial begin #2; forever #4 rxclk=~rxclk; end
    reg rst=1,link=1,hold_req=0;
    reg wr=0,sop=0,eop=0;
    reg [31:0] wd=0;
    reg [1:0] be=0;
    reg [2:0] priority_in=0;
    wire wa,ra,pa,rs,re,ten,ter,gtx,supported,active;
    wire [7:0] td;
    wire [31:0] rdata;
    wire [1:0] rbe;
    wire [2:0] speed;
    wire [31:0] te,tp,tf,txerr,rx_e,rx_p,rf,rxerr,overruns;
    wire len_ra; wire [15:0] len_data;
    reg len_rd=0;
    reg csb=1,wrb=1; reg [7:0] ca=0; reg [15:0] cd=0;
    MAC_top_fp dut(
        .Reset(rst),.Clk_125M(c125),.Clk_user(cu),.Clk_reg(cr),.Speed(speed),
        .fp_link_up(link),.fp_tx_enable(1'b1),.fp_force_mode(1'b1),.fp_pmac_enable(1'b1),
        .fp_hold_req(hold_req),.fp_add_frag_size(2'b0),.fp_preemptable_mask(8'h01),
        .Tx_mac_priority(priority_in),.fp_supported(supported),.fp_tx_active(active),
        .fp_tx_e_frames(te),.fp_tx_p_frames(tp),.fp_tx_fragments(tf),.fp_tx_errors(txerr),
        .fp_rx_e_frames(rx_e),.fp_rx_p_frames(rx_p),.fp_rx_fragments(rf),
        .fp_rx_errors(rxerr),.fp_rx_overruns(overruns),
        .Tx_mac_wa(wa),.Tx_mac_wr(wr),.Tx_mac_data(wd),.Tx_mac_BE(be),.Tx_mac_sop(sop),.Tx_mac_eop(eop),
        .Rx_mac_ra(ra),.Rx_mac_rd(ra),.Rx_mac_data(rdata),.Rx_mac_BE(rbe),.Rx_mac_pa(pa),
        .Rx_mac_sop(rs),.Rx_mac_eop(re),.Pkg_lgth_fifo_rd(len_rd),
        .Pkg_lgth_fifo_ra(len_ra),.Pkg_lgth_fifo_data(len_data),
        .Gtx_clk(gtx),.Rx_clk(rxclk),.Tx_clk(1'b0),.Tx_en(ten),.Tx_er(ter),.Txd(td),
        .Rx_er(ter),.Rx_dv(ten),.Rxd(td),.Crs(1'b0),.Col(1'b0),
        .CSB(csb),.WRB(wrb),.CD_in(cd),.CD_out(),.CA(ca),.Mdo(),.MdoEn(),.Mdi(1'b0),.Mdc());
    reg [7:0] vectors[0:4095];
    integer f,wire_f,cycle=0,n,words=0,len_count=0,count;
    reg [1023:0] vector_path,trace_path,wire_path;
    task regwrite(input [6:0] index,input [15:0] value);
        begin
            @(negedge cr); csb=0; wrb=0; ca={index,1'b0}; cd=value;
            @(negedge cr); csb=1; wrb=1;
        end
    endtask
    task send(input integer offset,input integer length,input [2:0] prio);
        integer pos,k,left; reg [31:0] word;
        begin
            for(pos=0;pos<length;pos=pos+4) begin
                // Only the first accepted word selects a class. Change priority
                // on every later word to expose accidental mid-frame rerouting.
                @(negedge cu); priority_in=pos==0 ? prio : (prio ^ 3'b111);
                while(!wa) @(negedge cu);
                left=length-pos; word=0;
                for(k=0;k<4;k=k+1) if(k<left) word[31-k*8 -: 8]=vectors[offset+pos+k];
                wr=1; wd=word; sop=pos==0; eop=left<=4; be=left<4 ? left : 0;
            end
            @(negedge cu); wr=0; sop=0; eop=0;
        end
    endtask
    always @(posedge cu) if(!rst && pa) begin
        $fwrite(f,"%0d %0d %0d %08x\n",rs,re,rbe,rdata); words=words+1;
    end
    always @(negedge c125) if(!rst) begin
        $fwrite(wire_f,"%0d %0d %02x\n",cycle,ten,td); cycle=cycle+1;
    end
    // Length FIFO's original rd_ack is two-cycle delayed; consume one entry at a time.
    initial begin
        wait(!rst);
        forever begin
            @(negedge cu); len_rd=0;
            if(len_ra) begin
                len_rd=1; @(negedge cu); len_rd=0;
                $display("LENGTH %0d",len_data); len_count=len_count+1;
                repeat(2) @(negedge cu);
            end
        end
    end
    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing vectors");
        if(!$value$plusargs("TRACE=%s",trace_path)) $fatal(1,"missing trace");
        if(!$value$plusargs("WIRE=%s",wire_path)) $fatal(1,"missing wire trace");
        if(!$value$plusargs("COUNT=%d",count)) $fatal(1,"missing count");
        $readmemh(vector_path,vectors,0,count-1); f=$fopen(trace_path,"w"); wire_f=$fopen(wire_path,"w");
        repeat(12) @(negedge cu); rst=0;
        repeat(12) @(negedge cu);
        regwrite(24,1); // Existing RX CRC checker must agree with independent checker.
        // p input body excludes FCS; old MAC generates padding/FCS.
        send(0,996,0);
        wait(dut.u_fp_tx.state==4 && dut.u_fp_tx.selected_p && dut.u_fp_tx.pos==20);
        send(996,61,7); // BE=01 at the final word; one legal express interruption.
        repeat(4000) @(negedge cu);
        // Exercise all tail-byte counts and per-frame route lock with alternating classes.
        send(1057,62,7); repeat(400) @(negedge cu);
        send(1119,63,0); repeat(400) @(negedge cu);
        send(1182,60,7); repeat(400) @(negedge cu);
        if(te!=3 || tp!=2 || tf<1 || txerr!=0 || rx_e!=3 || rx_p!=2 || rxerr!=0 || overruns!=0)
            $fatal(1,"top stats te=%0d tp=%0d tf=%0d txerr=%0d re=%0d rp=%0d rxerr=%0d overrun=%0d",te,tp,tf,txerr,rx_e,rx_p,rxerr,overruns);
        if(len_count!=5) $fatal(1,"length entries %0d expected 5",len_count);
        $display("PASS TOP frames=5 tx_fragments=%0d rx_fragments=%0d words=%0d lengths=%0d",tf,rf,words,len_count);
        $fclose(f); $fclose(wire_f); $finish;
    end
    initial begin #500000; $fatal(1,"TOP watchdog timeout"); end
endmodule
