PROJECT := Stackriot.xcodeproj
SCHEME := Stackriot
CONFIGURATION ?= Release
APP_NAME := Stackriot
PRODUCTION_DESTINATION := generic/platform=macOS
BUILD_DIR := $(CURDIR)/build
PRODUCTION_DIR := $(BUILD_DIR)/production
LOCAL_CACHE_DIR := $(BUILD_DIR)/Cache
PACKAGE_CACHE_DIR := $(BUILD_DIR)/PackageCache
LOCAL_HOME_DIR := $(BUILD_DIR)/home
LOCAL_TMP_DIR := $(BUILD_DIR)/tmp
DERIVED_DATA_DIR := $(BUILD_DIR)/DerivedData
SOURCE_PACKAGES_DIR := $(BUILD_DIR)/SourcePackages
PRODUCTS_DIR := $(DERIVED_DATA_DIR)/Build/Products/$(CONFIGURATION)
DEBUG_PRODUCTS_DIR := $(DERIVED_DATA_DIR)/Build/Products/Debug
DEBUG_APP_BUNDLE := $(DEBUG_PRODUCTS_DIR)/$(APP_NAME).app
APP_BUNDLE := $(PRODUCTS_DIR)/$(APP_NAME).app
PRODUCTION_APP_BUNDLE := $(PRODUCTION_DIR)/$(APP_NAME).app
PRODUCTION_ZIP_PATH := $(PRODUCTION_DIR)/$(APP_NAME).zip
DMG_DIR := $(BUILD_DIR)/dmg
DMG_BACKGROUND := $(BUILD_DIR)/$(APP_NAME)-dmg-background.png
DMG_PATH := $(DMG_DIR)/$(APP_NAME).dmg

.PHONY: help production production-build debug-run test dmg dmg-background clean clean-build clean-spm

help:
	@printf "%s\n" \
		"Available targets:" \
		"  make production        Export a portable production app bundle and ZIP to $(PRODUCTION_DIR)" \
		"  make production-build  Build $(APP_NAME).app in $(PRODUCTS_DIR) (CONFIGURATION=$(CONFIGURATION))" \
		"  make debug-run         Build Debug $(APP_NAME).app and open it (for manual debugging)" \
		"  make test              Run swift test with TMPDIR/HOME under $(BUILD_DIR) (isolated temp)" \
		"  make dmg               Create a distributable DMG in $(DMG_DIR)" \
		"  make dmg-background    Render the DMG background artwork only" \
		"  make clean             Remove $(BUILD_DIR) and SwiftPM $(CURDIR)/.build only (never user Library paths)" \
		"  make clean-build       Remove $(BUILD_DIR) only" \
		"  make clean-spm         Remove $(CURDIR)/.build only (Swift Package Manager cache)"

production-build:
	@mkdir -p "$(BUILD_DIR)" "$(SOURCE_PACKAGES_DIR)" "$(LOCAL_CACHE_DIR)" "$(PACKAGE_CACHE_DIR)" "$(LOCAL_TMP_DIR)" "$(LOCAL_HOME_DIR)/Library/Caches"
	CLANG_MODULE_CACHE_PATH="$(LOCAL_CACHE_DIR)/clang" \
	SWIFT_MODULECACHE_PATH="$(LOCAL_CACHE_DIR)/swift" \
	XDG_CACHE_HOME="$(LOCAL_CACHE_DIR)/xdg" \
	HOME="$(LOCAL_HOME_DIR)" \
	TMPDIR="$(LOCAL_TMP_DIR)" \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "$(PRODUCTION_DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA_DIR)" \
		-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIR)" \
		-packageCachePath "$(PACKAGE_CACHE_DIR)" \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		CLANG_MODULE_CACHE_PATH="$(LOCAL_CACHE_DIR)/clang" \
		SWIFT_MODULECACHE_PATH="$(LOCAL_CACHE_DIR)/swift" \
		XDG_CACHE_HOME="$(LOCAL_CACHE_DIR)/xdg" \
		HOME="$(LOCAL_HOME_DIR)" \
		TMPDIR="$(LOCAL_TMP_DIR)" \
		-skipPackagePluginValidation \
		ONLY_ACTIVE_ARCH=NO \
		ARCHS="arm64 x86_64" \
		build
	@printf "Built app bundle: %s\n" "$(APP_BUNDLE)"

production: production-build
	@mkdir -p "$(PRODUCTION_DIR)"
	rm -rf "$(PRODUCTION_APP_BUNDLE)" "$(PRODUCTION_ZIP_PATH)"
	ditto "$(APP_BUNDLE)" "$(PRODUCTION_APP_BUNDLE)"
	xattr -cr "$(PRODUCTION_APP_BUNDLE)" || true
	ditto -c -k --keepParent "$(PRODUCTION_APP_BUNDLE)" "$(PRODUCTION_ZIP_PATH)"
	@printf "Exported production app: %s\n" "$(PRODUCTION_APP_BUNDLE)"
	@printf "Created portable ZIP: %s\n" "$(PRODUCTION_ZIP_PATH)"

# Build Debug and launch the app (Xcode scheme). All caches live under $(BUILD_DIR).
debug-run:
	@mkdir -p "$(BUILD_DIR)" "$(SOURCE_PACKAGES_DIR)" "$(LOCAL_CACHE_DIR)" "$(PACKAGE_CACHE_DIR)" "$(LOCAL_TMP_DIR)" "$(LOCAL_HOME_DIR)/Library/Caches"
	CLANG_MODULE_CACHE_PATH="$(LOCAL_CACHE_DIR)/clang" \
	SWIFT_MODULECACHE_PATH="$(LOCAL_CACHE_DIR)/swift" \
	XDG_CACHE_HOME="$(LOCAL_CACHE_DIR)/xdg" \
	HOME="$(LOCAL_HOME_DIR)" \
	TMPDIR="$(LOCAL_TMP_DIR)" \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA_DIR)" \
		-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIR)" \
		-packageCachePath "$(PACKAGE_CACHE_DIR)" \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		CLANG_MODULE_CACHE_PATH="$(LOCAL_CACHE_DIR)/clang" \
		SWIFT_MODULECACHE_PATH="$(LOCAL_CACHE_DIR)/swift" \
		XDG_CACHE_HOME="$(LOCAL_CACHE_DIR)/xdg" \
		HOME="$(LOCAL_HOME_DIR)" \
		TMPDIR="$(LOCAL_TMP_DIR)" \
		-skipPackagePluginValidation \
		build
	@printf "Launching Debug app: %s\n" "$(DEBUG_APP_BUNDLE)"
	@open "$(DEBUG_APP_BUNDLE)"

# Swift tests use FileManager.temporaryDirectory → respects TMPDIR. Keeping TMPDIR under $(BUILD_DIR)
# lets `make clean` remove test-created trees; we do not delete arbitrary system temp paths.
test:
	@mkdir -p "$(BUILD_DIR)" "$(LOCAL_TMP_DIR)" "$(LOCAL_HOME_DIR)/Library/Caches"
	TMPDIR="$(LOCAL_TMP_DIR)" \
	HOME="$(LOCAL_HOME_DIR)" \
	swift test --parallel

dmg-background:
	@mkdir -p "$(BUILD_DIR)" "$(LOCAL_CACHE_DIR)" "$(PACKAGE_CACHE_DIR)" "$(LOCAL_TMP_DIR)" "$(LOCAL_HOME_DIR)/Library/Caches"
	CLANG_MODULE_CACHE_PATH="$(LOCAL_CACHE_DIR)/clang" \
	SWIFT_MODULECACHE_PATH="$(LOCAL_CACHE_DIR)/swift" \
	XDG_CACHE_HOME="$(LOCAL_CACHE_DIR)/xdg" \
	HOME="$(LOCAL_HOME_DIR)" \
	TMPDIR="$(LOCAL_TMP_DIR)" \
	swift scripts/render_dmg_background.swift "$(DMG_BACKGROUND)"
	@printf "Rendered background: %s\n" "$(DMG_BACKGROUND)"

dmg: production-build dmg-background
	bash scripts/create_dmg.sh \
		"$(APP_BUNDLE)" \
		"$(DMG_BACKGROUND)" \
		"README.md" \
		"$(DMG_PATH)"
	@printf "Created DMG: %s\n" "$(DMG_PATH)"

# Only removes repository-local build products (see help). Never touches ~/Library or global /tmp.
clean: clean-build clean-spm

clean-build:
	rm -rf "$(BUILD_DIR)"

clean-spm:
	rm -rf "$(CURDIR)/.build"
