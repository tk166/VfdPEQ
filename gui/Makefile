# SystemPEQ GUI — ImGui (Metal) + VfdSpecturm renderer, no Xcode needed
CXX   := clang++
SDK   := $(shell xcrun --show-sdk-path)
BUILD := build

IMGUI  := third_party/imgui

CXXFLAGS := -std=c++20 -arch arm64 -O2 -Wall -Wno-unused-variable \
	-isysroot $(SDK) -mmacosx-version-min=12.0 \
	-I$(IMGUI) -I. -I..

LDFLAGS := -framework Metal -framework MetalKit -framework QuartzCore \
	-framework AppKit -framework GameController -framework CoreAudio -framework AudioToolbox \
	-framework CoreFoundation -framework UniformTypeIdentifiers

OBJS := $(BUILD)/main.o \
	$(BUILD)/imgui.o $(BUILD)/imgui_draw.o $(BUILD)/imgui_tables.o $(BUILD)/imgui_widgets.o \
	$(BUILD)/imgui_impl_metal.o $(BUILD)/imgui_impl_osx.o

BIN := $(BUILD)/peq_gui

.PHONY: all clean

all: $(BIN)

$(BUILD)/%.o: %.mm peq_state.hpp $(wildcard ../*.hpp) $(wildcard vfd/*.hpp)
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/imgui.o: $(IMGUI)/imgui.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/imgui_draw.o: $(IMGUI)/imgui_draw.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/imgui_tables.o: $(IMGUI)/imgui_tables.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/imgui_widgets.o: $(IMGUI)/imgui_widgets.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/imgui_impl_metal.o: $(IMGUI)/imgui_impl_metal.mm
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/imgui_impl_osx.o: $(IMGUI)/imgui_impl_osx.mm
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BIN): $(OBJS)
	$(CXX) $^ $(LDFLAGS) -o $@

clean:
	rm -rf $(BUILD)
