# Event Unit Flex: behavior specification

This document lists the rules that `event_unit_flex` must follow and how the testbench in [`tb/`](../tb) checks each one. It refines the official manual, [`event_unit_flex_r41.pdf`](event_unit_flex_r41.pdf) (Rev. 4.1, 6 Oct 2017), and does not replace it. Register addresses, bit fields and reset values are in the manual.

Each rule has a source:

- **Stated:** the manual says it. The rule only restates it in testable form, with the page.
- **Clarification:** the manual is silent or ambiguous. The rule fixes what the RTL must do, and nothing in the manual contradicts it.
- **Erratum:** the manual says something else. The rule is what the RTL does, and the manual text should be corrected (see [Errata of the manual](#errata-of-the-manual)).
- **Beyond the manual:** a unit that the manual does not describe. The rule comes from the RTL.

When the RTL breaks a rule, that is a bug in the RTL. When the RTL and the manual disagree on something the manual states, the disagreement goes to the errata with a decision.

## Terms

| Term | Meaning |
|---|---|
| direct link | the per-core slave port on the peripheral demux of the core (`eu_direct_link`, manual p. 5: "peripheral demux link"). Its addresses are relative to `eu_demux_base_addr` and aliased to the issuing core |
| periph port | the slave port on the cluster peripheral interconnect (`speriph_slave`), relative to `eu_base_addr`. Not available for registers that put the core to sleep (p. 12) |
| sleep read | a direct-link read that may put the core to sleep: `eu_core_event_wait` (`0x38`), `eu_core_event_wait_clear` (`0x3C`), `eu_core_trigg_sw_event_wait` (`0x140 + 4j`), `eu_core_trigg_sw_event_wait_clear` (`0x180 + 4j`), `hw_barr_trigger_wait` (`0x218 + 0x20b`), `hw_barr_trigger_wait_clear` (`0x21C + 0x20b`), mutex lock (`0xC0 + 4m`), dispatcher pop (`0x80`) |
| clearing read | a sleep read that clears the buffer when it returns: the `_wait_clear` variants, mutex lock, dispatcher pop |
| cycle c0, c1 | c0 is the cycle in which a read is granted, c1 the next one, in which its response (`r_valid`) arrives. For a clearing read the buffer is cleared at the end of c1 |
| 1 / 2 outstanding | a master that presents its next request after the response (1) or right after the grant, in c1 (2). The CV32E40X and the cv32e40p LSU (`DEPTH = 2`) do the latter with a plain `lw` followed by an independent load or store |

## Rules

### P · Protocol

**P1 · Direct-link transactions** (Clarification of p. 5 and p. 10)

1. A request stays asserted, with the same address, `wen` and data, until it is granted.
2. Every granted request gets exactly one response, with `r_valid` one cycle after `gnt`. Responses come back in request order.
3. A non-blocking access (any access that is not a sleep read) is granted in the cycle it is presented, except in c1 of a clearing read (P2).
4. A sleep read is granted only when its wake condition holds (S2). Until then `gnt` stays low (p. 10, step 1).
5. Rules 1–4 hold for a master with 1 or 2 outstanding transactions.

The manual describes a single-cycle demux access (p. 5) and a sleep read that is not granted until wake-up (p. 10). It assumes `p.elw`, issued from the WB stage with no request behind it, and does not mention a second outstanding request. Rule 5 makes that case explicit.

**P2 · No effect without a grant** (Clarification)

A direct-link request has no effect in a cycle in which it is not granted: no register write, no software-event, barrier, mutex or dispatcher trigger, no clock gating and no buffer clear. The effect happens once, in the cycle the request is granted.

In particular, in c1 of a clearing read the unit does not grant a new request, so a request presented in c1 (2 outstanding) has no effect in c1 and takes effect when it is granted later.

On `master` this rule is broken in c1: writes are decoded (dispatcher push applied twice, mutex unlocked twice), a sleep read gates the clock and is then cleared without a response, and trigger reads fire.

**P3 · Periph port** (Stated, p. 12)

1. All registers except those that put a core to sleep can be accessed from the periph port (p. 12). Responses come back in order.
2. When the periph port and the direct link write the same `event_unit_core` in the same cycle, the direct-link write is applied first (p. 12: "the access from the peripheral demux port gets prioritized"). The periph write is not granted in that cycle; it is granted later and then applied. No write is lost.

The RTL also decodes the refused periph write in the conflict cycle (`we_interc` without `p_interc_gnt`), so it is applied once in that cycle and again when it is granted. Every `event_unit_core` register reachable from the periph port is idempotent (masks, `_and`/`_or`, `buffer_clear`, `sw_events_mask`), so the result is the same. A new non-idempotent register on this port would break rule 2.

**P4 · Every periph range answers** (Clarification of p. 12 and section 1.3.4)

Every access in the periph address space of the unit (`eu_base_addr` to `+ 0x7FF`) is granted and answered, with one response per request. A read of a register that does not exist, or of a range without a unit, returns 0; a write to a read-only register or to such a range has no effect. In particular:

1. a write to `eu_core_current_event` (`+ 0x700`, read-only, p. 22) is answered and does not pop the FIFO;
2. accesses to `eu_cluster_message_base_addr` (`+ 0x780`, p. 12) are answered, although inter-cluster messages are not implemented (sections 1.3.2 and 1.3.4 describe them as future work, and `event_unit_top` has no port for them).

A request that is never answered blocks the bus master, and with it every later access through the periph port. On `master` both cases hang.

### R · Registers

**R1 · Core unit registers** (Stated, p. 14–18; Clarification of the width of `eu_core_sw_events_mask`)

1. `eu_core_mask`, `eu_core_mask_irq` and `eu_core_sw_events_mask` read back the value last written. A write to their `_and` register clears the bits set in the data, a write to their `_or` register sets them (p. 14, 15, 16, 18).
2. `eu_core_sw_events_mask` holds one bit per core (`NB_CORES` bits); the bits above read 0. The manual gives 16 bits, the maximum number of cores (p. 18).
3. `eu_core_status` bit 0 reads 1 while the clock of the core runs and 0 while it is gated (p. 16).
4. `eu_core_buffer_masked` reads `buffer & mask`, `eu_core_buffer_irq_masked` reads `buffer & mask_irq` (p. 17). A write to `eu_core_buffer_clear` clears the bits set in the data, subject to E1 (p. 17).
5. The direct link reaches the unit of the issuing core only; the periph port reaches the unit of core `c` at `0x40*c` (p. 13). Every register of this list answers on both ports.

### E · Event buffer

**E1 · No event is lost** (Stated, p. 7 and p. 16; Erratum of p. 17)

An event line active in cycle t sets its bit in `eu_core_buffer` at the end of t, whatever else updates the buffer in t: the clear of a clearing read, a write to `eu_core_buffer_clear`, or an interrupt acknowledge. A clear only removes events that were in the buffer before t.

The manual states that the buffer "stores all incoming events, regardless of which event lines are masked" (p. 7) and that a buffer bit read as 1 means at least one event "since the bit was cleared" (p. 16). For `eu_core_buffer_clear` it says the opposite of E1: "If the corresponding event line is active in the same cycle where the clear operation gets effective, the bit still does get cleared to 0" (p. 17). The RTL, on `master` too, keeps the event for `buffer_clear`. The decision is to keep the event everywhere; see [erratum 1](#erratum-1--p-17-eu_core_buffer_clear).

On `master` E1 is broken for clearing reads (an event arriving in c1 is cleared without ever being returned) and for interrupt acknowledges (a new occurrence of the acknowledged event in the ack cycle is cleared).

**E2 · Clearing reads** (Stated, p. 19, p. 21, p. 24; Clarification for mutex and dispatcher)

1. The response of a sleep read carries `eu_core_buffer_masked` (`buffer & mask`) of the issuing core at wake-up (p. 19, p. 21, p. 24). The mutex lock instead returns the message of the last unlock (M1), and the dispatcher pop the popped value (D1).
2. A clearing read clears the bits of `eu_core_buffer` that are set in `eu_core_mask`, at the end of c1 (p. 19: "cleared to 0 after the read"), subject to E1.
3. The clear happens only for a read that was granted in c0, whether or not the core slept first. The manual says "following a sleep period" for `hw_barr_trigger_wait_clear` (p. 24); when the barrier event is already there the read is granted at once and the clear still happens.
4. Mutex lock and dispatcher pop are clearing reads (RTL: "hw mutex units - always _wait_clear"). The manual does not say so.

**E3 · Event lines** (Stated, Table 1 p. 9)

Each event source sets the bit of Table 1 in the buffer of the cores it targets: software events 7:0, DMA 9:8, timers 11:10, accelerators 15:12, barriers 16, mutexes 17, dispatcher 18, SoC peripheral events 27. Lines marked individual per core in Table 1 reach only their core. The map is built by `cluster_event_map` (outside this IP, testbench copy in [`tb/cluster_event_map.sv`](../tb/cluster_event_map.sv)); see [erratum 2](#erratum-2--p-7-section-133-and-p-1416-bit-of-the-soc-peripheral-event) for bit 27.

**SOC1 · SoC peripheral event FIFO** (Stated, section 1.3.3 p. 7 and p. 22; Clarification of the level)

1. An id transferred on the SoC event bus (`valid` and `ready` high at a rising edge, p. 7) is stored in the 8-entry FIFO.
2. `ready` is low while the FIFO is full; an id offered then is stored once there is room (the producer keeps `valid` high, p. 7).
3. A periph read of `eu_core_current_event` returns the oldest id in bits 7:0 with bit 31 set, and removes it. On an empty FIFO bit 31 reads 0 (p. 22).
4. The SoC event bit of every core is set as long as the FIFO holds at least one id. A clear of that bit while the FIFO is not empty has no effect (E1); after the FIFO is emptied the bit can be cleared. The manual only says the bit is set when an id arrives (p. 7).

### S · Sleep and wake-up

**S1 · Going to sleep** (Stated, p. 7 and p. 10)

A sleep read issued when `buffer & mask == 0` and no interrupt is pending is not granted, and the clock of the core is gated (`core_clock_en_o = 0`, `eu_core_status` bit 0 reads 0, p. 16). While `core_busy_i` is high the clock is not gated: the read waits without a grant with the clock running, and an event arriving meanwhile completes it as in S2 (Clarification: the manual does not describe `core_busy_i`). The software-event or barrier trigger of a `trigg_*_wait` read fires once, when the read is first presented and accepted for triggering, not again while the core sleeps.

**S2 · Waking up** (Stated, p. 10)

When `buffer & mask != 0` the clock is enabled and the pending sleep read is granted in the same cycle; its response follows in c1 (P1). If an enabled event is already in the buffer when the sleep read arrives, the read is granted at once without sleeping ("event already triggered while going to sleep").

**S3 · Interrupts during a wait** (Stated, p. 10–11)

When an interrupt enabled in `eu_core_mask_irq` becomes pending during a wait, the clock is enabled so that the core can take it (p. 10). Returning to the wait after the handler is the job of the core: `p.elw` replays the wait (p. 10, section 2.1). With a plain `lw` the wait can complete without any event of its mask: this is a known limitation, not a bug, and software must treat such a return as spurious and wait again. Waiting on an event and taking an interrupt on the same event line at the same time is not supported (p. 11, corner case 1).

**S4 · Debug requests during a wait** (Clarification: the manual does not describe debug)

`core_dbg_req_o` follows `dbg_req_i` one cycle later. A debug request during a wait has the effect of an interrupt (S3): the clock is enabled and the pending sleep read completes, with `buffer & mask` and without clearing. Once the request is gone, a new sleep read gates the clock again and wakes up on its events.

**I1 · Interrupt request and acknowledge** (Stated, p. 15 and p. 11; Clarification of the ack)

`core_irq_req_o` is raised when `buffer & mask_irq != 0`, with `core_irq_id_o` the highest such bit. An acknowledge with `core_irq_ack_id_i = k` clears bit k of the buffer (p. 11: the handler "must clear the bit in the buffer by which it has been triggered"; in the RTL the ack does it). A new occurrence of event k in the ack cycle stays in the buffer and raises the interrupt again (E1).

### Units

**M1 · HW mutex** (Stated, p. 9 and p. 20)

1. A read of `eu_core_hw_mutex` locks the mutex if it is free and returns at once; otherwise the core sleeps until the mutex is assigned to it (p. 9).
2. A write unlocks the mutex; if cores are waiting, the one with the lowest core id gets it and is woken by the mutex event (bit 17). The written value is returned as read data to that core (p. 9, p. 20).
3. At any time at most one core owns each mutex. Mutexes are independent: locking, waiting on and unlocking one does not affect the others. The mutex events of all mutexes of a core share bit 17. The runtimes use one mutex (p. 9); the testbench instantiates two.
4. Illegal unlocks (by a core that does not own the mutex) are not prevented by the hardware (p. 9, p. 20). The testbench never issues them; the RTL checkers under `` `ifdef SIM `` in `hw_mutex_unit.sv` report them.

**D1 · HW dispatcher** (Beyond the manual: only event line 18, p. 9, and address `0x80`, p. 12)

1. A direct-link write to `0x80` pushes one value for every core in the team mask (`0x84`); a read of `0x80` pops the next value for the issuing core and sleeps while there is none.
2. Each pushed value is popped exactly once by each core of its team, in push order.
3. Known limitation: a core moves its read pointer, skipping the values of other teams, only while it pops. After `DISP_FIFO_DEPTH` pushes without a pop of that core its pointer equals the write pointer again, the FIFO looks empty to it and the values for it are lost, even if fewer than `DISP_FIFO_DEPTH` of them are pending. Software must keep every core within `DISP_FIFO_DEPTH - 1` pushes, counting the pushes for other teams. The RTL has no overflow management (`hw_dispatch.sv`).

**B1 · HW barriers** (Stated, p. 8 and p. 22–24)

1. Triggering (write to `hw_barr_trigger`, read of `hw_barr_trigger_self`/`_wait`/`_wait_clear`) sets the status bit of the core.
2. When `status` matches `trigger_mask`, the barrier event (bit 16) goes to every core in `target_mask` and `status` returns to 0 in the same step.
3. The barrier events of all barrier units are ORed per core (p. 8).
4. Barrier registers are readable and writable from both ports with the values written (p. 22–23).

**W1 · Software events** (Stated, p. 8, p. 18, p. 21)

1. A write of mask `m` to `eu_core_trigg_sw_event` j sets bit j in the buffer of every core whose bit is set in `m` (p. 21).
2. A read of `trigg_sw_event_wait(_clear)` j triggers event j for the cores in `eu_core_sw_events_mask` of the issuing core, then behaves as `event_wait(_clear)` (p. 21).
3. The same software event must not be sent to one core by two cores in the same cycle (p. 8); the testbench does not do it.

## Errata of the manual

### Erratum 1 · p. 17, `eu_core_buffer_clear`

- **Manual:** "If the corresponding event line is active in the same cycle where the clear operation gets effective, the bit still does get cleared to 0."
- **RTL (`master` and fixed):** the bit stays set; the event is kept.
- **Decision:** the RTL is right. Clearing an event that has just arrived loses it without software ever seeing it, which contradicts p. 7 and p. 16. E1 applies to every clear.
- **Corrected text:** "If the corresponding event line is active in the same cycle where the clear operation gets effective, the bit stays set to 1: the new event is not lost."

### Erratum 2 · p. 7 (section 1.3.3) and p. 14–16, bit of the SoC peripheral event

Section 1.3.3 and the bit tables of `eu_core_mask`, `eu_core_mask_irq` and `eu_core_buffer` put SoC peripheral events on bit 31 and inter-cluster messages on bit 30. Table 1 (p. 9) puts SoC peripheral events on bit 27 and inter-cluster messages on bit 31. The event map is built outside this IP (`cluster_event_map` in `pulp_cluster`, copied in [`tb/cluster_event_map.sv`](../tb/cluster_event_map.sv)), which follows Table 1: the SoC event is bit 27. Table 1 is the reference.

### Erratum 3 · p. 24, `hw_barr_trigger_wait_clear`

"after its contents have been read, following a sleep period": the clear happens also when the read returns without sleeping (E2.3).

### Omissions

- A second outstanding request on the direct link (P1.5, P2).
- Mutex lock and dispatcher pop clear the buffer like `_wait_clear` (E2.4).
- The HW dispatcher (D1) has no register description.
- Which interrupt is reported when several are pending (I1: the highest bit).

## Traceability

Every test runs on every RTL; every assertion is bound into every `event_unit_core` in every test. `make -C tb compare` prints the status of each test on two RTLs. The last column is the RTL with the changes listed in [RTL deviations](#rtl-deviations-from-these-rules).

| Rule | Tests | Assertions (`tb/eu_core_checker.sv`) and monitors | `master` | with the changes |
|---|---|---|---|---|
| P1 | T1, T11, T8, T18, T40 | direct-link protocol check in `eu_core_driver` (`r_valid` exactly one cycle after every `gnt`) | pass | pass |
| P2 | T3–T7, T13–T17, T40 | `a_write_needs_grant`, `a_trigger_not_refused` | **fail** (T13–T16) | pass |
| P3 | T9, T19, T21, T22, T40 | read-back of every periph access | pass | pass |
| P4 | T46 | every access answered within `TIMEOUT` | **fail** | pass |
| R1 | T50, T51, T55 | read-back of every core unit register on both ports, `core_irq_req_o` | pass | pass |
| E1 | T2, T12, T23, T31–T36, T40, T42 | `a_event_kept` | **fail** | pass |
| E2 | T5, T6, T15, T16, T31–T36, T53, T57 | `a_clear_answers_read` | **fail** (T15, T16) | pass |
| E3 | T45, and bits 16–18, 7:0, 27 in the unit tests | buffer read-back per core | pass | pass |
| SOC1 | T42 | FIFO order, valid bit, `ready`, bit 27 | **fail** (E1 on bit 27) | pass |
| S1, S2 | every wait in T2–T7, T12–T17, T31–T36, T40; T44 for `core_busy_i`; T56, T57 | hang detection (`TIMEOUT`, `RND_HANG`), `core_clock_en_o` | pass with 1 outstanding | pass |
| S3 | T24, T56 | T24 reported as `KNOWN`; T56: wait with an interrupt pending, replay after the ack | known | known |
| S4 | T43 | `core_clock_en_o`, `core_dbg_req_o`, wait after debug | pass | pass |
| I1 | T23, T55 | buffer and `core_irq_req_o` after the ack | **fail** | pass |
| M1 | T4, T5, T14, T15, T35, T40, T41, T58 | random-test monitor: one owner per mutex, unlock by the owner | **fail** (T14, T40) | pass |
| D1 | T3, T7, T13, T17, T36, T40, T54; T59 (D1.3) reported as `KNOWN` | random-test monitor: each push popped once, in order | **fail** (T13) | pass |
| B1 | T6, T8, T16, T18, T34, T40, T53 | read-back, barrier event | **fail** (T16) | pass |
| W1 | T33, T40, T52 | software-event wake-ups | **fail** (T33, E1) | pass |

Not covered: inter-cluster messages, which have no unit and no port (P4 checks only that their range answers); `test_mode_i`; other parameter sets than 4 cores, 4 barriers, 8 software events and 2 mutexes. `make -C tb cov` lists the RTL lines that no test reaches. See [`tb/README.md`](../tb/README.md) to add tests.

## RTL deviations from these rules

On `master` (`763c3b9`) 27 tests pass, 16 fail and T24 and T59 are `KNOWN`. Every failure comes from one of the deviations below; with the changes in the last column, all 43 tests pass and T24 and T59 stay `KNOWN`.

| Deviation on `master` | Rules | Tests | Change |
|---|---|---|---|
| a write presented in c1 of a clearing read is decoded although it is not granted | P2 | T13, T14 | `event_unit_core`: no write decoded in c1 |
| a trigger read presented in c1 fires although it is not granted | P2 | T16 | `event_unit_core`: no trigger in c1 |
| a sleep read presented in c1 gates the clock and is later cleared without a response | P2, E2.3 | T15, T16 | `event_unit_core`: `stop_core_clock` low in c1 |
| the clear of a clearing read removes the events arriving in its cycle | E1 | T2, T12, T31–T36, T42 | `event_unit_core`: the clear keeps the incoming events |
| the interrupt-ack clear removes a new occurrence of the same event | E1, I1 | T23 | `event_unit_core`: ack clear before the incoming events, in every buffer update |
| a periph write to `eu_core_current_event` is granted and never answered | P4 | T46 | `soc_periph_fifo`: answer writes, ignore them |
| periph accesses to the inter-cluster range are never granted | P4 | T46 | `event_unit_top`: grant and answer with 0 |

The first five deviations show only when a request reaches the unit in c1, that is with two outstanding transactions (a plain `lw` followed by an independent load or store on the CV32E40X or the cv32e40p LSU), or when an event arrives in c1. The last two hang the periph bus. The random test (T40) runs into several of them.
