SOURCES = \
	src/header.sh \
	src/helpers.sh \
	src/banner.sh \
	src/config-builder.sh \
	src/config.sh \
	src/git-clone.sh \
	src/git-hooks.sh \
	src/git-patches.sh \
	src/git-sync.sh \
	src/network.sh \
	src/mounts.sh \
	src/bwrap.sh \
	src/docker.sh \
	src/main.sh

OUTPUT = dist/claude-cage

.PHONY: all clean

all: $(OUTPUT)

$(OUTPUT): $(SOURCES) | dist
	cat $(SOURCES) > $@
	chmod +x $@

dist:
	mkdir -p dist

clean:
	rm -f $(OUTPUT)
