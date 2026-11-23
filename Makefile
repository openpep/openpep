.PHONY: bootstrap check check-environment check-mac-environment license-check mac-bootstrap mac-check protocol-check vaultctl-check cockpit-pdf-check

bootstrap:
	npm ci --prefix packages/protocol-schema
	npm run build --prefix packages/protocol-schema
	npm ci --prefix tools/vaultctl
	npm ci --prefix tools/cockpit-pdf --ignore-scripts

check: check-environment license-check protocol-check vaultctl-check cockpit-pdf-check

check-environment:
	./scripts/check-environment.sh phase0

check-mac-environment:
	./scripts/check-environment.sh mac

mac-bootstrap: check-mac-environment
	xcodebuild -resolvePackageDependencies \
		-project apps/macos/OpenPEP.xcodeproj \
		-scheme OpenPEP

mac-check: check-mac-environment
	xcodebuild test -quiet \
		-project apps/macos/OpenPEP.xcodeproj \
		-scheme OpenPEP \
		-destination 'platform=macOS' \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		-skipPackageUpdates \
		-parallel-testing-enabled NO \
		CODE_SIGNING_ALLOWED=NO
	TEST_RUNNER_OPENPEP_ASSISTANT_UI_TESTS=1 xcodebuild test -quiet \
		-project apps/macos/OpenPEP.xcodeproj \
		-scheme OpenPEP \
		-destination 'platform=macOS' \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		-skipPackageUpdates \
		-parallel-testing-enabled NO \
		-only-testing:OpenPEPTests/AssistantPanelTests \
		-only-testing:OpenPEPTests/AssistantResultsLayoutTests \
		-only-testing:OpenPEPTests/AssistantVoiceTests \
		CODE_SIGNING_ALLOWED=NO

license-check:
	reuse lint

protocol-check:
	npm run check --prefix packages/protocol-schema

vaultctl-check:
	npm run check --prefix tools/vaultctl

cockpit-pdf-check:
	node tools/cockpit-pdf/build.mjs --check
	npm test --prefix tools/cockpit-pdf
