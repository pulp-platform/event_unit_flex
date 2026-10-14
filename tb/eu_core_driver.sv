// Copyright 2026 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Bus master model of a core on the event unit direct link or on the periph port, with outstanding transactions

module eu_core_driver
#(
  parameter int unsigned CORE_ID         = 0,
  parameter bit          FIXED_LATENCY   = 1'b1,  // 1: r_valid exactly one cycle after gnt (direct link); 0: any latency, in order
  parameter int unsigned MAX_OUTSTANDING = 2      // transactions in flight when two_outstanding_i is 1
)
(
  input  logic clk_i,
  input  logic rst_ni,

  // 1: the next request follows the grant, up to MAX_OUTSTANDING in flight; 0: it follows the response
  input  logic two_outstanding_i,

  XBAR_PERIPH_BUS.Master bus
);

  typedef struct packed {
    logic        wen;
    logic [31:0] add;
    logic [31:0] wdata;
  } op_t;

  op_t         op_q[$];
  logic [31:0] rsp_q[$];

  int unsigned outstanding;
  int unsigned protocol_errors;
  logic        gnt_q;

  // plain copies of the link, since interface signals are not written to the VCD
  logic        link_req, link_gnt, link_wen, link_r_valid;
  logic [31:0] link_add, link_wdata, link_r_rdata;

  assign link_req     = bus.req;
  assign link_gnt     = bus.gnt;
  assign link_wen     = bus.wen;
  assign link_add     = bus.add;
  assign link_wdata   = bus.wdata;
  assign link_r_valid = bus.r_valid;
  assign link_r_rdata = bus.r_rdata;

  assign bus.be = '1;
  assign bus.id = '0;

  // wen is 1 for a read and 0 for a write, as on the PULP peripheral bus
  function automatic void read(input logic [31:0] add);
    op_q.push_back('{wen: 1'b1, add: add, wdata: '0});
  endfunction

  function automatic void write(input logic [31:0] add, input logic [31:0] wdata);
    op_q.push_back('{wen: 1'b0, add: add, wdata: wdata});
  endfunction

  function automatic int unsigned nb_rsp();
    return rsp_q.size();
  endfunction

  task automatic get_rsp(input int unsigned timeout, output bit ok, output logic [31:0] rdata);
    int unsigned cycles = 0;
    while ((rsp_q.size() == 0) && (cycles < timeout)) begin
      @(posedge clk_i);
      cycles++;
    end
    ok    = (rsp_q.size() != 0);
    rdata = '0;
    if (ok) rdata = rsp_q.pop_front();
  endtask

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bus.req     <= 1'b0;
      bus.add     <= '0;
      bus.wen     <= 1'b1;
      bus.wdata   <= '0;
      gnt_q       <= 1'b0;
      outstanding  = 0;
      op_q.delete();
      rsp_q.delete();
    end else begin
      automatic bit granted = bus.req && bus.gnt;

      gnt_q <= granted;

      // on the direct link the response comes exactly one cycle after the grant
      if (FIXED_LATENCY && (bus.r_valid != gnt_q)) begin
        protocol_errors++;
        $display("[%0t] ERROR core %0d: r_valid=%0b one cycle after gnt=%0b",
                 $time, CORE_ID, bus.r_valid, gnt_q);
      end

      if (bus.r_valid) begin
        rsp_q.push_back(bus.r_rdata);
        outstanding--;
      end
      if (granted) outstanding++;

      if (granted || !bus.req) begin
        if ((op_q.size() != 0) && (two_outstanding_i ? (outstanding < MAX_OUTSTANDING) : (outstanding == 0))) begin
          automatic op_t op = op_q.pop_front();
          bus.req   <= 1'b1;
          bus.add   <= op.add;
          bus.wen   <= op.wen;
          bus.wdata <= op.wdata;
        end else begin
          bus.req   <= 1'b0;
        end
      end
    end
  end

  initial protocol_errors = 0;

endmodule // eu_core_driver
