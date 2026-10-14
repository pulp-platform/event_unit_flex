// Copyright 2026 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Rules of doc/event_unit_flex_behavior.md checked inside every event_unit_core (bound by the testbench)

module eu_core_checker #(
  parameter int unsigned NB_SW_EVT = 8,
  parameter int unsigned NB_BARR   = 4,
  parameter int unsigned NB_HW_MUT = 1
) (
  input logic                 clk_i,
  input logic                 rst_ni,

  // direct link grant and the response cycle of a clearing read
  input logic                 p_demux_gnt,
  input logic                 wait_clear_access_SP,

  // effects of direct-link writes
  input logic [3:0]           we_demux,
  input logic                 dispatch_w_req_o,
  input logic [NB_HW_MUT-1:0] mutex_wr_req_o,
  input logic [NB_SW_EVT-1:0] sw_events_reg,

  // effects of trigger reads
  input logic [NB_HW_MUT-1:0] mutex_rd_req_o,
  input logic                 dispatch_pop_req_o,
  input logic [NB_BARR-1:0]   hw_barr_id_o,
  input logic [NB_SW_EVT-1:0] sw_events_wait,

  input logic [31:0]          master_event_lines_i,
  input logic [31:0]          event_buffer_DP
);

  import eu_tb_pkg::*;

  // P2: a direct-link write takes effect only in the cycle it is granted
  a_write_needs_grant: assert property (@(posedge clk_i) disable iff (!rst_ni)
    ((we_demux != '0) || dispatch_w_req_o || (mutex_wr_req_o != '0) || (sw_events_reg != '0)) |-> p_demux_gnt)
    else assert_fail("P2", $sformatf("%m: a direct-link write takes effect without grant"));

  // P2: a trigger read (mutex lock, dispatcher pop, barrier, sw event) does nothing in the cycle where requests are refused
  a_trigger_not_refused: assert property (@(posedge clk_i) disable iff (!rst_ni)
    ((mutex_rd_req_o != '0) || dispatch_pop_req_o || (hw_barr_id_o != '0) || (sw_events_wait != '0)) |-> !wait_clear_access_SP)
    else assert_fail("P2", $sformatf("%m: a trigger read fires in the response cycle of a clearing read"));

  // E2: every clear of a clearing read answers a read granted in the cycle before
  a_clear_answers_read: assert property (@(posedge clk_i) disable iff (!rst_ni)
    wait_clear_access_SP |-> $past(p_demux_gnt))
    else assert_fail("E2", $sformatf("%m: buffer cleared without a granted read (no response)"));

  // E1: an event line active in a cycle is in the buffer in the next cycle, whatever is cleared in that cycle
  a_event_kept: assert property (@(posedge clk_i) disable iff (!rst_ni)
    (master_event_lines_i != '0) |=> ((event_buffer_DP & $past(master_event_lines_i)) == $past(master_event_lines_i)))
    else assert_fail("E1", $sformatf("%m: event 0x%08x lost in the cycle it arrived", $past(master_event_lines_i) & ~$sampled(event_buffer_DP)));

endmodule
