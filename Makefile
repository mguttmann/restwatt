# Restwatt build helpers. Everything goes through SwiftPM; see README.md.

.PHONY: build test app run install clean

build:
	swift build

test:
	swift test

app:
	scripts/make-app.sh

run: app
	open dist/Restwatt.app

# Copies the bundle into /Applications for the person running make; not used by CI.
install: app
	ditto dist/Restwatt.app /Applications/Restwatt.app

clean:
	rm -rf .build dist
