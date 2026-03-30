PROJECT := Stackriot.xcodeproj
SCHEME := Stackriot
CONFIGURATION ?= Release
APP_NAME := Stackriot
BUILD_DIR := $(CURDIR)/build
LOCAL_CACHE_DIR := $(BUILD_DIR)/Cache
LOCAL_HOME_DIR := $(BUILD_DIR)/home
LOCAL_TMP_DIR := $(BUILD_DIR)/tmp
DERIVED_DATA_DIR := $(BUILD_DIR)/DerivedData
SOURCE_PACKAGES_DIR := $(BUILD_DIR)/SourcePackages
PRODUCTS_DIR := $(DERIVED_DATA_DIR)/Build/Products/$(CONFIGURATION)
APP_BUNDLE := $(PRODUCTS_DIR)/$(APP_NAME).app
DMG_DIR := $(BUILD_DIR)/dmg
DMG_BACKGROUND := $(BUILD_DIR)/$(APP_NAME)-dmg-background.png
DMG_PATH := $(DMG_DIR)/$(APP_NAME).dmg

.PHONY: help production-build dmg dmg-background clean

help:
	@printf "%s\n" \
		"Available targets:" \
		"  make production-build  Build $(APP_NAME).app in $(PRODUCTS_DIR)" \
		"  make dmg               Create a distributable DMG in $(DMG_DIR)" \
		"  make dmg-background    Render the DMG background artwork only" \
		"  make clean             Remove all generated artifacts"

production-build:
	@mkdir -p "$(BUILD_DIR)" "$(SOURCE_PACKAGES_DIR)" "$(LOCAL_CACHE_DIR)" "$(LOCAL_TMP_DIR)" "$(LOCAL_HOME_DIR)/Library/Caches"
	CLANG_MODULE_CACHE_PATH="$(LOCAL_CACHE_DIR)/clang" \
	SWIFT_MODULECACHE_PATH="$(LOCAL_CACHE_DIR)/swift" \
	XDG_CACHE_HOME="$(LOCAL_CACHE_DIR)/xdg" \
	HOME="$(LOCAL_HOME_DIR)" \
	TMPDIR="$(LOCAL_TMP_DIR)" \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA_DIR)" \
		-clonedSourcePackagesDirPath "$(SOURCE_PACKAGES_DIR)" \
		-skipPackagePluginValidation \
		build
	@printf "Built app bundle: %s\n" "$(APP_BUNDLE)"

dmg-background:
	@mkdir -p "$(BUILD_DIR)" "$(LOCAL_CACHE_DIR)" "$(LOCAL_TMP_DIR)" "$(LOCAL_HOME_DIR)/Library/Caches"
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

clean:
	rm -rf "$(BUILD_DIR)"
