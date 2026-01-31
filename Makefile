SOURCES = \
	src/header.sh \
	src/banner.sh \
	src/config.sh \
	src/git-clone.sh \
	src/main.sh

OUTPUT = dist/claude-cage-git

.PHONY: all clean

all: $(OUTPUT)

$(OUTPUT): $(SOURCES) | dist
	cat $(SOURCES) > $@
	chmod +x $@

dist:
	mkdir -p dist

clean:
	rm -f $(OUTPUT)
