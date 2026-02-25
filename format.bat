@echo off
echo Formatting Kyzu workspace using nightly rustfmt...
cargo +nightly fmt --all
echo Done.
pause