# Orbit — common development tasks.
DERIVED := .build/xcode
APP := $(DERIVED)/Build/Products/Debug/Orbit.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/Orbit.app

.PHONY: all project build run test smoke cli ffmpeg release dmg clean

all: build

project:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
	xcodegen generate --quiet

build: project
	xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -derivedDataPath $(DERIVED) -quiet build

run: build
	@pkill -x Orbit 2>/dev/null || true
	open $(APP)

test:
	swift test --package-path Packages/OrbitKit

smoke:
	scripts/smoke-test.sh

cli:
	swift build --package-path Packages/OrbitKit -c release
	@echo "CLI: Packages/OrbitKit/.build/release/orbit"

ffmpeg:
	scripts/fetch-ffmpeg.sh

release: project
	xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -derivedDataPath $(DERIVED) -quiet build
	@echo "Built $(RELEASE_APP)"

dmg: release
	scripts/make-dmg.sh "$(RELEASE_APP)"

clean:
	rm -rf $(DERIVED) Orbit.xcodeproj Packages/OrbitKit/.build
