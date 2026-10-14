# Event Unit Flex

This repository contains the event unit IP for the PULP cluster.

## Documentation

For documentation, please refer to the User Manual in the `doc` folder, as well as the following paper: [Energy-Efficient Hardware-Accelerated Synchronization for Shared-L1-Memory Multiprocessor Clusters](https://arxiv.org/pdf/2004.06662.pdf).

[`doc/event_unit_flex_behavior.md`](doc/event_unit_flex_behavior.md) lists the rules the RTL must follow, each tied to the manual, with the errata of the manual.

## Verification

[`tb/`](tb) holds a self-checking testbench, on Verilator or Questa, with directed tests for every feature, a random test and assertions for those rules. `make -C tb` runs everything; `make -C tb compare` compares the working tree with `master`; `make -C tb cov` lists the RTL lines no test reaches. See [`tb/README.md`](tb/README.md).
