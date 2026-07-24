PROJECT := Noted.xcodeproj
SCHEME := NotedApp
DERIVED_DATA_PATH ?= $(CURDIR)/.build/DerivedData
SOURCE_PACKAGES_PATH ?= $(CURDIR)/.build/SourcePackages

.PHONY: bootstrap project build-macos build-ios test-macos ci-apple backend-check

bootstrap:
	./scripts/bootstrap.sh

project:
	./scripts/generate-project.sh

build-macos: project
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "platform=macOS" \
		-derivedDataPath "$(DERIVED_DATA_PATH)" \
		-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_PATH)" \
		CODE_SIGNING_ALLOWED=NO \
		build

build-ios: project
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "generic/platform=iOS Simulator" \
		-derivedDataPath "$(DERIVED_DATA_PATH)" \
		-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_PATH)" \
		CODE_SIGNING_ALLOWED=NO \
		build

test-macos: project
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "platform=macOS" \
		-derivedDataPath "$(DERIVED_DATA_PATH)" \
		-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_PATH)" \
		CODE_SIGNING_ALLOWED=NO \
		test

ci-apple:
	./scripts/ci-build-apple.sh

backend-check:
	npm --prefix functions ci
	npm --prefix functions run lint
	npm --prefix functions run typecheck
	npm --prefix functions run test
	npm --prefix functions run build
