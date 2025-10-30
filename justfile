build:
	zig build

install:
	zig build --release=fast
	cp zig-out/bin/cg ~/bin

watch +args:
	watchexec -w . -e zig -- @just {{args}}
