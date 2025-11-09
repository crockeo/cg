build:
	zig build

debug: build
	lldb zig-out/bin/cg

install:
	zig build --release=fast
	cp zig-out/bin/cg ~/bin

watch +args:
	watchexec -w . -e zig -- just {{args}}
