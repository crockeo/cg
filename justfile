build:
	zig build

debug: build
	lldb zig-out/bin/cg

install:
	zig build --release=fast
	cp zig-out/bin/cg ~/bin

test:
	zig build test --summary all

watch +args:
	watchexec -w . -e zig -- just {{args}}
