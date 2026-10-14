// Copyright 2026 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Self-checking testbench of event_unit_top for the rules of doc/event_unit_flex_behavior.md

`timescale 1ns/1ps

module tb_event_unit;

/*******************************************************/
/**              Configuration Beginning              **/
/*******************************************************/

  localparam int unsigned NB_CORES   = 4;
  localparam int unsigned NB_BARR    = 4;
  localparam int unsigned NB_SW_EVT  = 8;     // event_unit_top default
  localparam int unsigned NB_HW_MUT  = 2;     // one more than the runtimes use, to check that mutexes are independent
  localparam int unsigned SOC_DEPTH  = 8;     // event_unit_top default SOC_FIFO_DEPTH
  localparam int unsigned DISP_DEPTH = 8;     // event_unit_top default DISP_FIFO_DEPTH
  localparam time         CLK_PERIOD = 10ns;
  localparam int unsigned TIMEOUT    = 40;    // cycles before a blocking read counts as hung
  localparam int unsigned RND_HANG   = 3000;  // the same in the random test, where a core may wait for a mutex

  // core unit registers: direct link offsets, at PER_CORE_STRIDE * core on the periph port
  localparam logic [31:0] EU_MASK              = 32'h000;
  localparam logic [31:0] EU_MASK_AND          = 32'h004;
  localparam logic [31:0] EU_MASK_OR           = 32'h008;
  localparam logic [31:0] EU_IRQ_MASK          = 32'h00C;
  localparam logic [31:0] EU_IRQ_MASK_AND      = 32'h010;
  localparam logic [31:0] EU_IRQ_MASK_OR       = 32'h014;
  localparam logic [31:0] EU_STATUS            = 32'h018;
  localparam logic [31:0] EU_BUFFER            = 32'h01C;
  localparam logic [31:0] EU_BUFFER_MASKED     = 32'h020;
  localparam logic [31:0] EU_BUFFER_IRQ_MASKED = 32'h024;
  localparam logic [31:0] EU_BUFFER_CLEAR      = 32'h028;
  localparam logic [31:0] EU_SW_EVT_MASK       = 32'h02C;
  localparam logic [31:0] EU_SW_EVT_MASK_AND   = 32'h030;
  localparam logic [31:0] EU_SW_EVT_MASK_OR    = 32'h034;
  localparam logic [31:0] EU_WAIT              = 32'h038;
  localparam logic [31:0] EU_WAIT_CLEAR        = 32'h03C;

  // direct link only; mutex m, software event j and barrier b at +4m, +4j and +BARR_STRIDE*b
  localparam logic [31:0] EU_DISP_FIFO         = 32'h080;
  localparam logic [31:0] EU_DISP_TEAM         = 32'h084;
  localparam logic [31:0] EU_MUTEX             = 32'h0C0;
  localparam logic [31:0] EU_MUTEX1            = EU_MUTEX + 32'h4;
  localparam logic [31:0] EU_SW_EVT_TRIG       = 32'h100;
  localparam logic [31:0] EU_SW_EVT_WAIT       = 32'h140;
  localparam logic [31:0] EU_SW_EVT_WAIT_CLEAR = 32'h180;
  localparam logic [31:0] EU_BARR0             = 32'h200;

  // barrier unit registers
  localparam logic [31:0] BARR_TRIG_MASK       = 32'h00;
  localparam logic [31:0] BARR_STATUS          = 32'h04;
  localparam logic [31:0] BARR_TGT_MASK        = 32'h0C;
  localparam logic [31:0] BARR_TRIGGER         = 32'h10;
  localparam logic [31:0] BARR_TRIG_SELF       = 32'h14;
  localparam logic [31:0] BARR_TRIG_WAIT       = 32'h18;
  localparam logic [31:0] BARR_TRIG_WAIT_CLEAR = 32'h1C;
  localparam logic [31:0] BARR_STRIDE          = 32'h20;

  // periph port ranges
  localparam logic [31:0] PER_CORE_STRIDE      = 32'h040;
  localparam logic [31:0] PER_BARR0            = 32'h400;
  localparam logic [31:0] PER_SW_EVT_TRIG      = 32'h600;
  localparam logic [31:0] PER_SOC_EVENT        = 32'h700;  // eu_core_current_event
  localparam logic [31:0] PER_INTERCLUSTER     = 32'h780;  // eu_cluster_message_base_addr, no unit behind it

  // event buffer bits, as mapped by cluster_event_map
  localparam int unsigned EVT_CLUSTER_LSB = 22;
  localparam logic [31:0] EVT_SW0   = 32'h1 << 0;
  localparam logic [31:0] EVT_BARR  = 32'h1 << 16;
  localparam logic [31:0] EVT_MUTEX = 32'h1 << 17;
  localparam logic [31:0] EVT_DISP  = 32'h1 << 18;
  localparam logic [31:0] EVT_A     = 32'h1 << EVT_CLUSTER_LSB;        // cluster_events_i[0]
  localparam logic [31:0] EVT_B     = 32'h1 << (EVT_CLUSTER_LSB + 1);  // cluster_events_i[1]
  localparam logic [31:0] EVT_SOC   = 32'h1 << 27;                     // SoC peripheral event FIFO not empty

/*******************************************************/
/**                 Configuration End                 **/
/*******************************************************/
/**                 Signals Beginning                 **/
/*******************************************************/

  logic clk, rst_n;
  logic two_outstanding;

  logic [NB_CORES-1:0][31:0] cluster_events;
  logic [NB_CORES-1:0]       core_clock_en;

  // the testbench acks interrupts like a core would
  logic [NB_CORES-1:0]       irq_req, irq_ack;
  logic [NB_CORES-1:0][4:0]  irq_id, irq_ack_id;

  logic [NB_CORES-1:0]       core_busy, dbg_req, core_dbg_req;
  logic [NB_CORES-1:0][3:0]  acc_events;
  logic [NB_CORES-1:0][1:0]  dma_events, timer_events;

  logic                      soc_valid, soc_ready;
  logic [7:0]                soc_data;

  // copies of the direct links, indexable with a variable core and visible in the VCD
  logic [NB_CORES-1:0]       link_req, link_gnt, link_wen, link_r_valid;
  logic [NB_CORES-1:0][31:0] link_add, link_wdata, link_r_rdata;

  int unsigned test_id;      // to find the running test in the waveform
  string       test_name;
  int unsigned nb_fail, nb_pass, nb_known;
  int unsigned assert_base;  // assertion failures before the running test
  int          results_fd;

  XBAR_PERIPH_BUS #(.ID_WIDTH(NB_CORES+1)) speriph();
  XBAR_PERIPH_BUS #(.ID_WIDTH(NB_CORES+1)) eu_direct_link[NB_CORES-1:0]();

/*******************************************************/
/**                    Signals End                    **/
/*******************************************************/
/**             DUT and Masters Beginning             **/
/*******************************************************/

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  // its input FIFO adds latency (any, in order); four in flight fill that FIFO on a stall
  eu_core_driver #(
    .CORE_ID         ( NB_CORES ),
    .FIXED_LATENCY   ( 1'b0     ),
    .MAX_OUTSTANDING ( 4        )
  ) periph_i (
    .clk_i             ( clk             ),
    .rst_ni            ( rst_n           ),
    .two_outstanding_i ( two_outstanding ),
    .bus               ( speriph         )
  );

  event_unit_top #(
    .NB_CORES     ( NB_CORES   ),
    .NB_BARR      ( NB_BARR    ),
    .NB_HW_MUT    ( NB_HW_MUT  ),
    .PER_ID_WIDTH ( NB_CORES+1 )
  ) dut_i (
    .clk_i                  ( clk            ),
    .rst_ni                 ( rst_n          ),
    .test_mode_i            ( 1'b0           ),
    .acc_events_i           ( acc_events     ),
    .dma_events_i           ( dma_events     ),
    .timer_events_i         ( timer_events   ),
    .cluster_events_i       ( cluster_events ),
    .core_irq_req_o         ( irq_req        ),
    .core_irq_id_o          ( irq_id         ),
    .core_irq_ack_i         ( irq_ack        ),
    .core_irq_ack_id_i      ( irq_ack_id     ),
    .core_busy_i            ( core_busy      ),
    .core_clock_en_o        ( core_clock_en  ),
    .dbg_req_i              ( dbg_req        ),
    .core_dbg_req_o         ( core_dbg_req   ),
    .soc_periph_evt_valid_i ( soc_valid      ),
    .soc_periph_evt_ready_o ( soc_ready      ),
    .soc_periph_evt_data_i  ( soc_data       ),
    .speriph_slave          ( speriph        ),
    .eu_direct_link         ( eu_direct_link )
  );

  for (genvar I = 0; I < NB_CORES; I++) begin : CORE
    eu_core_driver #(
      .CORE_ID ( I )
    ) driver_i (
      .clk_i             ( clk               ),
      .rst_ni            ( rst_n             ),
      .two_outstanding_i ( two_outstanding   ),
      .bus               ( eu_direct_link[I] )
    );

    assign link_req[I]     = eu_direct_link[I].req;
    assign link_gnt[I]     = eu_direct_link[I].gnt;
    assign link_add[I]     = eu_direct_link[I].add;
    assign link_wen[I]     = eu_direct_link[I].wen;
    assign link_wdata[I]   = eu_direct_link[I].wdata;
    assign link_r_valid[I] = eu_direct_link[I].r_valid;
    assign link_r_rdata[I] = eu_direct_link[I].r_rdata;
  end

  bind event_unit_core eu_core_checker #(
    .NB_SW_EVT ( NB_SW_EVT ),
    .NB_BARR   ( NB_BARR   ),
    .NB_HW_MUT ( NB_HW_MUT )
  ) checker_i (.*);

/*******************************************************/
/**                DUT and Masters End                **/
/*******************************************************/
/**                 Helpers Beginning                 **/
/*******************************************************/

  // generate scopes need a constant index, hence one case item per core
  task automatic core_read(input int unsigned core, input logic [31:0] add);
    case (core)
      0:       CORE[0].driver_i.read(add);
      1:       CORE[1].driver_i.read(add);
      2:       CORE[2].driver_i.read(add);
      3:       CORE[3].driver_i.read(add);
      default: $fatal(1, "no core %0d", core);
    endcase
  endtask

  task automatic core_write(input int unsigned core, input logic [31:0] add, input logic [31:0] wdata);
    case (core)
      0:       CORE[0].driver_i.write(add, wdata);
      1:       CORE[1].driver_i.write(add, wdata);
      2:       CORE[2].driver_i.write(add, wdata);
      3:       CORE[3].driver_i.write(add, wdata);
      default: $fatal(1, "no core %0d", core);
    endcase
  endtask

  // ok is 0 when no response arrives within timeout cycles
  task automatic core_get_rsp(input int unsigned core, output bit ok, output logic [31:0] rdata,
                              input int unsigned timeout = TIMEOUT);
    case (core)
      0:       CORE[0].driver_i.get_rsp(timeout, ok, rdata);
      1:       CORE[1].driver_i.get_rsp(timeout, ok, rdata);
      2:       CORE[2].driver_i.get_rsp(timeout, ok, rdata);
      3:       CORE[3].driver_i.get_rsp(timeout, ok, rdata);
      default: $fatal(1, "no core %0d", core);
    endcase
  endtask

  // responses received and not consumed yet
  function automatic int unsigned core_nb_rsp(input int unsigned core);
    case (core)
      0:       return CORE[0].driver_i.nb_rsp();
      1:       return CORE[1].driver_i.nb_rsp();
      2:       return CORE[2].driver_i.nb_rsp();
      3:       return CORE[3].driver_i.nb_rsp();
      default: $fatal(1, "no core %0d", core);
    endcase
    return 0;
  endfunction

  task automatic core_setup(input int unsigned core, input logic [31:0] add, input logic [31:0] wdata);
    bit          ok;
    logic [31:0] rdata;
    core_write(core, add, wdata);
    core_get_rsp(core, ok, rdata);
  endtask

  task automatic wait_cycles(input int unsigned n);
    repeat (n) @(posedge clk);
  endtask

  // one-cycle pulse on the cluster event lines of a core, visible in the cycle after the call
  task automatic pulse_event(input int unsigned core, input logic [31:0] evt);
    cluster_events[core] <= evt >> EVT_CLUSTER_LSB;
    @(posedge clk);
    cluster_events[core] <= '0;
  endtask

  // returns a few cycles after the clock of the core is gated, so that the core is surely asleep
  task automatic wait_sleep(input int unsigned core);
    int unsigned cycles = 0;
    do begin
      @(posedge clk);
      cycles++;
    end while (core_clock_en[core] && (cycles < TIMEOUT));
    wait_cycles(3);
  endtask

  // returns at the clock edge that ends the grant cycle of the access
  task automatic wait_grant(input int unsigned core, input logic [31:0] add);
    do @(posedge clk); while (!(link_req[core] && link_gnt[core] && (link_add[core] == add)));
  endtask

  task automatic irq_ack_pulse(input int unsigned core, input logic [4:0] ack_id);
    irq_ack[core]    <= 1'b1;
    irq_ack_id[core] <= ack_id;
    @(posedge clk);
    irq_ack[core]    <= 1'b0;
    wait_cycles(3);
  endtask

  // driven on falling edges: Verilator does not order two NBAs of valid in one time step
  task automatic soc_push(input logic [7:0] evt_id);
    @(negedge clk);
    soc_valid = 1'b1;
    soc_data  = evt_id;
    while (!soc_ready) @(negedge clk);
    @(negedge clk);
    soc_valid = 1'b0;
  endtask

  task automatic reset_dut();
    rst_n          = 1'b0;
    cluster_events = '0;
    irq_ack        = '0;
    irq_ack_id     = '0;
    core_busy      = '0;
    dbg_req        = '0;
    acc_events     = '0;
    dma_events     = '0;
    timer_events   = '0;
    soc_valid      = 1'b0;
    soc_data       = '0;
    wait_cycles(3);
    rst_n          <= 1'b1;
    wait_cycles(2);
  endtask

  task automatic start_test(input int unsigned id, input bit two_out);
    test_id         = id;
    two_outstanding = two_out;
    reset_dut();
    assert_base     = eu_tb_pkg::assert_errors;
  endtask

  task automatic finish(input string status, input string why);
    $display("[%0t] %-5s T%0d %s%s", $time, status, test_id, test_name, why == "" ? "" : {": ", why});
    if (results_fd != 0) $fdisplay(results_fd, "%-5s T%0d %s%s", status, test_id, test_name, why == "" ? "" : {" : ", why});
    wait_cycles(4);
  endtask

  // a test whose own checks pass still fails if an assertion of eu_core_checker fired while it ran
  task automatic report(input bit ok, input string why);
    int unsigned nb_assert = eu_tb_pkg::assert_errors - assert_base;
    if (ok && (nb_assert != 0)) begin
      ok  = 1'b0;
      why = $sformatf("%0d assertion failure(s), first %s", nb_assert, eu_tb_pkg::assert_first);
    end
    if (ok) nb_pass++; else nb_fail++;
    finish(ok ? "PASS" : "FAIL", ok ? "" : why);
    eu_tb_pkg::assert_first = "";
  endtask

  // a documented limitation of the design: reported, not counted as a failure
  task automatic report_known(input bit ok, input string why);
    if (ok || (eu_tb_pkg::assert_errors != assert_base)) report(ok, why);
    else begin nb_known++; finish("KNOWN", why); end
  endtask

  // keeps only the first failure, so that later checks do not hide it
  function automatic void expect_true(inout string why, input bit cond, input string msg);
    if ((why == "") && !cond) why = msg;
  endfunction

  // with periph, the response of the periph master instead of the core
  task automatic expect_rsp(inout string why, input bit periph, input int unsigned core, input logic [31:0] exp,
                            input string what);
    bit          ok;
    logic [31:0] r;
    if (periph) periph_i.get_rsp(TIMEOUT, ok, r); else core_get_rsp(core, ok, r);
    expect_true(why, ok, $sformatf("%s: no response", what));
    expect_true(why, r == exp, $sformatf("%s returned 0x%08x, expected 0x%08x", what, r, exp));
  endtask

  task automatic expect_rd(inout string why, input bit periph, input int unsigned core, input logic [31:0] add,
                           input logic [31:0] exp, input string what);
    if (periph) periph_i.read(add); else core_read(core, add);
    expect_rsp(why, periph, core, exp, what);
  endtask

  task automatic reg_wr(input bit periph, input int unsigned core, input logic [31:0] add, input logic [31:0] wdata);
    bit          ok;
    logic [31:0] r;
    if (periph) begin periph_i.write(add, wdata); periph_i.get_rsp(TIMEOUT, ok, r); end
    else core_setup(core, add, wdata);
  endtask

  task automatic clear_buffers();
    for (int unsigned c = 0; c < NB_CORES; c++) core_setup(c, EU_BUFFER_CLEAR, '1);
  endtask

  // exp is unpacked, so that '{...} lists the cores from 0
  task automatic expect_buffers(inout string why, input logic [31:0] exp[NB_CORES], input string what);
    for (int unsigned c = 0; c < NB_CORES; c++)
      expect_rd(why, 1'b0, c, EU_BUFFER, exp[c], $sformatf("core %0d buffer after %s", c, what));
  endtask

/*******************************************************/
/**                    Helpers End                    **/
/*******************************************************/
/**              Protocol Tests Beginning             **/
/*******************************************************/

  // T1/T11: the reference for the protocol with two outstanding transactions
  task automatic test_plain_accesses(input int unsigned id, input bit two_out);
    bit          ok;
    logic [31:0] r;
    bit          all_ok = 1'b1;
    start_test(id, two_out);
    for (int unsigned i = 0; i < 4; i++) begin
      core_write(0, EU_MASK, 32'h0000_0100 << i);
      core_read (0, EU_MASK);
    end
    for (int unsigned i = 0; i < 4; i++) begin
      core_get_rsp(0, ok, r);
      core_get_rsp(0, ok, r);
      if (!ok || (r != (32'h0000_0100 << i))) all_ok = 1'b0;
    end
    report(all_ok, $sformatf("mask read back 0x%08x", r));
  endtask

  // T2/T12: an event that arrives in c1 of a _wait_clear must be returned by the next one
  task automatic test_event_in_clear_cycle(input int unsigned id, input bit two_out);
    bit          ok1, ok2;
    logic [31:0] r1, r2;
    start_test(id, two_out);
    core_setup(0, EU_MASK, EVT_A | EVT_B);
    core_read(0, EU_WAIT_CLEAR);
    wait_sleep(0);
    pulse_event(0, EVT_A);
    wait_grant(0, EU_WAIT_CLEAR);
    pulse_event(0, EVT_B);
    core_get_rsp(0, ok1, r1);
    core_read(0, EU_WAIT_CLEAR);
    core_get_rsp(0, ok2, r2);
    if (!ok1 || (r1 != EVT_A)) report(1'b0, $sformatf("first read returned 0x%08x", r1));
    else if (!ok2)             report(1'b0, "event B lost, core 0 sleeps forever");
    else                       report(r2 == EVT_B, $sformatf("second read returned 0x%08x", r2));
  endtask

  // T3/T13: a dispatcher push presented right after a _wait_clear pushes one value
  task automatic test_clear_then_push(input int unsigned id, input bit two_out);
    bit          ok, ok1, ok2;
    logic [31:0] r, r1, r2;
    start_test(id, two_out);
    core_setup(0, EU_MASK, EVT_A);
    core_setup(1, EU_MASK, EVT_DISP);
    core_setup(0, EU_DISP_TEAM, 32'h2);
    core_read (0, EU_WAIT_CLEAR);
    core_write(0, EU_DISP_FIFO, 32'hCAFE_0001);
    wait_sleep(0);
    pulse_event(0, EVT_A);
    core_get_rsp(0, ok, r);
    core_get_rsp(0, ok, r);
    core_read(1, EU_DISP_FIFO);
    core_get_rsp(1, ok1, r1);
    core_read(1, EU_DISP_FIFO);
    core_get_rsp(1, ok2, r2);
    if (!ok1 || (r1 != 32'hCAFE_0001)) report(1'b0, $sformatf("pop returned 0x%08x", r1));
    else report(!ok2, $sformatf("value pushed twice, second pop returned 0x%08x", r2));
  endtask

  // T4/T14: a mutex unlock presented right after a _wait_clear hands the mutex to one waiting core
  task automatic test_clear_then_unlock(input int unsigned id, input bit two_out);
    bit          ok;
    logic [31:0] r;
    start_test(id, two_out);
    core_setup(0, EU_MASK, EVT_A | EVT_MUTEX);
    core_setup(1, EU_MASK, EVT_MUTEX);
    core_setup(2, EU_MASK, EVT_MUTEX);
    core_read(0, EU_MUTEX);
    core_get_rsp(0, ok, r);
    core_read(1, EU_MUTEX);
    wait_cycles(3);
    core_read(2, EU_MUTEX);
    wait_cycles(3);
    core_read (0, EU_WAIT_CLEAR);
    core_write(0, EU_MUTEX, 32'h0000_0011);
    wait_sleep(0);
    pulse_event(0, EVT_A);
    wait_cycles(TIMEOUT);
    if (!ok || (core_nb_rsp(1) != 1)) report(1'b0, "core 1 did not get the mutex");
    else report(core_nb_rsp(2) == 0, "unlocked twice, cores 1 and 2 both own the mutex");
  endtask

  // T5/T15: a mutex lock presented right after a _wait_clear returns
  task automatic test_clear_then_lock(input int unsigned id, input bit two_out);
    bit          ok1, ok2;
    logic [31:0] r1, r2;
    start_test(id, two_out);
    core_setup(0, EU_MASK, EVT_A | EVT_MUTEX);
    core_read(0, EU_WAIT_CLEAR);
    core_read(0, EU_MUTEX);
    wait_sleep(0);
    pulse_event(0, EVT_A);
    core_get_rsp(0, ok1, r1);
    core_get_rsp(0, ok2, r2);
    if (!ok1 || (r1 != EVT_A)) report(1'b0, $sformatf("first read returned 0x%08x", r1));
    else report(ok2, "mutex event cleared without a response, core 0 sleeps forever");
  endtask

  // T6/T16: a barrier wait presented right after a _wait_clear returns once the barrier is complete
  task automatic test_clear_then_barrier(input int unsigned id, input bit two_out);
    bit          ok1, ok2;
    logic [31:0] r1, r2;
    start_test(id, two_out);
    core_setup(0, EU_MASK, EVT_A | EVT_BARR);
    core_setup(0, EU_BARR0 + BARR_TRIG_MASK, 32'h1);
    core_setup(0, EU_BARR0 + BARR_TGT_MASK, 32'h1);
    core_read(0, EU_WAIT_CLEAR);
    core_read(0, EU_BARR0 + BARR_TRIG_WAIT_CLEAR);
    wait_sleep(0);
    pulse_event(0, EVT_A);
    core_get_rsp(0, ok1, r1);
    core_get_rsp(0, ok2, r2);
    if (!ok1 || (r1 != EVT_A)) report(1'b0, $sformatf("first read returned 0x%08x", r1));
    else if (!ok2)             report(1'b0, "barrier event lost, core 0 sleeps forever");
    else                       report(r2 == EVT_BARR, $sformatf("barrier read returned 0x%08x", r2));
  endtask

  // T7/T17: a dispatcher push presented right after a _wait pushes one value
  task automatic test_wait_then_push(input int unsigned id, input bit two_out);
    bit          ok, ok1, ok2;
    logic [31:0] r, r1, r2;
    start_test(id, two_out);
    core_setup(0, EU_MASK, EVT_A);
    core_setup(1, EU_MASK, EVT_DISP);
    core_setup(0, EU_DISP_TEAM, 32'h2);
    core_read (0, EU_WAIT);
    core_write(0, EU_DISP_FIFO, 32'hCAFE_0007);
    wait_sleep(0);
    pulse_event(0, EVT_A);
    core_get_rsp(0, ok, r);
    core_get_rsp(0, ok, r);
    core_read(1, EU_DISP_FIFO);
    core_get_rsp(1, ok1, r1);
    core_read(1, EU_DISP_FIFO);
    core_get_rsp(1, ok2, r2);
    if (!ok1 || (r1 != 32'hCAFE_0007)) report(1'b0, $sformatf("pop returned 0x%08x", r1));
    else report(!ok2, $sformatf("value pushed twice, second pop returned 0x%08x", r2));
  endtask

  // an 'x in exp marks a write response, whose data is not checked
  task automatic check_reads(input logic [31:0] exp[$], input bit periph);
    bit          ok;
    logic [31:0] r;
    string       why = "";
    foreach (exp[k]) begin
      if (periph) periph_i.get_rsp(TIMEOUT, ok, r); else core_get_rsp(0, ok, r);
      if (!ok) begin why = $sformatf("response %0d missing", k); break; end
      if ((exp[k] !== 'x) && (r !== exp[k]) && (why == ""))
        why = $sformatf("response %0d is 0x%08x, expected 0x%08x", k, r, exp[k]);
    end
    report(why == "", why);
  endtask

  // T8/T18: core unit and barrier unit accesses back to back on the direct link, read data in order
  task automatic test_core_barrier_mix(input int unsigned id, input bit two_out);
    logic [31:0] exp[$];
    start_test(id, two_out);
    core_write(0, EU_MASK,                   32'h00F0_0000); exp.push_back('x);
    core_write(0, EU_BARR0 + BARR_TRIG_MASK, 32'h5);         exp.push_back('x);
    core_read (0, EU_BARR0 + BARR_TRIG_MASK);                exp.push_back(32'h5);
    core_read (0, EU_MASK);                                  exp.push_back(32'h00F0_0000);
    core_write(0, EU_BARR0 + BARR_TGT_MASK,  32'h3);         exp.push_back('x);
    core_read (0, EU_BARR0 + BARR_TGT_MASK);                 exp.push_back(32'h3);
    core_write(0, EU_MASK_OR,                32'h1);         exp.push_back('x);
    core_read (0, EU_MASK);                                  exp.push_back(32'h00F0_0001);
    core_read (0, EU_BARR0 + BARR_STATUS);                   exp.push_back(32'h0);
    core_read (0, EU_BARR0 + BARR_TRIG_MASK);                exp.push_back(32'h5);
    check_reads(exp, 1'b0);
  endtask

  // T9/T19: core 0, core 1 and barrier accesses back to back on the periph port, read data in order
  task automatic test_periph_mix(input int unsigned id, input bit two_out);
    logic [31:0] exp[$];
    start_test(id, two_out);
    periph_i.write(EU_MASK,                     32'h11); exp.push_back('x);
    periph_i.read (PER_CORE_STRIDE + EU_MASK);           exp.push_back(32'h0);
    periph_i.write(PER_CORE_STRIDE + EU_MASK,   32'h22); exp.push_back('x);
    periph_i.read (EU_MASK);                             exp.push_back(32'h11);
    periph_i.read (PER_CORE_STRIDE + EU_MASK);           exp.push_back(32'h22);
    periph_i.write(PER_BARR0 + BARR_TRIG_MASK,  32'h6);  exp.push_back('x);
    periph_i.read (PER_BARR0 + BARR_TRIG_MASK);          exp.push_back(32'h6);
    periph_i.read (EU_MASK);                             exp.push_back(32'h11);
    periph_i.read (PER_BARR0 + BARR_STATUS);             exp.push_back(32'h0);
    periph_i.read (PER_CORE_STRIDE + EU_MASK);           exp.push_back(32'h22);
    check_reads(exp, 1'b1);
  endtask

  // periph writes refused for a direct-link write, and periph writes decoded in a cycle without periph grant
  int unsigned n_conflict, n_refused_decoded;
  always @(posedge clk) if (rst_n) begin
    if (dut_i.EU_CORE[0].event_unit_core_i.write_conflict) n_conflict++;
    if ((dut_i.EU_CORE[0].event_unit_core_i.we_interc != '0) && !dut_i.EU_CORE[0].event_unit_core_i.p_interc_gnt)
      n_refused_decoded++;
  end

  // T21/T22: periph and direct-link OR writes to core 0's unit in the same cycles; OR commutes, so any order is right
  task automatic test_write_conflict(input int unsigned id, input bit two_out);
    bit          ok;
    logic [31:0] r;
    start_test(id, two_out);
    n_conflict = 0; n_refused_decoded = 0;
    for (int unsigned k = 0; k < 8; k++) begin
      core_write(0, EU_MASK_OR, 32'h1 << k);
      periph_i.write(EU_MASK_OR, 32'h1 << (16 + k));
    end
    for (int unsigned k = 0; k < 8; k++) begin core_get_rsp(0, ok, r); periph_i.get_rsp(TIMEOUT, ok, r); end
    core_read(0, EU_MASK); core_get_rsp(0, ok, r);
    $display("[%0t] INFO  T%0d write_conflict: %0d conflict cycles, %0d periph writes decoded without grant",
             $time, id, n_conflict, n_refused_decoded);
    if (n_conflict == 0) report(1'b0, "no conflict happened: the test did not exercise the case");
    else report(r == 32'h00FF_00FF, $sformatf("final mask 0x%08x, expected 0x00ff00ff", r));
  endtask

  // T23: an interrupt ack in the cycle the same event fires again keeps the new occurrence
  task automatic test_irq_ack_new_event(input int unsigned id);
    bit          ok;
    logic [31:0] r;
    int unsigned cycles = 0;
    start_test(id, 1'b0);
    core_setup(0, EU_IRQ_MASK, EVT_A);
    pulse_event(0, EVT_A);
    while (!irq_req[0] && cycles < TIMEOUT) begin @(posedge clk); cycles++; end
    irq_ack[0]        <= 1'b1;
    irq_ack_id[0]     <= irq_id[0];
    cluster_events[0] <= EVT_A >> EVT_CLUSTER_LSB;
    @(posedge clk);
    irq_ack[0]        <= 1'b0;
    cluster_events[0] <= '0;
    wait_cycles(3);
    core_read(0, EU_BUFFER); core_get_rsp(0, ok, r);
    report(ok && ((r & EVT_A) != '0) && irq_req[0],
           $sformatf("second A lost: buffer 0x%08x, irq_req %0b after the ack", r, irq_req[0]));
  endtask

  // T24: a plain lw on _wait_clear with an interrupt: without p.elw nothing replays the wait
  task automatic test_irq_during_wait(input int unsigned id);
    bit          ok;
    logic [31:0] r;
    start_test(id, 1'b0);
    core_setup(0, EU_MASK, EVT_B);
    core_setup(0, EU_IRQ_MASK, EVT_A);
    core_read(0, EU_WAIT_CLEAR);
    wait_sleep(0);
    pulse_event(0, EVT_A);
    core_get_rsp(0, ok, r);
    irq_ack_pulse(0, irq_id[0]);
    report_known(!ok || ((r & EVT_B) != '0), $sformatf({"_wait_clear returned 0x%08x without any event of its mask: ",
                 "the irq replay needs p.elw, software must wait again"}, r));
  endtask

  // T31-T36: event B in c1 of each clearing read must be returned by the next _wait_clear
  task automatic test_lost_in_clear(input int unsigned id, input int unsigned kind);
    // _wait_clear asleep, _wait_clear with A there, sw event, barrier, mutex lock, dispatcher pop
    logic [31:0] adds[6]  = '{EU_WAIT_CLEAR, EU_WAIT_CLEAR, EU_SW_EVT_WAIT_CLEAR, EU_BARR0 + BARR_TRIG_WAIT_CLEAR,
                              EU_MUTEX, EU_DISP_FIFO};
    logic [31:0] wakes[6] = '{EVT_A, EVT_A, EVT_SW0, EVT_BARR, EVT_MUTEX, EVT_DISP};
    bit          ok1, ok2;
    logic [31:0] r1, r2;
    start_test(id, 1'b0);
    core_setup(0, EU_MASK, wakes[kind] | EVT_B);
    case (kind)
      1: begin pulse_event(0, EVT_A); wait_cycles(2); end
      3: begin core_setup(0, EU_BARR0 + BARR_TRIG_MASK, 32'h1); core_setup(0, EU_BARR0 + BARR_TGT_MASK, 32'h1); end
      5: begin core_setup(0, EU_DISP_TEAM, 32'h1); core_setup(0, EU_DISP_FIFO, 32'hD15_0001); end
      default: ;
    endcase
    core_read(0, adds[kind]);
    if (kind == 0) begin wait_sleep(0); pulse_event(0, EVT_A); end
    wait_grant(0, adds[kind]);
    pulse_event(0, EVT_B);
    core_get_rsp(0, ok1, r1);
    core_read(0, EU_WAIT_CLEAR);
    core_get_rsp(0, ok2, r2);
    if (!ok1)      report(1'b0, "the first read never returned");
    else if (!ok2) report(1'b0, "event B lost, core 0 sleeps forever");
    else           report((r2 & EVT_B) != '0, $sformatf("second _wait_clear returned 0x%08x", r2));
  endtask

/*******************************************************/
/**                 Protocol Tests End                **/
/*******************************************************/
/**              Feature Tests Beginning              **/
/*******************************************************/

  // T41: each mutex has its own owner, waiters and message (M1)
  task automatic test_multi_mutex(input int unsigned id);
    bit          ok0, ok1, ok2, ok3;
    logic [31:0] r0, r1, r2, r3;
    string       why = "";
    start_test(id, 1'b0);
    for (int c = 0; c < NB_CORES; c++) core_setup(c, EU_MASK, EVT_MUTEX);
    // cores 0 and 1 own mutexes 0 and 1, cores 2 and 3 wait for them
    core_read(0, EU_MUTEX);  core_get_rsp(0, ok0, r0);
    core_read(1, EU_MUTEX1); core_get_rsp(1, ok1, r1);
    core_read(2, EU_MUTEX);
    core_read(3, EU_MUTEX1);
    wait_sleep(2); wait_sleep(3);
    core_setup(1, EU_MUTEX1, 32'h1111_0001);
    wait_cycles(5);
    if (!ok0 || !ok1) why = "a free mutex was not locked at once";
    else if ((core_nb_rsp(3) != 1) || (core_nb_rsp(2) != 0))
      why = $sformatf("unlock of mutex 1 woke core 3: %0d, core 2: %0d", core_nb_rsp(3), core_nb_rsp(2));
    if (why == "") begin
      core_get_rsp(3, ok3, r3);
      if (r3 != 32'h1111_0001) why = $sformatf("core 3 got message 0x%08x from mutex 1", r3);
    end
    if (why == "") begin
      core_setup(0, EU_MUTEX, 32'h0000_0A0A);
      core_get_rsp(2, ok2, r2);
      if (!ok2 || (r2 != 32'h0000_0A0A)) why = $sformatf("core 2 got 0x%08x from mutex 0 (response %0b)", r2, ok2);
    end
    if (why == "") begin
      core_setup(2, EU_MUTEX, '0); core_setup(3, EU_MUTEX1, '0);
      core_read(0, EU_MUTEX); core_get_rsp(0, ok0, r0);
      core_read(0, EU_MUTEX1); core_get_rsp(0, ok1, r1);
      if (!ok0 || !ok1) why = "a mutex is still locked after its owner unlocked it";
    end
    report(why == "", why);
  endtask

  // T42: bit 27 on every core while the FIFO holds ids, ids in order with the valid bit, ready low when full (SOC1)
  task automatic test_soc_events(input int unsigned id);
    bit          ok0, ok1, ok;
    logic [31:0] r0, r1, r;
    string       why = "";
    start_test(id, 1'b0);
    core_setup(0, EU_MASK, EVT_SOC);
    core_setup(1, EU_MASK, EVT_SOC);
    core_read(0, EU_WAIT_CLEAR); core_read(1, EU_WAIT);
    wait_sleep(0); wait_sleep(1);
    soc_push(8'h40);
    core_get_rsp(0, ok0, r0); core_get_rsp(1, ok1, r1);
    if (!ok0 || !ok1 || (r0 != EVT_SOC) || (r1 != EVT_SOC))
      why = $sformatf("cores woken with 0x%08x (%0b) and 0x%08x (%0b), expected bit 27", r0, ok0, r1, ok1);
    // the FIFO is not empty: the _wait_clear of core 0 cannot remove bit 27
    if (why == "") begin
      wait_cycles(2);
      core_read(0, EU_BUFFER); core_get_rsp(0, ok, r);
      if ((r & EVT_SOC) == '0) why = $sformatf("core 0 buffer 0x%08x without bit 27 while the FIFO holds an id", r);
      periph_i.read(PER_CORE_STRIDE * 2 + EU_BUFFER); periph_i.get_rsp(TIMEOUT, ok, r);
      if ((why == "") && ((r & EVT_SOC) == '0)) why = $sformatf("core 2 buffer 0x%08x without bit 27", r);
    end
    if (why == "") begin
      for (int unsigned i = 1; i < SOC_DEPTH; i++) soc_push(8'(32'h40 + i));
      @(negedge clk);
      if (soc_ready) why = $sformatf("ready high with %0d ids in the FIFO", SOC_DEPTH);
    end
    // one more id waits for room
    if (why == "") begin
      fork soc_push(8'(32'h40 + SOC_DEPTH)); join_none
      wait_cycles(3);
      for (int unsigned i = 0; i <= SOC_DEPTH; i++) begin
        periph_i.read(PER_SOC_EVENT); periph_i.get_rsp(TIMEOUT, ok, r);
        if ((why == "") && (!ok || (r != {1'b1, 23'b0, 8'(8'h40 + i)})))
          why = $sformatf("read %0d of the FIFO returned 0x%08x, expected 0x%08x", i, r, {1'b1, 23'b0, 8'(8'h40 + i)});
      end
      periph_i.read(PER_SOC_EVENT); periph_i.get_rsp(TIMEOUT, ok, r);
      if ((why == "") && (!ok || r[31])) why = $sformatf("read of the empty FIFO returned 0x%08x, valid bit set", r);
    end
    if (why == "") begin
      core_setup(0, EU_BUFFER_CLEAR, EVT_SOC);
      core_read(0, EU_BUFFER); core_get_rsp(0, ok, r);
      if ((r & EVT_SOC) != '0) why = $sformatf("bit 27 still set after the FIFO was emptied and the bit cleared: 0x%08x", r);
    end
    report(why == "", why);
  endtask

  // T43: a debug request wakes a waiting core like an interrupt, and the core sleeps normally afterwards (S4)
  task automatic test_debug_during_wait(input int unsigned id);
    bit          ok;
    logic [31:0] r;
    string       why = "";
    start_test(id, 1'b0);
    core_setup(0, EU_MASK, EVT_B);
    core_read(0, EU_WAIT_CLEAR);
    wait_sleep(0);
    dbg_req[0] <= 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (!core_clock_en[0]) why = "the clock stays gated with a debug request";
    if ((why == "") && !core_dbg_req[0]) why = "core_dbg_req_o not raised one cycle after dbg_req_i";
    core_get_rsp(0, ok, r);
    if ((why == "") && !ok) why = "the pending wait never completes during the debug request";
    dbg_req[0] <= 1'b0;
    wait_cycles(2);
    if (why == "") begin
      core_read(0, EU_WAIT_CLEAR);
      wait_sleep(0);
      if (core_clock_en[0]) why = "the core does not sleep again after the debug request";
      pulse_event(0, EVT_B);
      core_get_rsp(0, ok, r);
      if ((why == "") && (!ok || (r != EVT_B))) why = $sformatf("wait after debug returned 0x%08x (response %0b)", r, ok);
    end
    report(why == "", why);
  endtask

  // T44: no clock gating while core_busy_i is high, and an event then completes the wait (S1)
  task automatic test_core_busy(input int unsigned id);
    bit          ok;
    logic [31:0] r;
    string       why = "";
    start_test(id, 1'b0);
    core_setup(0, EU_MASK, EVT_B);
    core_busy[0] <= 1'b1;
    core_read(0, EU_WAIT_CLEAR);
    repeat (10) begin
      @(negedge clk);
      if ((why == "") && !core_clock_en[0]) why = "clock gated while core_busy_i is high";
      if ((why == "") && link_gnt[0]) why = "wait granted without an event";
    end
    core_busy[0] <= 1'b0;
    wait_cycles(3);
    if ((why == "") && core_clock_en[0]) why = "clock not gated after core_busy_i fell";
    pulse_event(0, EVT_B);
    core_get_rsp(0, ok, r);
    if ((why == "") && (!ok || (r != EVT_B))) why = $sformatf("wait returned 0x%08x (response %0b)", r, ok);
    if (why == "") begin
      core_busy[0] <= 1'b1;
      core_read(0, EU_WAIT_CLEAR);
      wait_cycles(4);
      pulse_event(0, EVT_B);
      core_get_rsp(0, ok, r);
      if (!ok || (r != EVT_B)) why = $sformatf("wait with an event while busy returned 0x%08x (response %0b)", r, ok);
      core_busy[0] <= 1'b0;
    end
    report(why == "", why);
  endtask

  // T45: accelerator, timer and DMA lines reach the bits of Table 1 of their core only (E3)
  task automatic test_event_sources(input int unsigned id);
    bit          ok;
    logic [31:0] r;
    string       why = "";
    start_test(id, 1'b0);
    for (int unsigned c = 0; c < NB_CORES; c++) begin
      acc_events[c]   <= 4'h1 << c;
      timer_events[c] <= 2'h1 << (c % 2);
      dma_events[c]   <= 2'h2 >> (c % 2);
    end
    @(posedge clk);
    acc_events <= '0; timer_events <= '0; dma_events <= '0;
    wait_cycles(2);
    for (int unsigned c = 0; c < NB_CORES; c++) begin
      logic [31:0] exp = (32'h1 << (12 + c)) | (32'h1 << (10 + c % 2)) | (32'h1 << (9 - c % 2));
      core_read(c, EU_BUFFER); core_get_rsp(c, ok, r);
      if ((why == "") && (!ok || (r != exp))) why = $sformatf("core %0d buffer 0x%08x, expected 0x%08x", c, r, exp);
    end
    report(why == "", why);
  endtask

  // T46: every periph range answers, also without a register to write or without a unit (P4)
  task automatic test_periph_ranges(input int unsigned id);
    bit          ok;
    logic [31:0] r;
    string       why = "";
    logic [31:0] adds[5]  = '{EU_MASK, PER_BARR0, PER_SW_EVT_TRIG, PER_SOC_EVENT, PER_INTERCLUSTER};
    string       names[5] = '{"core unit", "barrier unit", "sw event trigger", "SoC event FIFO", "inter-cluster range"};
    start_test(id, 1'b0);
    // an unanswered request blocks the port, so each range starts from reset
    foreach (adds[k]) begin
      reset_dut();
      periph_i.read(adds[k]); periph_i.get_rsp(TIMEOUT, ok, r);
      if (!ok) why = {why, why == "" ? "" : ", ", $sformatf("read of the %s (0x%03x) not answered", names[k], adds[k])};
      else begin
        periph_i.write(adds[k], '0); periph_i.get_rsp(TIMEOUT, ok, r);
        if (!ok) why = {why, why == "" ? "" : ", ", $sformatf("write to the %s (0x%03x) not answered", names[k], adds[k])};
      end
    end
    // the SoC event register is read-only: a write must not pop the FIFO
    if (why == "") begin
      reset_dut();
      soc_push(8'h5A);
      periph_i.write(PER_SOC_EVENT, '0); periph_i.get_rsp(TIMEOUT, ok, r);
      periph_i.read(PER_SOC_EVENT);      periph_i.get_rsp(TIMEOUT, ok, r);
      if (r != 32'h8000_005A) why = $sformatf("after a write the SoC event FIFO returned 0x%08x, expected 0x8000005a", r);
    end
    reset_dut();
    report(why == "", why);
  endtask

  // T50/T51: every core unit register, on the direct link of core 1 or on the periph port at core 2's unit (REG1)
  task automatic test_core_regs(input int unsigned id, input bit periph);
    int unsigned c    = periph ? 2 : 1;
    logic [31:0] base = periph ? PER_CORE_STRIDE * c : '0;
    string       why  = "";
    start_test(id, 1'b0);
    reg_wr(periph, c, base + EU_MASK, 32'hF0F0_0000);
    expect_rd(why, periph, c, base + EU_MASK, 32'hF0F0_0000, "mask");
    reg_wr(periph, c, base + EU_MASK_AND, 32'hF000_0000);
    expect_rd(why, periph, c, base + EU_MASK, 32'h00F0_0000, "mask after mask_and");
    reg_wr(periph, c, base + EU_MASK_OR, 32'h0000_000F);
    expect_rd(why, periph, c, base + EU_MASK, 32'h00F0_000F, "mask after mask_or");
    reg_wr(periph, c, base + EU_IRQ_MASK, 32'h0F0F_0000);
    expect_rd(why, periph, c, base + EU_IRQ_MASK, 32'h0F0F_0000, "irq mask");
    reg_wr(periph, c, base + EU_IRQ_MASK_AND, 32'h0F00_0000);
    expect_rd(why, periph, c, base + EU_IRQ_MASK, 32'h000F_0000, "irq mask after irq_mask_and");
    reg_wr(periph, c, base + EU_IRQ_MASK_OR, 32'h0000_0001);
    expect_rd(why, periph, c, base + EU_IRQ_MASK, 32'h000F_0001, "irq mask after irq_mask_or");
    // NB_CORES bits wide
    reg_wr(periph, c, base + EU_SW_EVT_MASK, 32'hFFFF_FFFA);
    expect_rd(why, periph, c, base + EU_SW_EVT_MASK, 32'hA, "sw_events_mask");
    reg_wr(periph, c, base + EU_SW_EVT_MASK_AND, 32'h2);
    expect_rd(why, periph, c, base + EU_SW_EVT_MASK, 32'h8, "sw_events_mask after sw_events_mask_and");
    reg_wr(periph, c, base + EU_SW_EVT_MASK_OR, 32'h1);
    expect_rd(why, periph, c, base + EU_SW_EVT_MASK, 32'h9, "sw_events_mask after sw_events_mask_or");
    expect_rd(why, periph, c, base + EU_STATUS, 32'h1, "status of a running core");
    // the direct link is aliased to the issuing core: the other units are untouched
    expect_rd(why, 1'b0, 0, EU_MASK, '0, "core 0 mask");
    expect_rd(why, 1'b1, 0, PER_CORE_STRIDE * 3 + EU_IRQ_MASK, '0, "core 3 irq mask");
    // A in the event mask, B in the irq mask, software event 0 in neither
    reg_wr(periph, c, base + EU_MASK, EVT_A);
    reg_wr(periph, c, base + EU_IRQ_MASK, EVT_B);
    core_setup(0, EU_SW_EVT_TRIG, 32'h1 << c);
    pulse_event(c, EVT_A | EVT_B);
    wait_cycles(2);
    expect_rd(why, periph, c, base + EU_BUFFER, EVT_A | EVT_B | EVT_SW0, "buffer");
    expect_rd(why, periph, c, base + EU_BUFFER_MASKED, EVT_A, "buffer_masked");
    expect_rd(why, periph, c, base + EU_BUFFER_IRQ_MASKED, EVT_B, "buffer_irq_masked");
    expect_true(why, irq_req[c] && (irq_id[c] == 5'd23),
                $sformatf("irq_req %0b id %0d, expected 1 and 23", irq_req[c], irq_id[c]));
    reg_wr(periph, c, base + EU_BUFFER_CLEAR, EVT_A | EVT_SW0);
    expect_rd(why, periph, c, base + EU_BUFFER, EVT_B, "buffer after buffer_clear of A and sw event 0");
    reg_wr(periph, c, base + EU_BUFFER_CLEAR, EVT_B);
    wait_cycles(2);
    expect_rd(why, periph, c, base + EU_BUFFER, '0, "buffer after buffer_clear of B");
    expect_true(why, !irq_req[c], "irq_req still high with an empty buffer");
    report(why == "", why);
  endtask

  // T52: targets of a trigger write, mask 0 for all cores, periph triggers, trigger reads with sw_events_mask (W1, S1)
  task automatic test_sw_events(input int unsigned id);
    string why = "";
    start_test(id, 1'b0);
    core_setup(0, EU_SW_EVT_TRIG + 4 * 3, 32'b0110);
    expect_buffers(why, '{0, 32'h1 << 3, 32'h1 << 3, 0}, "a write of event 3 for cores 1 and 2");
    clear_buffers();
    core_setup(3, EU_SW_EVT_TRIG + 4 * 5, '0);
    expect_buffers(why, '{4{32'h1 << 5}}, "a write of event 5 with mask 0");
    clear_buffers();
    reg_wr(1'b1, 0, PER_SW_EVT_TRIG + 4 * 2, 32'b1001);
    wait_cycles(2);
    expect_buffers(why, '{32'h1 << 2, 0, 0, 32'h1 << 2}, "a periph write of event 2 for cores 0 and 3");
    clear_buffers();
    reg_wr(1'b1, 0, PER_SW_EVT_TRIG + 4 * 7, '0);
    wait_cycles(2);
    expect_buffers(why, '{4{32'h1 << 7}}, "a periph write of event 7 with mask 0");
    clear_buffers();
    // core 1 triggers for cores 1 and 2, so it wakes on its own event
    core_setup(1, EU_SW_EVT_MASK, 32'b0110);
    core_setup(1, EU_MASK, 32'h1 << 4);
    expect_rd(why, 1'b0, 1, EU_SW_EVT_WAIT + 4 * 4, 32'h1 << 4, "trigg_sw_event_wait 4");
    expect_buffers(why, '{0, 32'h1 << 4, 32'h1 << 4, 0}, "trigg_sw_event_wait 4 (no clear)");
    clear_buffers();
    core_setup(1, EU_MASK, 32'h1 << 6);
    expect_rd(why, 1'b0, 1, EU_SW_EVT_WAIT_CLEAR + 4 * 6, 32'h1 << 6, "trigg_sw_event_wait_clear 6");
    expect_buffers(why, '{0, 0, 32'h1 << 6, 0}, "trigg_sw_event_wait_clear 6 (clear on core 1 only)");
    clear_buffers();
    // core 3 triggers event 1 for core 0 only, sleeps, and the trigger must not fire again while it sleeps
    core_setup(3, EU_SW_EVT_MASK, 32'b0001);
    core_setup(3, EU_MASK, 32'h1 << 1);
    core_read(3, EU_SW_EVT_WAIT + 4 * 1);
    wait_sleep(3);
    expect_true(why, !core_clock_en[3], "core 3 does not sleep on an event it sent to core 0 only");
    expect_rd(why, 1'b0, 0, EU_BUFFER, 32'h1 << 1, "core 0 buffer after the trigger read of core 3");
    core_setup(0, EU_BUFFER_CLEAR, '1);
    wait_cycles(5);
    expect_rd(why, 1'b0, 0, EU_BUFFER, '0, "core 0 buffer while core 3 sleeps");
    core_setup(0, EU_SW_EVT_TRIG + 4 * 1, 32'b1000);
    expect_rsp(why, 1'b0, 3, 32'h1 << 1, "trigg_sw_event_wait 1 of core 3");
    report(why == "", why);
  endtask

  // T53: a barrier of three cores for four: both ports, status, every trigger, events, independent barriers (B1)
  task automatic test_barrier(input int unsigned id);
    localparam logic [31:0] B1_DIRECT = EU_BARR0 + BARR_STRIDE;
    localparam logic [31:0] B1_PERIPH = PER_BARR0 + BARR_STRIDE;
    localparam logic [31:0] B2_DIRECT = EU_BARR0 + 2 * BARR_STRIDE;
    bit          ok;
    logic [31:0] r;
    string       why = "";
    start_test(id, 1'b0);
    reg_wr(1'b1, 0, B1_PERIPH + BARR_TRIG_MASK, 32'b0111);
    reg_wr(1'b1, 0, B1_PERIPH + BARR_TGT_MASK, 32'b1111);
    expect_rd(why, 1'b0, 3, B1_DIRECT + BARR_TRIG_MASK, 32'b0111, "trigger mask on the direct link");
    expect_rd(why, 1'b0, 3, B1_DIRECT + BARR_TGT_MASK, 32'b1111, "target mask on the direct link");
    expect_rd(why, 1'b1, 0, B1_PERIPH + BARR_TGT_MASK, 32'b1111, "target mask on the periph port");
    for (int unsigned c = 0; c < NB_CORES; c++) core_setup(c, EU_MASK, EVT_BARR);
    core_read(0, B1_DIRECT + BARR_TRIG_WAIT_CLEAR);
    wait_sleep(0);
    expect_rd(why, 1'b1, 0, B1_PERIPH + BARR_STATUS, 32'b0001, "status after trigger_wait_clear of core 0");
    core_setup(1, B1_DIRECT + BARR_TRIGGER, 32'b0010);
    expect_rd(why, 1'b0, 3, B1_DIRECT + BARR_STATUS, 32'b0011, "status after a trigger write for core 1");
    expect_true(why, !core_clock_en[0], "core 0 woke before the barrier was complete");
    core_read(2, B1_DIRECT + BARR_TRIG_SELF); core_get_rsp(2, ok, r);
    expect_true(why, ok, "trigger_self of core 2 not answered");
    expect_rsp(why, 1'b0, 0, EVT_BARR, "trigger_wait_clear of core 0");
    wait_cycles(2);
    expect_buffers(why, '{0, EVT_BARR, EVT_BARR, EVT_BARR}, "the barrier (core 0 cleared it)");
    expect_rd(why, 1'b1, 0, B1_PERIPH + BARR_STATUS, '0, "status after the barrier");
    expect_rd(why, 1'b1, 0, PER_BARR0 + BARR_STATUS, '0, "status of barrier 0");
    // trigger_wait of core 2, completed by a periph trigger write for cores 0 and 1
    clear_buffers();
    core_read(2, B1_DIRECT + BARR_TRIG_WAIT);
    wait_sleep(2);
    reg_wr(1'b1, 0, B1_PERIPH + BARR_TRIGGER, 32'b0011);
    expect_rsp(why, 1'b0, 2, EVT_BARR, "trigger_wait of core 2");
    wait_cycles(2);
    expect_buffers(why, '{4{EVT_BARR}}, "the second barrier (trigger_wait does not clear)");
    // barrier 2 of core 3 alone for core 0 leaves barrier 1 alone
    clear_buffers();
    core_setup(3, B2_DIRECT + BARR_TRIG_MASK, 32'b1000);
    core_setup(3, B2_DIRECT + BARR_TGT_MASK, 32'b0001);
    core_setup(3, B2_DIRECT + BARR_TRIGGER, 32'b1000);
    wait_cycles(2);
    expect_buffers(why, '{EVT_BARR, 0, 0, 0}, "barrier 2");
    expect_rd(why, 1'b1, 0, B1_PERIPH + BARR_STATUS, '0, "status of barrier 1 after barrier 2");
    report(why == "", why);
  endtask

  // T54: a core pops only the values of its teams, sleeps while there is none, in push order across the wrap (D1)
  task automatic test_dispatch_teams(input int unsigned id);
    string why = "";
    start_test(id, 1'b0);
    for (int unsigned c = 1; c < NB_CORES; c++) core_setup(c, EU_MASK, EVT_DISP);
    core_setup(0, EU_DISP_TEAM, 32'b0010); core_setup(0, EU_DISP_FIFO, 32'hD000_0001);
    core_setup(0, EU_DISP_TEAM, 32'b0110); core_setup(0, EU_DISP_FIFO, 32'hD000_0002);
    core_setup(0, EU_DISP_TEAM, 32'b1000); core_setup(0, EU_DISP_FIFO, 32'hD000_0003);
    expect_rd(why, 1'b0, 2, EU_DISP_FIFO, 32'hD000_0002, "core 2 pop (skips the value of core 1)");
    expect_rd(why, 1'b0, 3, EU_DISP_FIFO, 32'hD000_0003, "core 3 pop (skips two values)");
    expect_rd(why, 1'b0, 1, EU_DISP_FIFO, 32'hD000_0001, "first pop of core 1");
    expect_rd(why, 1'b0, 1, EU_DISP_FIFO, 32'hD000_0002, "second pop of core 1");
    // cores 1 and 2 sleep on an empty FIFO; a value for core 1 wakes core 1 only
    core_read(1, EU_DISP_FIFO); core_read(2, EU_DISP_FIFO);
    wait_sleep(1); wait_sleep(2);
    core_setup(0, EU_DISP_TEAM, 32'b0010); core_setup(0, EU_DISP_FIFO, 32'hD000_0004);
    wait_cycles(10);
    expect_true(why, core_nb_rsp(2) == 0, "core 2 popped a value of core 1");
    expect_rsp(why, 1'b0, 1, 32'hD000_0004, "pop of core 1 woken by its value");
    core_setup(0, EU_DISP_TEAM, 32'b0100); core_setup(0, EU_DISP_FIFO, 32'hD000_0005);
    expect_rsp(why, 1'b0, 2, 32'hD000_0005, "pop of core 2 woken by its value");
    // 11 pushes wrap the FIFO; core 3 waits first, so that its pointer skips the values of cores 1 and 2 (T59)
    core_read(3, EU_DISP_FIFO);
    wait_sleep(3);
    core_setup(0, EU_DISP_TEAM, 32'b1110);
    for (int unsigned i = 0; i < 6; i++) core_setup(0, EU_DISP_FIFO, 32'hE000_0000 + i);
    expect_rsp(why, 1'b0, 3, 32'hE000_0000, "pop 0 of core 3 after the wrap");
    for (int unsigned c = 1; c < NB_CORES; c++)
      for (int unsigned i = (c == 3) ? 1 : 0; i < 6; i++)
        expect_rd(why, 1'b0, c, EU_DISP_FIFO, 32'hE000_0000 + i, $sformatf("pop %0d of core %0d after the wrap", i, c));
    report(why == "", why);
  endtask

  // T59: a core skips other teams' values only while it pops, so DISP_DEPTH pushes bring its pointer to the write one
  task automatic test_dispatch_lag(input int unsigned id);
    bit          ok;
    logic [31:0] r;
    start_test(id, 1'b0);
    for (int unsigned c = 1; c < NB_CORES; c++) core_setup(c, EU_MASK, EVT_DISP);
    core_setup(0, EU_DISP_TEAM, 32'b0010);
    for (int unsigned i = 0; i < DISP_DEPTH - 1; i++) begin
      core_setup(0, EU_DISP_FIFO, 32'hF000_0000 + i);
      core_read(1, EU_DISP_FIFO); core_get_rsp(1, ok, r);
    end
    core_setup(0, EU_DISP_TEAM, 32'b1000);
    core_setup(0, EU_DISP_FIFO, 32'hF000_00FF);
    core_read(3, EU_DISP_FIFO); core_get_rsp(3, ok, r);
    report_known(ok && (r == 32'hF000_00FF), $sformatf({"the only value for core 3 is lost after %0d values for core 1: ",
                 "its read pointer lags by DISP_FIFO_DEPTH"}, DISP_DEPTH - 1));
  endtask

  // T55: only irq-mask events raise an interrupt, the highest bit is reported, an ack clears only its bit (I1)
  task automatic test_irq_priority(input int unsigned id);
    string why = "";
    start_test(id, 1'b0);
    core_setup(0, EU_IRQ_MASK, EVT_A | EVT_B);
    core_setup(1, EU_SW_EVT_TRIG, 32'b0001);
    wait_cycles(3);
    expect_true(why, !irq_req[0], "irq raised by sw event 0, not in the irq mask");
    core_setup(0, EU_IRQ_MASK_OR, EVT_SW0);
    wait_cycles(3);
    expect_true(why, irq_req[0] && (irq_id[0] == 5'd0),
                $sformatf("irq_req %0b id %0d after irq_mask_or of bit 0", irq_req[0], irq_id[0]));
    core_setup(0, EU_IRQ_MASK_AND, EVT_SW0);
    wait_cycles(3);
    expect_true(why, !irq_req[0], "irq still raised after irq_mask_and of bit 0");
    pulse_event(0, EVT_A | EVT_B);
    wait_cycles(3);
    expect_true(why, irq_req[0] && (irq_id[0] == 5'd23),
                $sformatf("irq_req %0b id %0d with A and B, expected id 23", irq_req[0], irq_id[0]));
    expect_rd(why, 1'b0, 0, EU_BUFFER_IRQ_MASKED, EVT_A | EVT_B, "buffer_irq_masked");
    irq_ack_pulse(0, 5'd23);
    expect_true(why, irq_req[0] && (irq_id[0] == 5'd22),
                $sformatf("irq_req %0b id %0d after the ack of 23, expected id 22", irq_req[0], irq_id[0]));
    expect_rd(why, 1'b0, 0, EU_BUFFER, EVT_A | EVT_SW0, "buffer after the ack of 23");
    irq_ack_pulse(0, 5'd22);
    expect_true(why, !irq_req[0], "irq still raised after both acks");
    expect_rd(why, 1'b0, 0, EU_BUFFER, EVT_SW0, "buffer after both acks");
    report(why == "", why);
  endtask

  // T56: a wait with an interrupt pending returns at once; after the ack the replay returns and the next one sleeps (S3)
  task automatic test_irq_while_sleep(input int unsigned id);
    bit          ok;
    logic [31:0] r;
    string       why = "";
    start_test(id, 1'b0);
    core_setup(0, EU_MASK, EVT_B);
    core_setup(0, EU_IRQ_MASK, EVT_A);
    pulse_event(0, EVT_A);
    wait_cycles(3);
    core_read(0, EU_WAIT_CLEAR); core_get_rsp(0, ok, r);
    expect_true(why, ok, "a wait with an interrupt pending never returns");
    pulse_event(0, EVT_B);
    irq_ack_pulse(0, irq_id[0]);
    expect_rd(why, 1'b0, 0, EU_WAIT_CLEAR, EVT_B, "replayed wait after the ack");
    expect_rd(why, 1'b0, 0, EU_BUFFER, '0, "buffer after the replayed _wait_clear");
    core_read(0, EU_WAIT_CLEAR);
    wait_sleep(0);
    expect_true(why, !core_clock_en[0], "the core does not sleep after the interrupt");
    expect_rd(why, 1'b1, 0, EU_STATUS, '0, "status of a sleeping core");
    pulse_event(0, EVT_B);
    expect_rsp(why, 1'b0, 0, EVT_B, "wait after the interrupt");
    report(why == "", why);
  endtask

  // T57: with the event already there both waits return at once; only _wait_clear clears, only the mask bits (E2, S2)
  task automatic test_wait_variants(input int unsigned id);
    string       why   = "";
    int unsigned gated = 0;
    start_test(id, 1'b0);
    core_setup(0, EU_MASK, EVT_A);
    pulse_event(0, EVT_A | EVT_B);
    wait_cycles(2);
    fork
      begin
        expect_rd(why, 1'b0, 0, EU_WAIT, EVT_A, "_wait");
        expect_rd(why, 1'b0, 0, EU_BUFFER, EVT_A | EVT_B, "buffer after _wait");
        expect_rd(why, 1'b0, 0, EU_WAIT_CLEAR, EVT_A, "_wait_clear");
        expect_rd(why, 1'b0, 0, EU_BUFFER, EVT_B, "buffer after _wait_clear (B is not in the mask)");
      end
      repeat (40) begin @(negedge clk); if (!core_clock_en[0]) gated++; end
    join
    expect_true(why, gated == 0, $sformatf("clock gated for %0d cycles with the event already there", gated));
    report(why == "", why);
  endtask

  // T58: a mutex goes to the waiting core with the lowest id, whatever the order of the locks (M1)
  task automatic test_mutex_priority(input int unsigned id);
    string why = "";
    start_test(id, 1'b0);
    for (int unsigned c = 0; c < NB_CORES; c++) core_setup(c, EU_MASK, EVT_MUTEX);
    expect_rd(why, 1'b0, 0, EU_MUTEX, '0, "lock of a free mutex");
    core_read(3, EU_MUTEX); wait_sleep(3);
    core_read(2, EU_MUTEX); wait_sleep(2);
    core_read(1, EU_MUTEX); wait_sleep(1);
    for (int unsigned c = 0; c < NB_CORES - 1; c++) begin
      core_setup(c, EU_MUTEX, 32'hAB00_0000 + c);
      expect_rsp(why, 1'b0, c + 1, 32'hAB00_0000 + c, $sformatf("lock of core %0d after the unlock by core %0d", c + 1, c));
      expect_true(why, (c + 2 >= NB_CORES) || (core_nb_rsp(c + 2) == 0), $sformatf("core %0d got the mutex too", c + 2));
    end
    core_setup(3, EU_MUTEX, '0);
    report(why == "", why);
  endtask

/*******************************************************/
/**                 Feature Tests End                 **/
/*******************************************************/
/**               Random Test Beginning               **/
/*******************************************************/

  // programs follow the software rules: only the awaited events in the mask, unlock by the owner, pops of pushed values
  typedef struct packed { logic wen; logic [31:0] add; logic [31:0] wdata; } req_t;
  req_t        mq[NB_CORES][$];        // requests granted and not answered yet, per core
  logic [31:0] disp_exp[NB_CORES][$];  // values each core still has to pop, in push order
  bit          rnd_active, rnd_abort[NB_CORES];
  int          mutex_owner[NB_HW_MUT];
  int unsigned rnd_errors, disp_pushes;
  string       rnd_first;

  function automatic void rnd_error(input string msg);
    rnd_errors++;
    if (rnd_first == "") rnd_first = msg;
    $display("[%0t] ERROR random: %s", $time, msg);
  endfunction

  function automatic bit is_mutex(input logic [31:0] add);
    return (add >= EU_MUTEX) && (add < EU_MUTEX + 4 * NB_HW_MUT);
  endfunction

  // M1: one owner per mutex, unlock by the owner; D1: each core pops what core 0 pushed, in order
  always @(posedge clk) if (rst_n && rnd_active) begin
    for (int c = 0; c < NB_CORES; c++) begin
      if (link_r_valid[c] && (mq[c].size() != 0)) begin
        automatic req_t g = mq[c].pop_front();
        if (g.wen && is_mutex(g.add)) begin
          automatic int m = (g.add - EU_MUTEX) / 4;
          if (mutex_owner[m] != -1)
            rnd_error($sformatf("M1: core %0d got mutex %0d while core %0d owns it", c, m, mutex_owner[m]));
          mutex_owner[m] = c;
        end
        if (g.wen && (g.add == EU_DISP_FIFO)) begin
          if (disp_exp[c].size() == 0)
            rnd_error($sformatf("D1: core %0d popped 0x%08x, nothing was pushed to it", c, link_r_rdata[c]));
          else begin
            automatic logic [31:0] e = disp_exp[c].pop_front();
            if (link_r_rdata[c] != e) rnd_error($sformatf("D1: core %0d popped 0x%08x, expected 0x%08x", c, link_r_rdata[c], e));
          end
        end
      end
      if (link_req[c] && link_gnt[c]) begin
        mq[c].push_back('{link_wen[c], link_add[c], link_wdata[c]});
        if (!link_wen[c] && is_mutex(link_add[c])) begin
          automatic int m = (link_add[c] - EU_MUTEX) / 4;
          if (mutex_owner[m] != c) rnd_error($sformatf("M1: core %0d unlocked mutex %0d owned by %0d", c, m, mutex_owner[m]));
          mutex_owner[m] = -1;
        end
        if ((c == 0) && !link_wen[c] && (link_add[c] == EU_DISP_FIFO))
          for (int t = 1; t < NB_CORES; t++) disp_exp[t].push_back(link_wdata[c]);
      end
    end
  end

  // a missing response is a hang
  task automatic rnd_collect(input int unsigned k, input int unsigned n);
    bit          ok;
    logic [31:0] r;
    repeat (n) begin
      core_get_rsp(k, ok, r, RND_HANG);
      if (!ok) begin
        rnd_error($sformatf("core %0d hangs: no response for %0d cycles", k, RND_HANG));
        rnd_abort[k] = 1'b1;
        return;
      end
    end
  endtask

  // accesses that cannot block anybody
  task automatic rnd_nb(input int unsigned k);
    case ($urandom_range(0, 5))
      0:       core_read(k, EU_MASK);
      1:       core_read(k, EU_BUFFER);
      2:       core_read(k, EU_BUFFER_MASKED);
      3:       core_read(k, EU_STATUS);
      4:       core_write(k, EU_BUFFER_CLEAR, $urandom & (EVT_A | EVT_B | 32'hFF));
      default: core_write(k, EU_SW_EVT_TRIG + 4 * $urandom_range(0, NB_SW_EVT - 1), $urandom_range(0, 15));
    endcase
  endtask

  // the mask write, the blocking read and maybe a non-blocking access right behind it
  task automatic rnd_wait(input int unsigned k, input logic [31:0] mask, input logic [31:0] add);
    int unsigned n = 2;
    core_write(k, EU_MASK, mask);
    core_read(k, add);
    if ($urandom_range(0, 1) != 0) begin rnd_nb(k); n++; end
    rnd_collect(k, n);
  endtask

  task automatic rnd_core(input int unsigned k, input int unsigned ops);
    for (int unsigned n = 0; (n < ops) && !rnd_abort[k]; n++) begin
      int unsigned op = $urandom_range(0, 99);
      if ((k == 0) && (op < 15)) begin
        // at most 5 values pending in the 8-entry FIFO
        bit room = 1'b1;
        for (int t = 1; t < NB_CORES; t++) if (disp_exp[t].size() > 4) room = 1'b0;
        if (room) begin
          int unsigned m = 2;
          if ($urandom_range(0, 1) != 0) begin core_write(k, EU_MASK, EVT_A | EVT_B); core_read(k, EU_WAIT_CLEAR); m += 2; end
          core_write(k, EU_DISP_TEAM, 32'hE);
          core_write(k, EU_DISP_FIFO, {16'hD15A, 16'(disp_pushes++)});
          rnd_collect(k, m);
        end
      end else if ((k != 0) && (op < 25) && (disp_exp[k].size() != 0)) begin
        rnd_wait(k, EVT_DISP, EU_DISP_FIFO);
      end else if (op < 45) begin
        rnd_wait(k, EVT_A | EVT_B, EU_WAIT_CLEAR);
      end else if (op < 55) begin
        int unsigned j = $urandom_range(0, NB_SW_EVT - 1);
        rnd_wait(k, 32'h1 << j, EU_SW_EVT_WAIT_CLEAR + 4 * j);
      end else if (op < 65) begin
        rnd_wait(k, EVT_BARR, EU_BARR0 + BARR_STRIDE * k + BARR_TRIG_WAIT_CLEAR);
      end else if (op < 78) begin
        // critical section, the unlock maybe right behind a _wait_clear
        int unsigned m   = 1;
        logic [31:0] mtx = EU_MUTEX + 4 * $urandom_range(0, NB_HW_MUT - 1);
        core_write(k, EU_MASK, EVT_MUTEX);
        core_read(k, mtx);
        rnd_collect(k, 2);
        if (rnd_abort[k]) return;
        if ($urandom_range(0, 1) != 0) begin core_write(k, EU_MASK, EVT_A | EVT_B); core_read(k, EU_WAIT_CLEAR); m += 2; end
        else begin rnd_nb(k); m++; end
        core_write(k, mtx, $urandom);
        rnd_collect(k, m);
      end else begin
        int unsigned m = $urandom_range(1, 3);
        repeat (m) rnd_nb(k);
        rnd_collect(k, m);
      end
    end
  endtask

  task automatic rnd_storm();
    while (rnd_active) begin
      @(posedge clk);
      for (int c = 0; c < NB_CORES; c++) cluster_events[c] <= ($urandom_range(0, 11) == 0) ? 32'($urandom_range(1, 3)) : '0;
    end
    cluster_events <= '0;
  endtask

  // the periph master only does accesses that cannot block anybody
  task automatic rnd_periph();
    bit          ok;
    logic [31:0] r;
    while (rnd_active) begin
      int unsigned c = $urandom_range(0, NB_CORES - 1);
      wait_cycles($urandom_range(1, 6));
      case ($urandom_range(0, 2))
        0:       periph_i.read(PER_CORE_STRIDE * c + (($urandom_range(0, 1) != 0) ? EU_MASK : EU_BUFFER));
        1:       periph_i.write(PER_CORE_STRIDE * c + EU_BUFFER_CLEAR, $urandom & (EVT_A | EVT_B));
        default: periph_i.write(PER_SW_EVT_TRIG + 4 * $urandom_range(0, NB_SW_EVT - 1), $urandom_range(0, 15));
      endcase
      periph_i.get_rsp(RND_HANG, ok, r);
      if (!ok) begin rnd_error("the periph master hangs"); return; end
    end
  endtask

  task automatic rnd_toggle();
    while (rnd_active) begin
      wait_cycles($urandom_range(20, 150));
      two_outstanding = ~two_outstanding;
    end
  endtask

  // T40: random traffic from four cores and the periph port, with random events and outstanding transactions
  task automatic test_random(input int unsigned id, input int unsigned seed, input int unsigned ops);
    start_test(id, 1'b0);
    void'($urandom(seed));
    rnd_errors = 0; rnd_first = ""; disp_pushes = 0;
    foreach (mutex_owner[m]) mutex_owner[m] = -1;
    for (int c = 0; c < NB_CORES; c++) begin mq[c].delete(); disp_exp[c].delete(); rnd_abort[c] = 1'b0; end
    // barrier k belongs to core k alone, so that a barrier wait never depends on another core
    for (int c = 0; c < NB_CORES; c++) begin
      core_setup(c, EU_BARR0 + BARR_STRIDE * c + BARR_TRIG_MASK, 32'h1 << c);
      core_setup(c, EU_BARR0 + BARR_STRIDE * c + BARR_TGT_MASK, 32'h1 << c);
    end
    rnd_active = 1'b1;
    fork rnd_storm(); rnd_periph(); rnd_toggle(); join_none
    fork
      rnd_core(0, ops);
      rnd_core(1, ops);
      rnd_core(2, ops);
      rnd_core(3, ops);
    join
    for (int unsigned c = 1; c < NB_CORES; c++)
      while ((disp_exp[c].size() != 0) && !rnd_abort[c]) rnd_wait(c, EVT_DISP, EU_DISP_FIFO);
    foreach (mutex_owner[m])
      if (mutex_owner[m] != -1) rnd_error($sformatf("M1: core %0d still owns mutex %0d at the end", mutex_owner[m], m));
    rnd_active = 1'b0;
    wait_cycles(RND_HANG / 10);
    $display("[%0t] INFO  T%0d random seed %0d: %0d ops per core, %0d dispatcher pushes", $time, id, seed, ops, disp_pushes);
    report(rnd_errors == 0, $sformatf("%0d error(s), first %s (seed %0d)", rnd_errors, rnd_first, seed));
  endtask

/*******************************************************/
/**                  Random Test End                  **/
/*******************************************************/
/**              Test Registry Beginning              **/
/*******************************************************/

  // ids are stable and used in the documents: a new test takes a new id
  typedef enum int unsigned {
    K_PLAIN, K_EVENT_IN_CLEAR, K_CLEAR_PUSH, K_CLEAR_UNLOCK, K_CLEAR_LOCK, K_CLEAR_BARRIER, K_WAIT_PUSH,
    K_CORE_BARRIER_MIX, K_PERIPH_MIX, K_WRITE_CONFLICT, K_IRQ_ACK, K_IRQ_WAIT, K_LOST_IN_CLEAR, K_RANDOM,
    K_MULTI_MUTEX, K_SOC_EVENTS, K_DEBUG_WAIT, K_CORE_BUSY, K_EVENT_SOURCES, K_PERIPH_RANGES, K_CORE_REGS,
    K_SW_EVENTS, K_BARRIER, K_DISPATCH_TEAMS, K_IRQ_PRIORITY, K_IRQ_WHILE_SLEEP, K_WAIT_VARIANTS, K_MUTEX_PRIORITY,
    K_DISPATCH_LAG
  } kind_e;
  typedef struct { int unsigned id; string name; kind_e kind; int unsigned arg; string rule; } test_t;
  test_t tests[$];

  function automatic void add(input int unsigned id, input string name, input kind_e kind, input int unsigned arg,
                              input string rule);
    tests.push_back('{id, name, kind, arg, rule});
  endfunction

  function automatic void register_tests();
    string mode[2] = '{".1out", ".2out"};
    string lost[6] = '{"wait_asleep", "wait_present", "sw_event", "barrier", "mutex_lock", "dispatch_pop"};
    for (int m = 0; m < 2; m++) begin
      add(10*m + 1, {"plain_accesses", mode[m]},           K_PLAIN,            m, "P1");
      add(10*m + 2, {"event_in_clear_cycle", mode[m]},     K_EVENT_IN_CLEAR,   m, "E1");
      add(10*m + 3, {"clear_then_dispatch_push", mode[m]}, K_CLEAR_PUSH,       m, "P2 D1");
      add(10*m + 4, {"clear_then_mutex_unlock", mode[m]},  K_CLEAR_UNLOCK,     m, "P2 M1");
      add(10*m + 5, {"clear_then_mutex_lock", mode[m]},    K_CLEAR_LOCK,       m, "P2 E2 M1");
      add(10*m + 6, {"clear_then_barrier_wait", mode[m]},  K_CLEAR_BARRIER,    m, "P2 E2 B1");
    end
    for (int m = 0; m < 2; m++) begin
      add(10*m + 7, {"wait_then_dispatch_push", mode[m]},  K_WAIT_PUSH,        m, "P2 D1");
      add(10*m + 8, {"core_barrier_mix", mode[m]},         K_CORE_BARRIER_MIX, m, "P1");
      add(10*m + 9, {"periph_mix", mode[m]},               K_PERIPH_MIX,       m, "P3");
    end
    add(21, "periph_direct_write_conflict.1out", K_WRITE_CONFLICT,  0, "P3");
    add(22, "periph_direct_write_conflict.2out", K_WRITE_CONFLICT,  1, "P3");
    add(23, "irq_ack_with_new_event",            K_IRQ_ACK,         0, "E1 I1");
    add(24, "irq_during_lw_wait",                K_IRQ_WAIT,        0, "S3");
    for (int k = 0; k < 6; k++) add(31 + k, {"lost_in_clear.", lost[k]}, K_LOST_IN_CLEAR, k, "E1");
    add(40, "random",                            K_RANDOM,          0, "all");
    add(41, "multi_mutex",                       K_MULTI_MUTEX,     0, "M1");
    add(42, "soc_events",                        K_SOC_EVENTS,      0, "SOC1 E1");
    add(43, "debug_during_wait",                 K_DEBUG_WAIT,      0, "S4");
    add(44, "core_busy",                         K_CORE_BUSY,       0, "S1 S2");
    add(45, "event_sources",                     K_EVENT_SOURCES,   0, "E3");
    add(46, "periph_ranges",                     K_PERIPH_RANGES,   0, "P4");
    add(50, "core_regs.direct",                  K_CORE_REGS,       0, "R1 E3");
    add(51, "core_regs.periph",                  K_CORE_REGS,       1, "R1 P3");
    add(52, "sw_events",                         K_SW_EVENTS,       0, "W1 S1");
    add(53, "barrier",                           K_BARRIER,         0, "B1 E2");
    add(54, "dispatch_teams",                    K_DISPATCH_TEAMS,  0, "D1");
    add(55, "irq_priority",                      K_IRQ_PRIORITY,    0, "I1 R1");
    add(56, "irq_while_sleep",                   K_IRQ_WHILE_SLEEP, 0, "S3 S1 S2");
    add(57, "wait_variants",                     K_WAIT_VARIANTS,   0, "E2 S2");
    add(58, "mutex_priority",                    K_MUTEX_PRIORITY,  0, "M1");
    add(59, "dispatch_lag",                      K_DISPATCH_LAG,    0, "D1");
  endfunction

  // * matches any string, ? any character
  function automatic bit glob(input string p, input string s);
    if (p.len() == 0) return s.len() == 0;
    if (p[0] == "*") return glob(p.substr(1, p.len() - 1), s) || ((s.len() != 0) && glob(p, s.substr(1, s.len() - 1)));
    if (s.len() == 0) return 1'b0;
    if ((p[0] == "?") || (p[0] == s[0])) return glob(p.substr(1, p.len() - 1), s.substr(1, s.len() - 1));
    return 1'b0;
  endfunction

  // patterns: comma-separated globs, empty for every test
  function automatic bit selected(input string patterns, input string name);
    int unsigned a = 0;
    if (patterns == "") return 1'b1;
    for (int unsigned i = 0; i <= patterns.len(); i++)
      if ((i == patterns.len()) || (patterns[i] == ",")) begin
        if ((i > a) && glob(patterns.substr(a, i - 1), name)) return 1'b1;
        a = i + 1;
      end
    return 1'b0;
  endfunction

  task automatic run(input test_t t, input int unsigned seed, input int unsigned ops);
    test_name = t.name;
    case (t.kind)
      K_PLAIN:            test_plain_accesses      (t.id, t.arg[0]);
      K_EVENT_IN_CLEAR:   test_event_in_clear_cycle(t.id, t.arg[0]);
      K_CLEAR_PUSH:       test_clear_then_push     (t.id, t.arg[0]);
      K_CLEAR_UNLOCK:     test_clear_then_unlock   (t.id, t.arg[0]);
      K_CLEAR_LOCK:       test_clear_then_lock     (t.id, t.arg[0]);
      K_CLEAR_BARRIER:    test_clear_then_barrier  (t.id, t.arg[0]);
      K_WAIT_PUSH:        test_wait_then_push      (t.id, t.arg[0]);
      K_CORE_BARRIER_MIX: test_core_barrier_mix    (t.id, t.arg[0]);
      K_PERIPH_MIX:       test_periph_mix          (t.id, t.arg[0]);
      K_WRITE_CONFLICT:   test_write_conflict      (t.id, t.arg[0]);
      K_IRQ_ACK:          test_irq_ack_new_event   (t.id);
      K_IRQ_WAIT:         test_irq_during_wait     (t.id);
      K_LOST_IN_CLEAR:    test_lost_in_clear       (t.id, t.arg);
      K_RANDOM:           test_random              (t.id, seed, ops);
      K_MULTI_MUTEX:      test_multi_mutex         (t.id);
      K_SOC_EVENTS:       test_soc_events          (t.id);
      K_DEBUG_WAIT:       test_debug_during_wait   (t.id);
      K_CORE_BUSY:        test_core_busy           (t.id);
      K_EVENT_SOURCES:    test_event_sources       (t.id);
      K_PERIPH_RANGES:    test_periph_ranges       (t.id);
      K_CORE_REGS:        test_core_regs           (t.id, t.arg[0]);
      K_SW_EVENTS:        test_sw_events           (t.id);
      K_BARRIER:          test_barrier             (t.id);
      K_DISPATCH_TEAMS:   test_dispatch_teams      (t.id);
      K_IRQ_PRIORITY:     test_irq_priority        (t.id);
      K_IRQ_WHILE_SLEEP:  test_irq_while_sleep     (t.id);
      K_WAIT_VARIANTS:    test_wait_variants       (t.id);
      K_MUTEX_PRIORITY:   test_mutex_priority      (t.id);
      K_DISPATCH_LAG:     test_dispatch_lag        (t.id);
      default:            $fatal(1, "test kind %0d has no task", t.kind);
    endcase
  endtask

  // +TEST=<globs> selects tests, +LIST prints them, +SEED and +OPS drive the random test, +VCD dumps the waves
  initial begin
    int unsigned protocol_errors, seed, ops, nb_run;
    string       patterns;

    register_tests();
    if ($test$plusargs("LIST")) begin
      $display("%-4s %-36s %s", "id", "name", "rules");
      foreach (tests[i]) $display("T%-3d %-36s %s", tests[i].id, tests[i].name, tests[i].rule);
      $finish;
    end
    if (!$value$plusargs("TEST=%s", patterns)) patterns = "";
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    if (!$value$plusargs("OPS=%d", ops)) ops = 150;
    if ($test$plusargs("VCD")) begin
      $dumpfile("tb_event_unit.vcd");
      $dumpvars(0, tb_event_unit);
    end
    results_fd = $fopen("results.txt", "w");

    nb_pass = 0; nb_fail = 0; nb_known = 0; nb_run = 0;
    foreach (tests[i]) if (selected(patterns, tests[i].name)) begin run(tests[i], seed, ops); nb_run++; end

    protocol_errors = CORE[0].driver_i.protocol_errors + CORE[1].driver_i.protocol_errors +
                      CORE[2].driver_i.protocol_errors + CORE[3].driver_i.protocol_errors + periph_i.protocol_errors;

    $display("---------------------------------------------------------------");
    if (nb_run == 0) $display("no test matches +TEST=%s (+LIST shows them)", patterns);
    $display("%0d passed, %0d failed, %0d known limitations, %0d protocol errors", nb_pass, nb_fail, nb_known, protocol_errors);
    $display("%s", ((nb_run != 0) && (nb_fail == 0) && (protocol_errors == 0)) ? "TEST PASSED" : "TEST FAILED");
    if (results_fd != 0) $fclose(results_fd);
    $finish;
  end

/*******************************************************/
/**                 Test Registry End                 **/
/*******************************************************/

endmodule // tb_event_unit
