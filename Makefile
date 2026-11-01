IMAGE = mobaprint

# three.js (MIT) wird lokal ausgeliefert statt von einem CDN geladen.
THREE_VERSION = 0.184.0
THREE_CDN     = https://cdn.jsdelivr.net/npm/three@$(THREE_VERSION)
THREE_DIR     = static/three
THREE_FILES   = build/three.module.js build/three.core.js \
                examples/jsm/controls/OrbitControls.js \
                examples/jsm/loaders/3MFLoader.js \
                examples/jsm/libs/fflate.module.js LICENSE

.PHONY: build run static clean-static

build: static
	docker build -t $(IMAGE) .

run:
	docker run --rm -p 8080:8080 $(IMAGE)

# Lädt nur fehlende Dateien; nach einer Versionsänderung "make clean-static static".
static: $(addprefix $(THREE_DIR)/,$(THREE_FILES))

$(THREE_DIR)/%:
	mkdir -p $(dir $@)
	curl -fsSL $(THREE_CDN)/$* -o $@

clean-static:
	rm -rf $(THREE_DIR)
