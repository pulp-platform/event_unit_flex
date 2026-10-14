// Copyright 2026 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Shared state of the event unit testbench: the assertion failures, counted so that each test can tell its own

package eu_tb_pkg;

  int unsigned assert_errors = 0;
  string       assert_first  = "";

  // called by the assertions of eu_core_checker; the rule id refers to doc/event_unit_flex_behavior.md
  function automatic void assert_fail(input string rule, input string msg);
    assert_errors++;
    if (assert_first == "") assert_first = $sformatf("%s: %s", rule, msg);
    $display("[%0t] ASSERT %s: %s", $time, rule, msg);
  endfunction

endpackage
