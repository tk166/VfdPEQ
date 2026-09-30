# VfdPEQ HAL driver — pure clang build, no Xcode/cmake required
# Driver code is a fork of BlackHole (GPL-3.0), see LICENSE.

CC      := clang
SDK     := $(shell xcrun --show-sdk-path)
ARCH    := arm64
DRIVER  := VfdPEQ
VERSION := 0.1.0

BUILD   := build
SRC     := src/$(DRIVER).c

# Driver identity (overridable via #ifndef in source)
# Release 等价构建（对齐上游官方发布）：无 DEBUG —— 驱动的 DebugMsg/FailWithAction
# 全部编译为 no-op。⚠️ IO 实时线程里的 syslog 在 overload 时会雪崩（阻塞→更多 overload），
# 并可拖死 coreaudiod（实测 140% CPU 对象 churn）——诊断构建一律用 `make debug`。
DEFINES := \
	-DkDriver_Name='"$(DRIVER)"' \
	-DkPlugIn_BundleID='"dev.vfdpeq.hal"' \
	-DkManufacturer_Name='"VfdPEQ Project"' \
	-DkNumber_Of_Channels=2 \
	-DkDevice_IsHidden=false \
	-DkDevice2_IsHidden=true

# 诊断构建开关：make debug 传入 DEBUG_BUILD=1（激活 DebugMsg/FailWithAction 的 syslog）
ifdef DEBUG_BUILD
DEFINES += -DDEBUG=1
endif

CFLAGS  := -arch $(ARCH) -bundle -O2 -DNDEBUG \
	-mmacosx-version-min=12.0 \
	-isysroot $(SDK) \
	$(DEFINES) \
	-Wall -Wno-unused-variable -Wno-deprecated-declarations

LDFLAGS := -framework CoreFoundation -framework CoreAudio -framework AudioToolbox -framework Accelerate

.PHONY: all clean sign verify debug

all: $(BUILD)/$(DRIVER).driver

# Debug 构建（仅诊断用）：DEBUG=1 激活 DebugMsg/FailWithAction 的 syslog——
# 会给 IO 实时线程引入阻塞开销，禁止长期安装。输出到 build/debug/，不覆盖 Release 产物。
debug:
	rm -rf build/debug
	$(MAKE) -e BUILD=build/debug DEBUG_BUILD=1 all

$(BUILD)/$(DRIVER).driver: $(SRC) resources/Info.plist
	@mkdir -p $(BUILD)/$(DRIVER).driver/Contents/MacOS
	$(CC) $(CFLAGS) -o $(BUILD)/$(DRIVER).driver/Contents/MacOS/$(DRIVER) $(SRC) $(LDFLAGS)
	cp resources/Info.plist $(BUILD)/$(DRIVER).driver/Contents/Info.plist
	$(MAKE) sign

sign:
	codesign -s - --force $(BUILD)/$(DRIVER).driver

verify:
	codesign -dv $(BUILD)/$(DRIVER).driver
	plutil -lint $(BUILD)/$(DRIVER).driver/Contents/Info.plist
	nm -gU $(BUILD)/$(DRIVER).driver/Contents/MacOS/$(DRIVER) | grep Create

clean:
	rm -rf $(BUILD)
