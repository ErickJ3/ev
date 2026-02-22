default:
    @just --list

build:
    zig build

run *ARGS:
    zig build run -- {{ARGS}}

test:
    zig build test

scan *ARGS:
    zig build run -- scan {{ARGS}}

clean *ARGS:
    zig build run -- clean {{ARGS}}

status:
    zig build run -- status

release:
    zig build release

release-linux:
    zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe

release-arm:
    zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe

release-freebsd:
    zig build -Dtarget=x86_64-freebsd -Doptimize=ReleaseSafe
