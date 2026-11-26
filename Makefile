NAME := BatSign
SCHEME := Feather
PLATFORMS := iphoneos maccatalyst

TMP := $(TMPDIR)/$(NAME)

.PHONY: all clean deps $(PLATFORMS)

all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

# The local HTTPS installer's TLS identity: a private, name-constrained CA and a
# short-lived leaf (scripts/make-local-pki.sh). The public backloop.dev pack that
# used to be downloaded here no longer exists, which is what left installs stuck.
# Locally the CA is kept in ~/.batsign-pki; CI passes BATSIGN_CA_KEY/BATSIGN_CA_CERT
# or PKI_FLAGS=--ephemeral.
PKI_FLAGS ?=

deps:
	rm -rf deps || true
	sh scripts/make-local-pki.sh --out deps $(PKI_FLAGS)


$(PLATFORMS): deps
	rm -rf _build

	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	xcodebuild \
		-project Feather.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "$$DEST" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/BatSign.app
	chmod -R 0755 _build/Payload/BatSign.app
	codesign --force --sign - --timestamp=none _build/Payload/BatSign.app
	cp deps/* _build/Payload/BatSign.app/

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/BatSign.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload/BatSign.app "packages/BatSign_Catalyst.zip"; \
	fi
