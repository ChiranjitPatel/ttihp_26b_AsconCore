# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = project.v ascon_round.v

ifeq ($(SIM), icarus)
	VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
	COMPILE_ARGS += -DSIM
	COMPILE_ARGS += -g2012
else
    $(error This project only supports icarus)
endif

# TOPLEVEL is the name of the module to test
TOPLEVEL = tt_um_ascon_permutation

# MODULE is the basename of the Python test file
MODULE = test

include $(shell cocotb-config --makefiles)/Makefile.sim
