# VfdPEQ engine — clang++, no external deps
CXX      := clang++
SDK      := $(shell xcrun --show-sdk-path)
BUILD    := build

CXXFLAGS := -std=c++20 -arch arm64 -O2 -Wall -Wextra \
	-isysroot $(SDK) -mmacosx-version-min=12.0
LDFLAGS  := -framework CoreAudio -framework AudioToolbox -framework CoreFoundation

SRCS := main.cpp
OBJS := $(SRCS:%.cpp=$(BUILD)/%.o)
BIN  := $(BUILD)/peq_engine

.PHONY: all clean

all: $(BIN)

$(BUILD)/%.o: %.cpp biquad.hpp config.hpp ringbuffer.hpp
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BIN): $(OBJS)
	$(CXX) $^ $(LDFLAGS) -o $@

clean:
	rm -rf $(BUILD)
