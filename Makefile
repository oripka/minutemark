.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	zsh scripts/build-app.sh

run: app
	open build/MinuteMark.app

clean:
	swift package clean
	rm -rf build
