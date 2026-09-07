.PHONY: generate build run clean appimage build-flatpak build-appimage lint format

generate:
	flugo generate

build-linux:
	flugo build linux

build-macos:
	flugo build macos

build-windows:
	flugo build windows

build-android:
	flugo build android

build-ios:
	flugo build ios

build-all:
	flugo build all

run:
	flugo run

package-linux:
	flugo package linux

flathub:
	flugo flathub

appimage:
	flugo appimage

build-flatpak:
	flugo build flatpak

build-appimage:
	flugo build appimage

clean:
	flugo clean

# Run both Go and Dart linters. Errors out on any finding.
# Requires golangci-lint (https://golangci-lint.run) and the Flutter SDK.
lint:
	flugo lint

# Auto-fix what can be auto-fixed: gofmt, golangci-lint --fix on Go;
# dart fix --apply, dart format on Dart.
format:
	flugo lint --fix
