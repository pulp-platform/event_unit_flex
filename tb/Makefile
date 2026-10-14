# Copyright 2026 ETH Zurich and University of Bologna.
# Copyright and related rights are licensed under the Solderpad Hardware
# License, Version 0.51 (the "License"); you may not use this file except in
# compliance with the License.  You may obtain a copy of the License at
# http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
# or agreed to in writing, software, hardware and materials distributed under
# this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied. See the License for the
# specific language governing permissions and limitations under the License.

# Event unit testbench on Verilator (default) or Questa. See tb/README.md.
#
#   make                         all tests on the RTL of the working tree
#   make TEST='*mutex*,random'   the tests whose name matches one of the globs
#   make list                    the tests, with their id and the rules they check
#   make RTL_REF=master          the RTL of a git ref instead of the working tree
#   make compare [REF=master]    the working tree against a ref, test by test
#   make random SEEDS=50         the random test with seeds 1..50
#   make waves TEST=<name>       a VCD of the selected tests
#   make cov                     RTL line coverage of all tests and the RTL lines no test reaches (Verilator)
#   make SIM=questa ...          any of the above on Questa
#
# Options: SEED=<n> OPS=<ops per core> for the random test, VCD=1 for a VCD of any run.

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
SIM  ?= verilator

# tools from Environment Modules when available, else from PATH
QUESTA_SETUP    ?= { source /usr/share/Modules/init/bash && module load questa/2025.3; } > /dev/null 2>&1; true
VERILATOR_SETUP ?= { source /usr/share/Modules/init/bash && module load verilator/5.052; } > /dev/null 2>&1; true

# common_cells: the checkout of `bender checkout`, else a clone of the version in Bender.yml
CC_VERSION   := v$(shell sed -n 's/.*common_cells:.*version: *\([0-9.]*\).*/\1/p' $(ROOT)/Bender.yml)
CC_CLONE     := $(ROOT)/tb/build/common_cells-$(CC_VERSION)
COMMON_CELLS ?= $(firstword $(wildcard $(ROOT)/.bender/git/checkouts/common_cells-*) $(CC_CLONE))

RTL_REF ?=
REF     ?= master
TEST    ?=
SEED    ?= 1
OPS     ?= 150
SEEDS   ?= 20
VCD     ?= 0
COV     ?= 0

SHELL := /bin/bash

ifeq ($(RTL_REF),)
  NAME    := work-tree
  RTL_DIR := $(ROOT)/rtl
else
  NAME    := $(subst /,_,$(RTL_REF))
  RTL_DIR := $(ROOT)/tb/build/$(NAME)/rtl
endif

BUILD := $(ROOT)/tb/build/$(NAME)/$(SIM)$(if $(filter 1,$(COV)),-cov)

rtl_files := event_unit_core.sv hw_barrier_unit.sv hw_dispatch.sv hw_mutex_unit.sv interc_sw_evt_trig.sv \
             periph_FIFO_id.sv soc_periph_fifo.sv event_unit_interface_mux.sv event_unit_top.sv
tb_deps   := eu_tb_pkg.sv xbar_periph_bus.sv cluster_event_map.sv cluster_clock_gating.sv eu_core_checker.sv
tb_top    := eu_core_driver.sv tb_event_unit.sv
cc_files  := src/deprecated/generic_fifo.sv src/onehot_to_bin.sv

own_srcs := $(addprefix $(ROOT)/tb/,$(tb_deps) $(tb_top)) $(addprefix $(RTL_DIR)/,$(rtl_files))
srcs     := $(addprefix $(ROOT)/tb/,$(tb_deps)) $(addprefix $(COMMON_CELLS)/,$(cc_files)) \
            $(addprefix $(RTL_DIR)/,$(rtl_files)) $(addprefix $(ROOT)/tb/,$(tb_top))

plusargs := +SEED=$(SEED) +OPS=$(OPS) $(if $(TEST),+TEST=$(TEST)) $(if $(filter 1,$(VCD)),+VCD)

ifeq ($(SIM),questa)
  COMPILE = $(QUESTA_SETUP) && rm -rf work && vlib work > /dev/null && \
            vlog -sv -quiet -suppress 2583 -timescale 1ns/1ps +incdir+$(COMMON_CELLS)/include $(srcs)
  RUN     = $(QUESTA_SETUP) && vsim -c -quiet -voptargs=+acc tb_event_unit -do "run -all; quit -f"
else ifeq ($(SIM),verilator)
  VL_FLAGS := --binary --timing --assert --trace -j 0 --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style \
              $(if $(filter 1,$(COV)),--coverage-line) --top-module tb_event_unit -Mdir obj
  COMPILE = $(VERILATOR_SETUP) && rm -rf obj && CCACHE_DISABLE=1 verilator $(VL_FLAGS) +incdir+$(COMMON_CELLS)/include $(srcs)
  RUN     = ./obj/Vtb_event_unit
else
  $(error SIM must be verilator or questa)
endif

# simulator output, with Questa's "# " prefix removed
SHOW := sed 's/^\# //'

.PHONY: all test compile list compare random waves cov rtl clean help

all: test

help:
	@sed -n '/^# Event unit/,/^$$/p' $(lastword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'

$(CC_CLONE):
	git clone -q -c advice.detachedHead=false --depth 1 -b $(CC_VERSION) https://github.com/pulp-platform/common_cells.git $@

# a ref is extracted again at every run, the working tree is compiled only when a source changed
rtl:
	@mkdir -p $(BUILD)
ifneq ($(RTL_REF),)
	@git -C $(ROOT) archive $(RTL_REF) rtl | tar -x -C $(ROOT)/tb/build/$(NAME)
endif

$(BUILD)/compiled: $(own_srcs) $(ROOT)/tb/Makefile | rtl $(COMMON_CELLS)
	@cd $(BUILD) && { $(COMPILE); } > compile.log 2>&1 || { cat compile.log; exit 1; }
	@touch $@

compile: rtl $(BUILD)/compiled

# the transcript keeps the whole run; the console shows one line per test and the verdict; exit 1 on a failure
test: compile
	@cd $(BUILD) && { $(RUN) $(plusargs); } > transcript 2>&1; $(SHOW) transcript | \
	  grep -E "^\[.*\] (PASS|FAIL|KNOWN|INFO|ASSERT|ERROR)|passed, |no test matches|^TEST "; \
	  echo "results: $(BUILD)/results.txt"; grep -q "^\(# \)\{0,1\}TEST PASSED" transcript

list: compile
	@cd $(BUILD) && { $(RUN) +LIST; } 2>&1 | $(SHOW) | grep -E "^(id |T[0-9])"

# the working tree against REF: one row per test, the status on both
compare:
	@$(MAKE) --no-print-directory RTL_REF=$(REF) test > /dev/null 2>&1 || true
	@$(MAKE) --no-print-directory RTL_REF= test > /dev/null 2>&1 || true
	@printf "%-4s %-36s %-8s %s\n" id test "$(REF)" work-tree
	@join -j 1 <(awk '{print $$2, $$1, $$3}' $(ROOT)/tb/build/$(subst /,_,$(REF))/$(SIM)/results.txt | sort -k1,1) \
	           <(awk '{print $$2, $$1}' $(ROOT)/tb/build/work-tree/$(SIM)/results.txt | sort -k1,1) | sort -V | \
	  awk '{printf "%-4s %-36s %-8s %s\n", $$1, $$3, $$2, $$4}'

# the random test with seeds 1..SEEDS; the failing seeds are listed, rerun one with make TEST=random SEED=<n> VCD=1
random: compile
	@fail=""; for s in $$(seq 1 $(SEEDS)); do \
	  ( cd $(BUILD) && { $(RUN) +TEST=random +SEED=$$s +OPS=$(OPS); } > random_$$s.log 2>&1 ); \
	  if grep -q "^\(# \)\{0,1\}TEST PASSED" $(BUILD)/random_$$s.log; then printf "."; else printf "F"; fail="$$fail $$s"; fi; done; echo; \
	  if [ -z "$$fail" ]; then echo "random: $(SEEDS) seeds passed"; else echo "random: failing seeds:$$fail (logs in $(BUILD)/random_<seed>.log)"; exit 1; fi

waves:
	@$(MAKE) --no-print-directory test VCD=1; echo "waves: $(BUILD)/tb_event_unit.vcd"

# every RTL line with a count of 0 is printed as file:line; annotated sources in <build>/annotated
cov:
	@$(MAKE) --no-print-directory SIM=verilator COV=1 test || true
	@cd $(ROOT)/tb/build/$(NAME)/verilator-cov && $(VERILATOR_SETUP) && rm -rf annotated && \
	  verilator_coverage --annotate annotated --annotate-min 1 coverage.dat | grep "lines with" ; \
	  for f in $(rtl_files); do [ -f annotated/$$f ] && grep -nE "^%0+ " annotated/$$f | sed "s|^|rtl/$$f:|"; done; \
	  echo "annotated: $(ROOT)/tb/build/$(NAME)/verilator-cov/annotated"

clean:
	rm -rf $(ROOT)/tb/build
