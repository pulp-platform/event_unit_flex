# Event unit testbench

A self-checking testbench for `event_unit_top`, on Verilator (default) or Questa. It checks the rules of [`doc/event_unit_flex_behavior.md`](../doc/event_unit_flex_behavior.md) (R1, P1, E1, M1, …) with directed tests for every feature, a constrained-random test and assertions bound into every `event_unit_core`.

## Running

```bash
make -C tb                          # all tests on the working-tree RTL
make -C tb TEST='*mutex*,random'    # only the tests whose name matches a glob (* and ?), comma separated
make -C tb list                     # id, name and rules of every test
make -C tb compare                  # working tree against master, test by test (REF=<git ref> for another ref)
make -C tb random SEEDS=50          # the random test with seeds 1..50
make -C tb cov                      # RTL line coverage, and the RTL lines that no test reaches
make -C tb waves TEST=barrier       # VCD in tb/build/work-tree/verilator/tb_event_unit.vcd
make -C tb RTL_REF=master           # the RTL of a git ref instead of the working tree
make -C tb SIM=questa ...           # any of the above on Questa
make -C tb clean
```

The console shows one line per test and a verdict; `make` exits with 1 if a test fails, so it can go in CI.

```
[...] PASS  T1 plain_accesses.1out
[...] FAIL  T12 event_in_clear_cycle.2out: event B lost, core 0 sleeps forever
[...] KNOWN T24 irq_during_lw_wait: _wait_clear returned 0x00000000 without any event of its mask: ...
43 passed, 0 failed, 2 known limitations, 0 protocol errors
TEST PASSED
```

| Status | Meaning |
|---|---|
| `PASS` | the checks of the test passed and no assertion fired while it ran |
| `FAIL` | a check failed or an assertion fired; the reason is on the same line |
| `KNOWN` | a known limitation of the design, documented in the spec (S3, D1.3); it does not fail the run |

On the `master` RTL 16 tests fail. Each failure is a deviation of the RTL from the spec, listed with its fix in [RTL deviations](../doc/event_unit_flex_behavior.md#rtl-deviations-from-these-rules). Verilator and Questa give the same status for every test.

### Checking a change

1. `make -C tb compare` runs every test on `master` and on the working tree and prints one row per test with both statuses. A change is safe when no row goes from `PASS` to `FAIL`; a fix turns a `FAIL` into `PASS`.
2. `make -C tb random SEEDS=50` runs the random test on more seeds.
3. `make -C tb cov` lists, as `rtl/<file>:<line>`, every RTL line that no test executes. New RTL that shows up there needs a test. Line coverage only says that a line ran, not that its effect was checked: a new test also has to check the result (see [Adding a test](#adding-a-test)).

The only lines `make cov` reports today are the unreachable `default` of the periph response mux in `event_unit_interface_mux.sv`.

### Tools

| Variable | Default | Use |
|---|---|---|
| `SIM` | `verilator` | `verilator` or `questa` |
| `TEST` | all | globs of the tests to run |
| `RTL_REF` | working tree | git ref whose `rtl/` is simulated (extracted with `git archive` into `build/<ref>/rtl`) |
| `REF` | `master` | the ref `make compare` compares against |
| `SEED`, `OPS` | `1`, `150` | seed and operations per core of the random test |
| `SEEDS` | `20` | number of seeds of `make random` |
| `VCD` | `0` | `1` dumps a VCD of the run |
| `VERILATOR_SETUP` | `module load verilator/5.052`, else `PATH` | command that puts `verilator` on the path |
| `QUESTA_SETUP` | `module load questa/2025.3`, else `PATH` | command that puts `vlog`/`vsim` on the path |
| `COMMON_CELLS` | `.bender/git/checkouts/common_cells-*` after `bender checkout`, else a clone of the `Bender.yml` version in `build/` | where `generic_fifo` and `onehot_to_bin` come from |

Verilator needs `--timing`, so version 5 and a C++20 compiler with coroutines; the flow is tested with 5.052. The build disables ccache: with Verilator's precompiled headers it can reuse an object of the other RTL and the simulation crashes at start.

Each RTL and simulator builds in `tb/build/<name>/<sim>/` (`work-tree/verilator`, `master/questa`, …): `transcript` is the whole simulation log, `results.txt` one line per test, `compile.log` the compiler output, `random_<seed>.log` the logs of `make random`. `make cov` builds in `<name>/verilator-cov/` and writes the annotated sources in its `annotated/` folder. The working tree recompiles only when a source or the Makefile changes; a ref recompiles at every run.

## What runs

| Id | Test | Rules | What it does |
|---|---|---|---|
| T1 / T11 | `plain_accesses.1out` / `.2out` | P1 | mask writes and reads back to back |
| T2 / T12 | `event_in_clear_cycle` | E1 | event B arrives in c1 of a `_wait_clear`; the next `_wait_clear` must return it |
| T3 / T13 | `clear_then_dispatch_push` | P2 D1 | `_wait_clear` followed by a dispatcher push: one value pushed |
| T4 / T14 | `clear_then_mutex_unlock` | P2 M1 | `_wait_clear` followed by an unlock: one waiting core gets the mutex |
| T5 / T15 | `clear_then_mutex_lock` | P2 E2 M1 | `_wait_clear` followed by a lock: the lock returns |
| T6 / T16 | `clear_then_barrier_wait` | P2 E2 B1 | `_wait_clear` followed by a barrier wait: the barrier event is returned |
| T7 / T17 | `wait_then_dispatch_push` | P2 D1 | `_wait` (no clear) followed by a dispatcher push |
| T8 / T18 | `core_barrier_mix` | P1 | core-unit and barrier-unit accesses interleaved, every read checked |
| T9 / T19 | `periph_mix` | P3 | periph-port accesses to core 0, core 1 and a barrier, every read checked |
| T21 / T22 | `periph_direct_write_conflict` | P3 | periph and direct-link writes to core 0's unit in the same cycles |
| T23 | `irq_ack_with_new_event` | E1 I1 | interrupt ack in the cycle the same event fires again |
| T24 | `irq_during_lw_wait` | S3 | interrupt during a `_wait_clear` done with a plain `lw` (`KNOWN`) |
| T31–T36 | `lost_in_clear.<read>` | E1 | E1 on every clearing read: `_wait_clear` asleep, `_wait_clear` with the event present, sw event, barrier, mutex lock, dispatcher pop |
| T40 | `random` | all | random traffic from 4 cores and the periph port, see below |
| T41 | `multi_mutex` | M1 | two mutexes: independent owners, waiters and messages |
| T42 | `soc_events` | SOC1 E1 | SoC event FIFO: bit 27 on every core while not empty, ids in order with the valid bit, `ready` when full |
| T43 | `debug_during_wait` | S4 | debug request during a wait: clock on, `core_dbg_req_o`, sleep and wake-up afterwards |
| T44 | `core_busy` | S1 S2 | no clock gating while `core_busy_i` is high, wake-up while busy |
| T45 | `event_sources` | E3 | accelerator, timer and DMA lines reach the bits of Table 1 of their core only |
| T46 | `periph_ranges` | P4 | every periph range answers reads and writes, also the read-only SoC event register and the inter-cluster range |
| T50 / T51 | `core_regs.direct` / `.periph` | R1 | every core unit register on one port: masks with `_and`/`_or`, `sw_events_mask` width, `status`, buffer views, `buffer_clear`, aliasing of the direct link |
| T52 | `sw_events` | W1 S1 | trigger writes with a core mask and with mask 0, periph triggers, `trigg_sw_event_wait(_clear)` with `sw_events_mask`, no second trigger while asleep |
| T53 | `barrier` | B1 E2 | a barrier of three cores for four: registers on both ports, status while it fills, trigger write, `trigger_self`, `_wait`, `_wait_clear`, periph trigger, a second barrier |
| T54 | `dispatch_teams` | D1 | team masks: a core skips the values of other teams, sleeps on an empty FIFO, pops in order across the wrap |
| T55 | `irq_priority` | I1 R1 | only irq-mask events raise an interrupt, the highest bit is reported, an ack clears only its bit, `irq_mask_and/or` on a full buffer |
| T56 | `irq_while_sleep` | S3 S1 S2 | a wait with an interrupt pending returns at once, the replay after the ack returns its event, the next wait sleeps |
| T57 | `wait_variants` | E2 S2 | `_wait` and `_wait_clear` with the event already there: no sleep, only `_wait_clear` clears and only the bits of the mask |
| T58 | `mutex_priority` | M1 | the waiting core with the lowest id gets the mutex, whatever the order of the locks |
| T59 | `dispatch_lag` | D1 | a core that does not pop for `DISP_FIFO_DEPTH` pushes loses its value (`KNOWN`, D1.3) |

`.1out` runs the cores with one outstanding transaction, `.2out` with two (the next request presented in the cycle after the grant). The ids are stable and are the ones used in the documents.

### The random test (T40)

Each core runs `OPS` operations picked at random: waits on cluster events, software events, barriers, critical sections on one of the two mutexes (sometimes with a `_wait_clear` before the unlock), dispatcher pushes from core 0 and pops, and bursts of non-blocking accesses. In the background, random event pulses hit the cores, the periph port writes and reads, and the cores switch between 1 and 2 outstanding transactions. A monitor checks M1 (one owner per mutex, unlock by the owner) and D1 (each push popped once, in order); any blocking read that takes more than `RND_HANG` cycles is a hang. At the end the traffic drains and the mutex must be free.

A failing seed prints its first error; rerun it with `make -C tb waves TEST=random SEED=<n>`.

### Assertions

[`eu_core_checker.sv`](eu_core_checker.sv) is bound into every `event_unit_core` and runs in every test:

| Assertion | Rule | Fires when |
|---|---|---|
| `a_write_needs_grant` | P2 | a direct-link write takes effect without `gnt` |
| `a_trigger_not_refused` | P2 | a trigger read fires in c1 of a clearing read |
| `a_clear_answers_read` | E2 | the buffer is cleared without a read granted in the cycle before |
| `a_event_kept` | E1 | an event active in a cycle is not in the buffer in the next one |

A failure prints `ASSERT <rule>: <message>` with the instance and fails the test that was running. [`eu_core_driver.sv`](eu_core_driver.sv) also checks the direct-link protocol (P1): `r_valid` exactly one cycle after every `gnt` and never otherwise, so one response per grant; the count is the `protocol errors` of the summary. On the periph port any latency is allowed and the tests check that every response arrives, in order.

## Adding a test

1. Write a task `test_<name>(input int unsigned id, ...)` in [`tb_event_unit.sv`](tb_event_unit.sv), in the section of its kind. Start it with `start_test(id, two_out)`, which resets the DUT; end it with `report(ok, why)`, or `report_known(ok, why)` for a documented limitation. The usual shape keeps the first failure in a string:

   ```systemverilog
   string why = "";
   start_test(id, 1'b0);
   core_setup(0, EU_MASK, EVT_A);
   expect_rd(why, 1'b0, 0, EU_MASK, EVT_A, "mask");
   report(why == "", why);
   ```

2. Use the helpers:
   - `expect_rd(why, periph, core, add, exp, what)`: a read on the direct link of `core` (or on the periph port with `periph = 1`) that must return `exp`; `expect_rsp(...)` waits only for the response of a read already queued; `expect_true(why, cond, msg)` for any other check;
   - `reg_wr(periph, core, add, wdata)`, `core_setup(core, add, wdata)`: a write and its response;
   - `core_read(core, add)`, `core_write(core, add, wdata)`: queue a direct-link access; `core_get_rsp(core, ok, rdata)` waits for the next response (`ok = 0` after `TIMEOUT` cycles); `core_nb_rsp(core)` counts the responses not consumed yet;
   - `periph_i.read/write/get_rsp`: the same on the periph port (offsets from `eu_base_addr`);
   - `expect_buffers(why, '{core0, core1, core2, core3}, what)` and `clear_buffers()`: the event buffers of all cores;
   - `pulse_event(core, EVT_*)`: a one-cycle pulse on a cluster event line; `irq_ack_pulse(core, id)`: an interrupt ack;
   - `soc_push(id)`: one id on the SoC peripheral event bus; `core_busy`, `dbg_req`, `acc_events`, `dma_events`, `timer_events` drive the other inputs (all back to 0 at every `start_test`);
   - `wait_sleep(core)`, `wait_grant(core, add)`, `wait_cycles(n)`.
3. Add a kind to `kind_e`, a line in `run`, and a line in `register_tests` with a new id and the rules it checks.
4. If the test checks a rule that is not in the spec, add the rule to [`doc/event_unit_flex_behavior.md`](../doc/event_unit_flex_behavior.md) with its source in the manual, and add the test to its traceability table.
5. Run `make -C tb compare` and check that the new test fails on an RTL with the bug and passes on the fixed one; run it on both simulators.

Register offsets (`EU_*`, `BARR_*`, `PER_*`) and event bits (`EVT_*`) are at the top of the testbench. Event bits follow [`cluster_event_map.sv`](cluster_event_map.sv): software events 7:0, barrier 16, mutex 17, dispatcher 18, cluster events 22 and up.

## Files

| File | Content |
|---|---|
| [`Makefile`](Makefile) | compilation on both simulators, runs, comparison, seeds, coverage |
| [`tb_event_unit.sv`](tb_event_unit.sv) | testbench: DUT, protocol tests, feature tests, random test, registry |
| [`eu_core_driver.sv`](eu_core_driver.sv) | bus master model with outstanding transactions and protocol check |
| [`eu_core_checker.sv`](eu_core_checker.sv), [`eu_tb_pkg.sv`](eu_tb_pkg.sv) | assertions and their failure counter |
| [`cluster_event_map.sv`](cluster_event_map.sv), [`xbar_periph_bus.sv`](xbar_periph_bus.sv), [`cluster_clock_gating.sv`](cluster_clock_gating.sv) | testbench copies of `pulp_cluster` dependencies |

Not covered: inter-cluster messages, which have no unit and no port in `event_unit_top` (T46 checks only that their range answers), and `test_mode_i`. The testbench runs one parameter set: 4 cores, 4 barriers, 8 software events, 2 mutexes, 8-entry dispatcher and SoC FIFOs.
