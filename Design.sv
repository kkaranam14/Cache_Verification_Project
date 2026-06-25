// Summary:
//   This RTL implements a simple blocking 4-way set-associative cache.
//   The cache has 2KB total capacity, 32-byte cache lines, 16 sets, and
//   4 ways per set. It supports one CPU request at a time, write-back,
//   write-allocate, byte writes through write strobes, dirty evictions,
//   and tree-based pseudo-LRU replacement.
//
// Design Organization:
//   1. Parameters, state encoding, and cache storage arrays
//   2. Request registers, address decode, and helper functions
//   3. Hit detection, invalid-way search, and victim selection
//   4. CPU/memory/debug outputs and sequential FSM control
//
// Notes:
//   This is a blocking cache. A new CPU request is accepted only when the cache(state)
//   is in ST_IDLE. Miss handling completes fully before the next request starts.
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module cache_4way (
   // Global clock and active-low reset
  input  logic         clk,
  input  logic         rst_n,
  // CPU-side request/response interface.
  // The CPU issues one 32-bit word read or write request at a time.
  input  logic         cpu_req_valid,
  output logic         cpu_req_ready,
  input  logic         cpu_req_write,
  input  logic [31:0]  cpu_addr,
  input  logic [31:0]  cpu_wdata,
  input  logic [3:0]   cpu_wstrb,

  output logic         cpu_resp_valid,
  output logic [31:0]  cpu_rdata,

  // Memory-side interface.
  // Main memory transfers a complete 256-bit cache line per request.
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
  
  //--------------------------------------------------------------------------
  // Cache Configuration and Address Mapping
  //--------------------------------------------------------------------------
  // Total cache size = SETS * WAYS * LINE_BYTES = 16 * 4 * 32 = 2048 bytes.
  // Address format for this cache:
  //   addr[31:9] = tag
  //   addr[8:5]  = set index
  //   addr[4:0]  = byte offset inside the 32-byte cache line
  //--------------------------------------------------------------------------
  
  
  
  localparam int SETS       = 16;
  localparam int WAYS       = 4;
  localparam int LINE_BYTES = 32;
  localparam int LINE_W     = 256;
  localparam int OFFSET_W   = 5;
  localparam int INDEX_W    = 4;
  localparam int TAG_W      = 23;

  //--------------------------------------------------------------------------
  // State Encoding
  //--------------------------------------------------------------------------
  // ST_IDLE           : Wait for a CPU request.
  // ST_LOOKUP         : Check tags in the selected set and decide hit/miss.
  // ST_WRITEBACK_REQ  : Send dirty victim line write-back request to memory.
  // ST_WRITEBACK_WAIT : Wait for memory write-back completion.
  // ST_REFILL_REQ     : Request the missed line from memory.
  // ST_REFILL_WAIT    : Wait for the refill line and update cache storage.
  // ST_RESP           : Return response to CPU and then go back to idle.
  //--------------------------------------------------------------------------  
  
  localparam logic [2:0]
    ST_IDLE           = 3'd0,
    ST_LOOKUP         = 3'd1,
    ST_WRITEBACK_REQ  = 3'd2,
    ST_WRITEBACK_WAIT = 3'd3,
    ST_REFILL_REQ     = 3'd4,
    ST_REFILL_WAIT    = 3'd5,
    ST_RESP           = 3'd6;

  //--------------------------------------------------------------------------
  // Cache Storage Arrays
  //--------------------------------------------------------------------------
  // data_array  : stores the 256-bit data line for each set and way.
  // tag_array   : stores the tag associated with each valid line.
  // valid_array : tells whether a line contains meaningful cached data.
  // dirty_array : tells whether a line was modified and must be written back.
  //--------------------------------------------------------------------------
  logic [255:0] data_array  [0:SETS-1][0:WAYS-1];
  logic [TAG_W-1:0] tag_array [0:SETS-1][0:WAYS-1];
  logic valid_array [0:SETS-1][0:WAYS-1];
  logic dirty_array [0:SETS-1][0:WAYS-1];

  // 3 bits are enough for tree pseudo-LRU in a 4-way set
  logic [2:0] lru_array [0:SETS-1];

  // Latched request
  // The cache is blocking, so the accepted CPU request is stored here and kept
  // stable while the cache performs lookup, possible write-back, and refill.
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

// Address decode  
// req_index selects one of the 16 sets. The tag is compared against all
// 4 ways in that set. req_line_addr is the cache-line-aligned memory address
// used for refill requests.
  assign req_offset    = req_addr_q[4:0];
  assign req_index     = req_addr_q[8:5];
  assign req_tag       = req_addr_q[31:9];
  assign req_line_addr = {req_addr_q[31:5], 5'b0};

// Helper Function: Select One 32-bit Word from a 256-bit Cache Line
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
  // For a 4-way set, the tree points toward the least-recently-used half and
  // then toward the least-recently-used way inside that half.
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
  // When a way is accessed, the tree bits are updated so that future victim
  // selection prefers the opposite/less recently used path.
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
 // A hit occurs when one valid way in the indexed set has a matching tag.
 // On a miss, the cache first tries to fill an invalid way. If all ways are
 // valid, pseudo-LRU selects a victim way.
  always_comb begin
    hit = 1'b0;
    hit_way = 2'd0;
    invalid_found = 1'b0;
    invalid_way = 2'd0;
   // Search all ways for a valid matching tag.
    for (int w = 0; w < WAYS; w++) begin
      if (valid_array[req_index][w] && tag_array[req_index][w] == req_tag) begin
        hit = 1'b1;
        hit_way = w[1:0];
      end
    end
  // Pick the first invalid way, if any, as the preferred miss target.
    for (int w = 0; w < WAYS; w++) begin
      if (!valid_array[req_index][w] && !invalid_found) begin
        invalid_found = 1'b1;
        invalid_way = w[1:0];
      end
    end
  end

  //--------------------------------------------------------------------------
  // Victim Selection and Refill Data Preparation
  //--------------------------------------------------------------------------
  // Miss victim priority:
  //   1. Use an invalid way if one exists.
  //   2. Otherwise use the pseudo-LRU victim.
  // If the selected victim is valid and dirty, it must be written back before
  // the refill can be installed.
  //--------------------------------------------------------------------------
  
  assign lru_victim_way    = pick_lru_victim(lru_array[req_index]);
  assign victim_way_comb   = invalid_found ? invalid_way : lru_victim_way;
  assign victim_dirty_comb = valid_array[req_index][victim_way_comb] &&
                             dirty_array[req_index][victim_way_comb];
  // For a write miss, the cache uses write-allocate: fetch the full line from
  // memory, merge the CPU write into that line, then install the modified line.
  assign refill_line_final = req_write_q ?
                             merge_word(mem_rline, req_offset, req_wdata_q, req_wstrb_q) :
                             mem_rline;
  assign refill_read_word = get_word(mem_rline, req_offset);
  // CPU, Memory, and Debug Output Logic
  // Outputs are derived from the current FSM state. req_ready is high only in
  // IDLE, and resp_valid is high only when the cached transaction is complete.
  assign cpu_req_ready  = (state_q == ST_IDLE);
  assign cpu_resp_valid = (state_q == ST_RESP);
  assign cpu_rdata      = resp_rdata_q;
  // Memory request is asserted only while issuing a write-back or refill.
  assign mem_req_valid = (state_q == ST_WRITEBACK_REQ) || (state_q == ST_REFILL_REQ);
  assign mem_req_write = (state_q == ST_WRITEBACK_REQ);
    // Write-back uses the victim line address; refill uses the missed line address.
  assign mem_addr      = (state_q == ST_WRITEBACK_REQ) ?
                         {tag_array[req_index][victim_way_q], req_index, 5'b0} :
                         req_line_addr;
  assign mem_wline     = data_array[req_index][victim_way_q];
  // Debug pulses allow the testbench to count whether important paths occurred.
  assign dbg_state       = state_q;
  assign dbg_hit         = (state_q == ST_LOOKUP) && hit;
  assign dbg_miss        = (state_q == ST_LOOKUP) && !hit;
  assign dbg_dirty_evict = (state_q == ST_LOOKUP) && !hit && victim_dirty_comb;
  assign dbg_hit_way     = hit_way;
  assign dbg_victim_way  = (state_q == ST_LOOKUP) ? victim_way_comb : victim_way_q;
  assign dbg_req_write   = req_write_q;

  //--------------------------------------------------------------------------
  // Main Cache FSM and Sequential State Updates
  //--------------------------------------------------------------------------
  // The FSM performs the full cache transaction:
  //   IDLE -> LOOKUP -> RESP                       for hit
  //   IDLE -> LOOKUP -> REFILL -> RESP             for clean miss
  //   IDLE -> LOOKUP -> WRITEBACK -> REFILL -> RESP for dirty miss
  //--------------------------------------------------------------------------  
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q      <= ST_IDLE;
      req_addr_q   <= 32'd0;
      req_write_q  <= 1'b0;
      req_wdata_q  <= 32'd0;
      req_wstrb_q  <= 4'd0;
      victim_way_q <= 2'd0;
      resp_rdata_q <= 32'd0;
      
      // Reset all metadata and data storage so the cache starts empty.
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
          // Accept a new CPU request only when the cache is idle.
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
            // Hit path: update data on writes, return data on reads, and mark
            // the accessed way as recently used.
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
            // Miss path: remember the selected victim. Dirty victims require a
            // write-back before the missed line can be refilled.
            victim_way_q <= victim_way_comb;
            if (victim_dirty_comb)
              state_q <= ST_WRITEBACK_REQ;
            else
              state_q <= ST_REFILL_REQ;
          end
        end

        ST_WRITEBACK_REQ: begin
          // Handshake the write-back request for the dirty victim line.
          if (mem_req_valid && mem_req_ready)
            state_q <= ST_WRITEBACK_WAIT;
        end

        ST_WRITEBACK_WAIT: begin
          // The memory model asserts mem_resp_valid when the write-back is done.
          if (mem_resp_valid) begin
            dirty_array[req_index][victim_way_q] <= 1'b0;
            state_q <= ST_REFILL_REQ;
          end
        end

        ST_REFILL_REQ: begin
          // Request the new cache line from memory using the aligned line address.
          if (mem_req_valid && mem_req_ready)
            state_q <= ST_REFILL_WAIT;
        end

        ST_REFILL_WAIT: begin
           // Install the returned memory line. For a write miss, the pending write
          // has already been merged into refill_line_final.
          if (mem_resp_valid) begin
            data_array[req_index][victim_way_q]  <= refill_line_final;
            tag_array[req_index][victim_way_q]   <= req_tag;
            valid_array[req_index][victim_way_q] <= 1'b1;
            dirty_array[req_index][victim_way_q] <= req_write_q;
            lru_array[req_index] <= update_lru(lru_array[req_index], victim_way_q);
            // Writes return no meaningful read data. Reads return the selected
            // word from the memory refill line.
            resp_rdata_q <= req_write_q ? 32'd0 : refill_read_word;
            state_q <= ST_RESP;
          end
        end

        ST_RESP: begin
          // Response is visible for one cycle, then the cache becomes ready for
          // the next CPU request.
          state_q <= ST_IDLE;
        end

        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end
endmodule
