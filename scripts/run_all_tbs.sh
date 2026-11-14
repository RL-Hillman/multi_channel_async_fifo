#!/usr/bin/env bash
set -euo pipefail

# Run from the project root: ~/projects/async_fifo_arbiter
cd "$(dirname "$0")/.."
mkdir -p obj_dir/async_fifo_tb obj_dir/rr_arbiter_tb obj_dir/multi_channel_top_tb

printf '\n=== 1) async_fifo_tb: compile ===\n'
verilator --binary --timing --assert --trace \
    -Wno-fatal -Wno-TIMESCALEMOD \
    --top-module async_fifo_tb \
    --Mdir obj_dir/async_fifo_tb \
    rtl/async_fifo.sv tb/async_fifo_tb.sv

for mode in 0 1 2; do
    printf '\n=== async_fifo_tb CLOCK_MODE=%s ===\n' "$mode"
    ./obj_dir/async_fifo_tb/Vasync_fifo_tb "+CLOCK_MODE=$mode"
done

printf '\n=== 2) rr_arbiter_tb: compile ===\n'
verilator --binary --timing --assert --trace \
    -Wno-fatal -Wno-TIMESCALEMOD \
    --top-module rr_arbiter_tb \
    --Mdir obj_dir/rr_arbiter_tb \
    rtl/rr_arbiter.sv tb/rr_arbiter_tb.sv

./obj_dir/rr_arbiter_tb/Vrr_arbiter_tb

printf '\n=== 3) multi_channel_top_tb: compile ===\n'
verilator --binary --timing --assert --trace \
    -Wno-fatal -Wno-TIMESCALEMOD \
    --top-module multi_channel_top_tb \
    --Mdir obj_dir/multi_channel_top_tb \
    rtl/*.sv tb/multi_channel_top_tb.sv

./obj_dir/multi_channel_top_tb/Vmulti_channel_top_tb

printf '\n=== ALL TB EXECUTABLES FINISHED SUCCESSFULLY ===\n'
