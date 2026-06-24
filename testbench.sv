`timescale 1ns/1ps

interface cache_cpu_if(input logic clk);
  logic        req_valid;
  logic        req_ready;
  logic        req_write;
  logic [31:0] addr;
  logic [31:0] wdata;
  logic [3:0]  wstrb;

  logic        resp_valid;
  logic [31:0] rdata;
endinterface

// CPU cache transaction
class cache_txn;
  rand bit        write;
  rand bit [31:0] addr;
  rand bit [31:0] wdata;
  rand bit [3:0]  wstrb;
       bit [31:0] rdata;
   
  // Word aligned address (address multiple of 4)
  constraint c_addr  { addr < 32'h0000_1000; addr[1:0] == 2'b00; }
  constraint c_wstrb { if (write) wstrb != 4'b0000; else wstrb == 4'b0000; }

  function cache_txn copy();
    cache_txn t;
    t = new();
    t.write = write;
    t.addr  = addr;
    t.wdata = wdata;
    t.wstrb = wstrb;
    t.rdata = rdata;
    return t;
  endfunction

  function void print(string tag);
    if (write)
      $display("[%s] WRITE addr=0x%08h wdata=0x%08h wstrb=0x%0h rdata=0x%08h",
               tag, addr, wdata, wstrb, rdata);
    else
      $display("[%s] READ  addr=0x%08h wdata=0x%08h wstrb=0x%0h rdata=0x%08h",
               tag, addr, wdata, wstrb, rdata);
  endfunction
endclass

// Generator

class cache_generator;
  mailbox gen2drv;  //mailbox to the driver
  mailbox done_mbx; // mailbox to scoreboard
  int num_random;

  function new(mailbox gen2drv, mailbox done_mbx, int num_random = 100);
    this.gen2drv = gen2drv;
    this.done_mbx = done_mbx;
    this.num_random = num_random;
  endfunction

  function bit [31:0] make_addr(int tag, int index, int word_offset);
    bit [31:0] a;
    begin
      a = 32'd0;
      a[31:9] = tag[22:0];
      a[8:5]  = index[3:0];
      a[4:0]  = word_offset[2:0] << 2;
      return a;
    end
  endfunction

  task send_txn(cache_txn tr);
    int dummy;
    gen2drv.put(tr);
    done_mbx.get(dummy); // wait until scoreboard finishes this txn
  endtask

  task send_read(bit [31:0] addr);
    cache_txn tr;
    tr = new();
    tr.write = 0;
    tr.addr  = addr;
    tr.wdata = 32'd0;
    tr.wstrb = 4'd0; // as it is read
    send_txn(tr);
  endtask

  task send_write(bit [31:0] addr, bit [31:0] data, bit [3:0] strb);
    cache_txn tr;
    tr = new();
    tr.write = 1;
    tr.addr  = addr;
    tr.wdata = data;
    tr.wstrb = strb;
    send_txn(tr);
  endtask
  
  // Directed testing
  task run_directed();
    bit [31:0] a1, a2, a3, a4, a5;

    $display("[GEN] Test 1: read miss followed by read hit");
    send_read(32'h0000_0010);
    send_read(32'h0000_0010); // read hit

    $display("[GEN] Test 2: write then read same address");
    send_write(32'h0000_0020, 32'hA1B2_C3D4, 4'hF);
    send_read (32'h0000_0020);

    $display("[GEN] Test 3: partial byte write");
    send_write(32'h0000_0024, 32'hCAFE_1234, 4'b0011);
    send_read (32'h0000_0024);

    $display("[GEN] Test 4: same-set replacement and dirty eviction");
    a1 = make_addr(1, 0, 0); // Different Tag but same index
    a2 = make_addr(2, 0, 0);
    a3 = make_addr(3, 0, 0);
    a4 = make_addr(4, 0, 0);
    a5 = make_addr(5, 0, 0);

    // Fill all 4 ways of set 0. a1 is dirty because it is written.
    send_write(a1, 32'h1111_AAAA, 4'hF);
    send_read (a2);
    send_read (a3);
    send_read (a4);

    // Touch a2 and a3 so the pseudo-LRU victim becomes a1.
    send_read (a2);
    send_read (a3);

    // This new line maps to the same set and should push out dirty a1.
    send_read (a5);

    // Reading a1 again should still return the written value after write-back.
    send_read (a1);
  endtask

  task run_random();
    cache_txn tr;
    $display("[GEN] Random test: %0d transactions", num_random);

    repeat (num_random) begin
      tr = new();
      if (!tr.randomize()) begin
        $fatal(1, "[GEN] randomize failed");
      end
      send_txn(tr);
    end
  endtask

  task run();
    run_directed();
    run_random();
    gen2drv.put(null); // to stop the driver
    $display("[GEN] Done");
  endtask
endclass

class cache_driver;
  virtual cache_cpu_if vif;
  mailbox gen2drv;
  bit done;

  function new(virtual cache_cpu_if vif, mailbox gen2drv);
    this.vif = vif;
    this.gen2drv = gen2drv;
    done = 0;
  endfunction

  task reset_signals();
    vif.req_valid <= 0;
    vif.req_write <= 0;
    vif.addr      <= 0;
    vif.wdata     <= 0;
    vif.wstrb     <= 0;
  endtask

  task drive_one(cache_txn tr);
    @(negedge vif.clk);
    vif.req_valid <= 1;
    vif.req_write <= tr.write;
    vif.addr      <= tr.addr;
    vif.wdata     <= tr.wdata;
    vif.wstrb     <= tr.wstrb;

    while (!vif.req_ready) @(posedge vif.clk);

    @(negedge vif.clk);
    vif.req_valid <= 0;
    vif.req_write <= 0;
    vif.addr      <= 0;
    vif.wdata     <= 0;
    vif.wstrb     <= 0;

    while (!vif.resp_valid) @(posedge vif.clk);
  endtask

  task run();
    cache_txn tr;
    reset_signals();

    forever begin
      gen2drv.get(tr);
      if (tr == null) begin // From generator to driver
        done = 1;
        $display("[DRV] Done");
        break;
      end
      tr.print("DRV");
      drive_one(tr);
    end
  endtask
endclass

// Monitor
class cache_monitor;
  virtual cache_cpu_if vif;
  mailbox mon2sb;  // mailbox from monitor to scoreboard
  cache_txn req_q[$];

  function new(virtual cache_cpu_if vif, mailbox mon2sb);
    this.vif = vif;
    this.mon2sb = mon2sb;
  endfunction

  task run();
    cache_txn req;
    cache_txn rsp;

    forever begin
      @(posedge vif.clk);

      if (vif.req_valid && vif.req_ready) begin
        req = new();
        req.write = vif.req_write;
        req.addr  = vif.addr;
        req.wdata = vif.wdata;
        req.wstrb = vif.wstrb;
        req_q.push_back(req);
        req.print("MON-REQ");
      end

      if (vif.resp_valid) begin
        if (req_q.size() == 0) begin
          $fatal(1, "[MON] Response seen without request");
        end
        rsp = req_q.pop_front();
        rsp.rdata = vif.rdata;
        rsp.print("MON-RSP");
        mon2sb.put(rsp);
      end
    end
  endtask
endclass

// Scoreboard code

class cache_scoreboard;
  mailbox mon2sb; // from monitor to the scoreboard
  mailbox done_mbx; // From generator to scoreboard

  byte unsigned ref_mem [0:65535];
  int reads;
  int writes;
  int errors;

  function new(mailbox mon2sb, mailbox done_mbx);
    this.mon2sb = mon2sb;
    this.done_mbx = done_mbx;
    reads = 0;
    writes = 0;
    errors = 0;

    for (int i = 0; i < 65536; i++) begin
      ref_mem[i] = i[7:0];
    end
  endfunction

  function bit [31:0] ref_read32(bit [31:0] addr);
    bit [31:0] data;
    begin
      data = 32'd0;
      for (int b = 0; b < 4; b++) begin
        data[b*8 +: 8] = ref_mem[addr + b];
      end
      return data;
    end
  endfunction

  function void ref_write32(bit [31:0] addr, bit [31:0] data, bit [3:0] strb);
    for (int b = 0; b < 4; b++) begin
      if (strb[b]) begin
        ref_mem[addr + b] = data[b*8 +: 8];
      end
    end
  endfunction

  task run();
    cache_txn tr;
    bit [31:0] expected;

    forever begin
      mon2sb.get(tr);

      if (tr.write) begin
        ref_write32(tr.addr, tr.wdata, tr.wstrb);
        writes++;
      end else begin
        expected = ref_read32(tr.addr);
        reads++;
        if (tr.rdata !== expected) begin
          errors++;
          $display("[SB] ERROR addr=0x%08h expected=0x%08h got=0x%08h",
                   tr.addr, expected, tr.rdata);
        end else begin
          $display("[SB] READ PASS addr=0x%08h data=0x%08h", tr.addr, tr.rdata);
        end
      end

      done_mbx.put(1);
    end
  endtask

  task report();
    $display("--------------------------------------------------");
    $display("[SB] Reads checked  = %0d", reads);
    $display("[SB] Writes checked = %0d", writes);
    $display("[SB] Errors         = %0d", errors);
    if (errors == 0) $display("[SB] PASS");
    else             $display("[SB] FAIL");
    $display("--------------------------------------------------");
  endtask
endclass

// Environment

class cache_env;
  virtual cache_cpu_if vif;

  mailbox gen2drv;
  mailbox mon2sb;
  mailbox done_mbx;

  cache_generator  gen;
  cache_driver     drv;
  cache_monitor    mon;
  cache_scoreboard sb;

  function new(virtual cache_cpu_if vif, int num_random = 100);
    this.vif = vif;

    gen2drv  = new();
    mon2sb   = new();
    done_mbx = new();

    gen = new(gen2drv, done_mbx, num_random);
    drv = new(vif, gen2drv);
    mon = new(vif, mon2sb);
    sb  = new(mon2sb, done_mbx);
  endfunction

  task run();
    fork
      drv.run();
      mon.run();
      sb.run();
    join_none

    gen.run();
    wait (drv.done == 1);
    repeat (10) @(posedge vif.clk);
    sb.report();
  endtask
endclass

// Backing memory model 
module cache_mem_model (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         mem_req_valid,
  output logic         mem_req_ready,
  input  logic         mem_req_write,
  input  logic [31:0]  mem_addr,
  input  logic [255:0] mem_wline,
  output logic         mem_resp_valid,
  output logic [255:0] mem_rline
);
  parameter int LATENCY = 2;

  byte unsigned mem [0:65535];
  logic pending;
  logic pending_write;
  logic [31:0] pending_addr;
  logic [255:0] pending_wline;
  int delay_count;

  assign mem_req_ready = !pending;

  initial begin
    for (int i = 0; i < 65536; i++) begin
      mem[i] = i[7:0];
    end
  end

  function automatic logic [255:0] read_line(input logic [31:0] addr);
    logic [255:0] line;
    begin
      line = 256'd0;
      for (int b = 0; b < 32; b++) begin
        line[b*8 +: 8] = mem[addr + b];
      end
      return line;
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending <= 0;
      pending_write <= 0;
      pending_addr <= 0;
      pending_wline <= 0;
      delay_count <= 0;
      mem_resp_valid <= 0;
      mem_rline <= 0;
    end else begin
      mem_resp_valid <= 0;

      if (!pending && mem_req_valid && mem_req_ready) begin
        pending <= 1;
        pending_write <= mem_req_write;
        pending_addr <= {mem_addr[31:5], 5'b0};
        pending_wline <= mem_wline;
        delay_count <= LATENCY;
      end else if (pending) begin
        if (delay_count == 0) begin
          if (pending_write) begin
            for (int b = 0; b < 32; b++) begin
              mem[pending_addr + b] <= pending_wline[b*8 +: 8];
            end
            mem_rline <= 0;
          end else begin
            mem_rline <= read_line(pending_addr);
          end
          mem_resp_valid <= 1;
          pending <= 0;
        end else begin
          delay_count <= delay_count - 1;
        end
      end
    end
  end
endmodule

module tb_cache_4way;
  logic clk;
  logic rst_n;

  cache_cpu_if cpu_if(clk);

  logic         mem_req_valid;
  logic         mem_req_ready;
  logic         mem_req_write;
  logic [31:0]  mem_addr;
  logic [255:0] mem_wline;
  logic         mem_resp_valid;
  logic [255:0] mem_rline;

  logic [2:0] dbg_state;
  logic       dbg_hit;
  logic       dbg_miss;
  logic       dbg_dirty_evict;
  logic [1:0] dbg_hit_way;
  logic [1:0] dbg_victim_way;
  logic       dbg_req_write;

  cache_env env;

  int hit_count;
  int miss_count;
  int dirty_evict_count;

  initial clk = 0;
  always #5 clk = ~clk;

  cache_4way dut (
    .clk(clk),
    .rst_n(rst_n),

    .cpu_req_valid(cpu_if.req_valid),
    .cpu_req_ready(cpu_if.req_ready),
    .cpu_req_write(cpu_if.req_write),
    .cpu_addr(cpu_if.addr),
    .cpu_wdata(cpu_if.wdata),
    .cpu_wstrb(cpu_if.wstrb),
    .cpu_resp_valid(cpu_if.resp_valid),
    .cpu_rdata(cpu_if.rdata),

    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write),
    .mem_addr(mem_addr),
    .mem_wline(mem_wline),
    .mem_resp_valid(mem_resp_valid),
    .mem_rline(mem_rline),

    .dbg_state(dbg_state),
    .dbg_hit(dbg_hit),
    .dbg_miss(dbg_miss),
    .dbg_dirty_evict(dbg_dirty_evict),
    .dbg_hit_way(dbg_hit_way),
    .dbg_victim_way(dbg_victim_way),
    .dbg_req_write(dbg_req_write)
  );

  cache_mem_model mem_model (
    .clk(clk),
    .rst_n(rst_n),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write),
    .mem_addr(mem_addr),
    .mem_wline(mem_wline),
    .mem_resp_valid(mem_resp_valid),
    .mem_rline(mem_rline)
  );

  always @(posedge clk) begin
    if (rst_n) begin
      if (dbg_hit) hit_count++;
      if (dbg_miss) miss_count++;
      if (dbg_dirty_evict) dirty_evict_count++;
    end
  end

  initial begin
    $timeformat(-9, 0, " ns", 10);

    hit_count = 0;
    miss_count = 0;
    dirty_evict_count = 0;

    env = new(cpu_if, 100);

    rst_n = 0;
    env.drv.reset_signals();
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    env.run();

    $display("[COV] Hits observed          = %0d", hit_count);
    $display("[COV] Misses observed        = %0d", miss_count);
    $display("[COV] Dirty evictions seen   = %0d", dirty_evict_count);

    if (env.sb.errors == 0) begin
      $display("[TB] ALL TESTS PASSED");
    end else begin
      $fatal(1, "[TB] TEST FAILED");
    end

    $finish;
  end
endmodule
