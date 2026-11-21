CXX := clang++
CC  := clang
CACHE_DIR ?= $(shell python3 tools/bo3_paths.py --cache-dir)
ZYDIS_DIR ?= $(shell python3 tools/bo3_paths.py --zydis-dir)
ZYDIS_INC := $(ZYDIS_DIR)/amalgamated-dist
ZYDIS_OBJ := $(ZYDIS_DIR)/Zydis.o
MCPU      ?= $(shell python3 tools/bo3_paths.py --mcpu)

CXXFLAGS := -std=c++20 -O3 -DNDEBUG -mmacosx-version-min=13.0 -Wall -Wextra -Wno-unused-parameter -Ilifter -Iruntime
CFLAGS   := -O3 -DNDEBUG -mmacosx-version-min=13.0 -Wall -Wextra -Iruntime

BUILD_DIR := build

LIFTER_SRCS := lifter/macho_loader.cpp lifter/cfg.cpp lifter/ir_emitter.cpp lifter/ir_int.cpp lifter/ir_sse.cpp lifter/main.cpp
LIFTER_OBJS := $(patsubst lifter/%.cpp,$(BUILD_DIR)/lifter_%.o,$(LIFTER_SRCS))

.PHONY: all clean coverage app

all: $(BUILD_DIR)/bo3_lift $(BUILD_DIR)/bo3_loader

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/lifter_%.o: lifter/%.cpp lifter/macho_loader.h lifter/cfg.h lifter/ir_emitter.h runtime/cpu_state.h | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -I"$(ZYDIS_INC)" -c $< -o $@

$(BUILD_DIR)/bo3_lift: $(LIFTER_OBJS) | $(BUILD_DIR)
	@test -f "$(ZYDIS_OBJ)" || { echo "Error: Zydis.o missing at $(ZYDIS_OBJ) (run ./install.sh)" >&2; exit 1; }
	$(CXX) $(CXXFLAGS) -I"$(ZYDIS_INC)" $(LIFTER_OBJS) "$(ZYDIS_OBJ)" -o $@

$(BUILD_DIR)/bo3_loader: loader/bo3_loader.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -arch arm64 -mcpu=$(MCPU) $< -o $@

app: $(BUILD_DIR)/bo3_loader
	bash tools/build_app.sh

coverage: $(BUILD_DIR)/bo3_lift
	@BO3_EXE="$$(python3 tools/bo3_paths.py --exe)" && \
		./$(BUILD_DIR)/bo3_lift --coverage "$$BO3_EXE" --min-va 0x1004a0000 --max-va 0x1016263d8

clean:
	rm -rf $(BUILD_DIR)
