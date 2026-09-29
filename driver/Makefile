# SystemPEQ HAL driver — pure clang build, no Xcode/cmake required
# Driver code is a fork of BlackHole (GPL-3.0), see LICENSE.

CC      := clang
SDK     := $(shell xcrun --show-sdk-path)
ARCH    := arm64
DRIVER  := SystemPEQ
VERSION := 0.1.0

BUILD   := build
SRC     := src/$(DRIVER).c

# Driver identity (overridable via #ifndef in source)
DEFINES := \
	-DkDriver_Name='"$(DRIVER)"' \
	-DkPlugIn_BundleID='"dev.systempeq.hal"' \
	-DkManufacturer_Name='"SystemPEQ Project"' \
	-DkNumber_Of_Channels=2 \
	-DkDevice_IsHidden=false \
	-DkDevice2_IsHidden=true

CFLAGS  := -arch $(ARCH) -bundle -O2 -DNDEBUG \
	-mmacosx-version-min=12.0 \
	-isysroot $(SDK) \
	$(DEFINES) \
	-Wall -Wno-unused-variable -Wno-deprecated-declarations

LDFLAGS := -framework CoreFoundation -framework CoreAudio -framework AudioToolbox -framework Accelerate

.PHONY: all clean sign verify

all: $(BUILD)/$(DRIVER).driver

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
