APP_BINARY = dist/ScreenRecorder.app/Contents/MacOS/ScreenRecorder

.PHONY: build release clean

build:
	swift build
	cp .build/debug/ScreenRecorder $(APP_BINARY)

release:
	swift build -c release
	cp .build/release/ScreenRecorder $(APP_BINARY)

clean:
	swift package clean
