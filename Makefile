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
	src/bwrap.sh \
	src/docker.sh \
	src/main.sh

COMPLETIONS = \
	completions/claude-cage.bash \
	completions/claude-cage.zsh

OUTPUT = dist/claude-cage

.PHONY: all clean

all: $(OUTPUT)

$(OUTPUT): $(SOURCES) $(COMPLETIONS) | dist
	@# Concatenate sources and substitute completion placeholders
	@cat $(SOURCES) > $@.tmp
	@awk '/@@BASH_COMPLETION@@/{while((getline l<"completions/claude-cage.bash")>0)print l;next}1' $@.tmp > $@.tmp2
	@awk '/@@ZSH_COMPLETION@@/{while((getline l<"completions/claude-cage.zsh")>0)print l;next}1' $@.tmp2 > $@
	@rm -f $@.tmp $@.tmp2
	@chmod +x $@

dist:
	mkdir -p dist

clean:
	rm -f $(OUTPUT)
