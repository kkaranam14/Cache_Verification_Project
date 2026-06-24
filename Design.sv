
// 4-way set associative cache
// 2KB cache, 32-byte line, 16 sets, 4 ways
// Blocking cache with write-back and write-allocate
// CPU side: one 32-bit word request at a time
`timescale 1ns/1ps

module cache_4way (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         cpu_req_valid,
  output logic         cpu_req_ready,
  input  logic         cpu_req_write,
  input  logic [31:0]  cpu_addr,
  input  logic [31:0]  cpu_wdata,
  input  logic [3:0]   cpu_wstrb,

  output logic         cpu_resp_valid,
  output logic [31:0]  cpu_rdata,

  // Memory side: one full cache line transfer
  output logic         mem_req_valid,
  input  logic         mem_req_ready,
  output logic         mem_req_write,
  output logic [31:0]  mem_addr,
  output logic [255:0] mem_wline,

  input  logic         mem_resp_valid,
  input  logic [255:0] mem_rline,

  // Debug signals used only by the testbench
  output logic [2:0]   dbg_state,
  output logic         dbg_hit,
  output logic         dbg_miss,
  output logic         dbg_dirty_evict,
  output logic [1:0]   dbg_hit_way,
  output logic [1:0]   dbg_victim_way,
  output logic         dbg_req_write
);

  localparam int SETS       = 16;
  localparam int WAYS       = 4;
  localparam int LINE_BYTES = 32;
  localparam int LINE_W     = 256;
  localparam int OFFSET_W   = 5;
  localparam int INDEX_W    = 4;
  localparam int TAG_W      = 23;

  localparam logic [2:0]
    ST_IDLE           = 3'd0,
    ST_LOOKUP         = 3'd1,
    ST_WRITEBACK_REQ  = 3'd2,
    ST_WRITEBACK_WAIT = 3'd3,
    ST_REFILL_REQ     = 3'd4,
    ST_REFILL_WAIT    = 3'd5,
    ST_RESP           = 3'd6;

  // Cache storage
  logic [255:0] data_array  [0:SETS-1][0:WAYS-1];
  logic [TAG_W-1:0] tag_array [0:SETS-1][0:WAYS-1];
  logic valid_array [0:SETS-1][0:WAYS-1];
  logic dirty_array [0:SETS-1][0:WAYS-1];

  // 3 bits are enough for tree pseudo-LRU in a 4-way set
  logic [2:0] lru_array [0:SETS-1];

  // Latched request
  logic [2:0]  state_q;
  logic [31:0] req_addr_q;
  logic        req_write_q;
  logic [31:0] req_wdata_q;
  logic [3:0]  req_wstrb_q;
  logic [1:0]  victim_way_q;
  logic [31:0] resp_rdata_q;

  logic [22:0] req_tag;
  logic [3:0]  req_index;
  logic [4:0]  req_offset;
  logic [31:0] req_line_addr;

  logic        hit;
  logic [1:0]  hit_way;
  logic        invalid_found;
  logic [1:0]  invalid_way;
  logic [1:0]  lru_victim_way;
  logic [1:0]  victim_way_comb;
  logic        victim_dirty_comb;

  logic [255:0] refill_line_final;
  logic [31:0]  refill_read_word;

  assign req_offset    = req_addr_q[4:0];
  assign req_index     = req_addr_q[8:5];
  assign req_tag       = req_addr_q[31:9];
  assign req_line_addr = {req_addr_q[31:5], 5'b0};

  // Pick one word from a cache line
  function automatic logic [31:0] get_word(input logic [255:0] line,
                                           input logic [4:0] byte_offset);
    int word_idx;
    begin
      word_idx = byte_offset[4:2];
      get_word = line[word_idx*32 +: 32];
    end
  endfunction

  // Update selected bytes inside one word of a cache line
  function automatic logic [255:0] merge_word(input logic [255:0] line,
                                              input logic [4:0] byte_offset,
                                              input logic [31:0] wdata,
                                              input logic [3:0] wstrb);
    logic [255:0] tmp;
    int word_idx;
    int base;
    begin
      tmp = line;
      word_idx = byte_offset[4:2];
      base = word_idx * 32;
      for (int b = 0; b < 4; b++) begin
        if (wstrb[b]) begin
          tmp[base + b*8 +: 8] = wdata[b*8 +: 8];
        end
      end
      merge_word = tmp;
    end
  endfunction

  // Tree pseudo-LRU victim selection
  function automatic logic [1:0] pick_lru_victim(input logic [2:0] lru);
    begin
      if (lru[0] == 1'b0) begin
        pick_lru_victim = (lru[1] == 1'b0) ? 2'd0 : 2'd1;
      end else begin
        pick_lru_victim = (lru[2] == 1'b0) ? 2'd2 : 2'd3;
      end
    end
  endfunction

  // Update pseudo-LRU after touching a way
  function automatic logic [2:0] update_lru(input logic [2:0] old_lru,
                                            input logic [1:0] way);
    logic [2:0] new_lru;
    begin
      new_lru = old_lru;
      case (way)
        2'd0: begin new_lru[0] = 1'b1; new_lru[1] = 1'b1; end
        2'd1: begin new_lru[0] = 1'b1; new_lru[1] = 1'b0; end
        2'd2: begin new_lru[0] = 1'b0; new_lru[2] = 1'b1; end
        2'd3: begin new_lru[0] = 1'b0; new_lru[2] = 1'b0; end
      endcase
      update_lru = new_lru;
    end
  endfunction

  // Hit check and invalid-way search
  always_comb begin
    hit = 1'b0;
    hit_way = 2'd0;
    invalid_found = 1'b0;
    invalid_way = 2'd0;

    for (int w = 0; w < WAYS; w++) begin
      if (valid_array[req_index][w] && tag_array[req_index][w] == req_tag) begin
        hit = 1'b1;
        hit_way = w[1:0];
      end
    end

    for (int w = 0; w < WAYS; w++) begin
      if (!valid_array[req_index][w] && !invalid_found) begin
        invalid_found = 1'b1;
        invalid_way = w[1:0];
      end
    end
  end

  assign lru_victim_way    = pick_lru_victim(lru_array[req_index]);
  assign victim_way_comb   = invalid_found ? invalid_way : lru_victim_way;
  assign victim_dirty_comb = valid_array[req_index][victim_way_comb] &&
                             dirty_array[req_index][victim_way_comb];

  assign refill_line_final = req_write_q ?
                             merge_word(mem_rline, req_offset, req_wdata_q, req_wstrb_q) :
                             mem_rline;
  assign refill_read_word = get_word(mem_rline, req_offset);

  assign cpu_req_ready  = (state_q == ST_IDLE);
  assign cpu_resp_valid = (state_q == ST_RESP);
  assign cpu_rdata      = resp_rdata_q;

  assign mem_req_valid = (state_q == ST_WRITEBACK_REQ) || (state_q == ST_REFILL_REQ);
  assign mem_req_write = (state_q == ST_WRITEBACK_REQ);
  assign mem_addr      = (state_q == ST_WRITEBACK_REQ) ?
                         {tag_array[req_index][victim_way_q], req_index, 5'b0} :
                         req_line_addr;
  assign mem_wline     = data_array[req_index][victim_way_q];

  assign dbg_state       = state_q;
  assign dbg_hit         = (state_q == ST_LOOKUP) && hit;
  assign dbg_miss        = (state_q == ST_LOOKUP) && !hit;
  assign dbg_dirty_evict = (state_q == ST_LOOKUP) && !hit && victim_dirty_comb;
  assign dbg_hit_way     = hit_way;
  assign dbg_victim_way  = (state_q == ST_LOOKUP) ? victim_way_comb : victim_way_q;
  assign dbg_req_write   = req_write_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q      <= ST_IDLE;
      req_addr_q   <= 32'd0;
      req_write_q  <= 1'b0;
      req_wdata_q  <= 32'd0;
      req_wstrb_q  <= 4'd0;
      victim_way_q <= 2'd0;
      resp_rdata_q <= 32'd0;

      for (int s = 0; s < SETS; s++) begin
        lru_array[s] <= 3'd0;
        for (int w = 0; w < WAYS; w++) begin
          valid_array[s][w] <= 1'b0;
          dirty_array[s][w] <= 1'b0;
          tag_array[s][w]   <= '0;
          data_array[s][w]  <= '0;
        end
      end
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (cpu_req_valid && cpu_req_ready) begin
            req_addr_q   <= cpu_addr;
            req_write_q  <= cpu_req_write;
            req_wdata_q  <= cpu_wdata;
            req_wstrb_q  <= cpu_wstrb;
            resp_rdata_q <= 32'd0;
            state_q      <= ST_LOOKUP;
          end
        end

        ST_LOOKUP: begin
          if (hit) begin
            if (req_write_q) begin
              data_array[req_index][hit_way] <= merge_word(data_array[req_index][hit_way],
                                                           req_offset,
                                                           req_wdata_q,
                                                           req_wstrb_q);
              dirty_array[req_index][hit_way] <= 1'b1;
              resp_rdata_q <= 32'd0;
            end else begin
              resp_rdata_q <= get_word(data_array[req_index][hit_way], req_offset);
            end
            lru_array[req_index] <= update_lru(lru_array[req_index], hit_way);
            state_q <= ST_RESP;
          end else begin
            victim_way_q <= victim_way_comb;
            if (victim_dirty_comb)
              state_q <= ST_WRITEBACK_REQ;
            else
              state_q <= ST_REFILL_REQ;
          end
        end

        ST_WRITEBACK_REQ: begin
          if (mem_req_valid && mem_req_ready)
            state_q <= ST_WRITEBACK_WAIT;
        end
        ST_WRITEBACK_WAIT: begin
          if (mem_resp_valid) begin
            dirty_array[req_index][victim_way_q] <= 1'b0;
            state_q <= ST_REFILL_REQ;
          end
        end
        ST_REFILL_REQ: begin
          if (mem_req_valid && mem_req_ready)
            state_q <= ST_REFILL_WAIT;
        end
        ST_REFILL_WAIT: begin
          if (mem_resp_valid) begin
            data_array[req_index][victim_way_q]  <= refill_line_final;
            tag_array[req_index][victim_way_q]   <= req_tag;
            valid_array[req_index][victim_way_q] <= 1'b1;
            dirty_array[req_index][victim_way_q] <= req_write_q;
            lru_array[req_index] <= update_lru(lru_array[req_index], victim_way_q);
            resp_rdata_q <= req_write_q ? 32'd0 : refill_read_word;
            state_q <= ST_RESP;
          end
        end
        ST_RESP: begin
          state_q <= ST_IDLE;
        end
        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end
endmodule
