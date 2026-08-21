# Makefile
# Cocotb simulation for adaptive_fft_butterfly

# Defaults
SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog

# Source directory
SRC_DIR = $(PWD)/../src

# RTL DUT source
PROJECT_SOURCES = fft_DUT.v

ifneq ($(GATES),yes)

# ================================================================
# RTL simulation
# ================================================================

SIM_BUILD = sim_build/rtl

VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# ================================================================
# Gate-level simulation
# ================================================================

SIM_BUILD = sim_build/gl

COMPILE_ARGS += -DGL_TEST
COMPILE_ARGS += -DFUNCTIONAL
COMPILE_ARGS += -DUSE_POWER_PINS
COMPILE_ARGS += -DSIM
COMPILE_ARGS += -DUNIT_DELAY=\#1

VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

# This file is supplied by the GDS workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

VERILOG_SOURCES += $(SRC_DIR)/fft_DUT.v

endif

# Allow Verilog include files from src/
COMPILE_ARGS += -I$(SRC_DIR)

# Cocotb testbench
VERILOG_SOURCES += $(PWD)/tb.v

# Top-level Verilog module
TOPLEVEL = tb

# Python test module
COCOTB_TEST_MODULES = test

# Cocotb simulator rules
include $(shell cocotb-config --makefiles)/Makefile.sim
