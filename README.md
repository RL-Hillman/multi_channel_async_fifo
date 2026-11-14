# Multi-Channel Asynchronous FIFO with Round-Robin Arbitration

## Project Overview

A **parameterized SystemVerilog RTL design** that aggregates data from multiple independent input clock domains into a single output stream. The architecture supports a configurable number of input channels, data width, and FIFO depth, with each channel operating on its own write clock and sharing a common read clock.

Each channel uses an **asynchronous FIFO with Gray-coded pointers and two-stage synchronizers** for safe clock-domain crossing (CDC), along with FULL/EMPTY detection and Ready/Valid flow control. A **round-robin arbiter** provides fair channel selection, while an **elastic output register slice** introduces a registered pipeline stage to improve timing and handle downstream backpressure. The selected data and its one-hot channel identifier remain stable until the transfer is accepted. The design also incorporates **per-clock-domain reset synchronization**, with asynchronous active-low assertion and synchronous deassertion.

The project demonstrates **RTL architecture, CDC design, reset synchronization, self-checking functional verification, standard-cell synthesis, and pre-layout static timing analysis (STA)**.



## System Architecture

The system consists of multiple independent write-clock domains connected to a shared read-clock domain. Each input channel operates independently, while the read-domain logic handles arbitration, data selection, and output flow control.

The diagram below illustrates the default **four-channel configuration** (`NUM_CHANNELS = 4`). The architecture supports a configurable number of channels.

![System Architecture](docs/system_architecture.jpeg)

*Figure 1: System architecture showing independent input channels, asynchronous FIFOs, round-robin arbitration, data multiplexing, output register slicing, and reset synchronization.*

### Data Flow and Arbitration

Each input channel receives data through its own Ready/Valid interface and stores it in a dedicated asynchronous FIFO. The FIFOs safely transfer data into the shared `rd_clk` domain, where the round-robin arbiter selects among channels containing valid data.

The arbiter generates a one-hot `grant` vector, which controls the data MUX. The selected data and its channel identifier are then packed together and forwarded to the **elastic output register slice**.

The output interface provides:
- `out_data_o` — selected output data.
- `out_grant_o` — one-hot source identifier (`NUM_CHANNELS` bits).
- `out_valid_o` — indicates valid output data.
- `out_ready_i` — indicates downstream readiness.

### Flow Control and Backpressure

Data transfers are controlled through Ready/Valid handshakes. A FIFO advances only when it is selected and the output register slice is ready to accept its data:

```systemverilog
assign fifo_rd_ready[ch] = grant[ch] && regslice_in_ready;
```

When downstream backpressure occurs, the register slice holds its output data and channel identifier stable until the transfer is accepted. If the register slice is occupied and cannot accept another word, upstream FIFO reads are stalled.

### Reset Synchronization

A common active-low reset (`global_rst_n`) is distributed through **independent reset synchronizers**: one for each write-clock domain and one for the shared read-clock domain.

Each synchronizer supports asynchronous reset assertion and clock-synchronized deassertion, ensuring controlled reset release within its corresponding clock domain.

## RTL Microarchitecture & CDC

| RTL file | Purpose |
|---|---|
| [`async_fifo.sv`](rtl/async_fifo.sv) | Dual-clock FIFO with Gray-coded pointers, two-stage CDC synchronizers, and FULL/EMPTY detection |
| [`reset_sync.sv`](rtl/reset_sync.sv) | Per-domain reset synchronization |
| [`rr_arbiter.sv`](rtl/rr_arbiter.sv) | Round-robin grant generation and backpressure-aware priority tracking |
| [`stream_regslice.sv`](rtl/stream_regslice.sv) | Registered, one-entry elastic Ready/Valid output stage |
| [`multi_channel_top.sv`](rtl/multi_channel_top.sv) | Parameterized integration of FIFOs, arbitration, data selection, and reset handling |

### Asynchronous FIFO: Clock-Domain Crossing

![Asynchronous FIFO CDC architecture](docs/async_fifo_cdc_architecture.jpeg)

Each FIFO uses separate **binary pointers** for memory addressing and **Gray-coded pointers** for CDC. Only the Gray-coded pointer values are sent across the clock boundary, through two-flop synchronizers marked with `(* async_reg = "true" *)`.

- **Write → read:** the synchronized write Gray pointer (`wgray_rd_sync2`) is compared with the local next read Gray pointer to determine EMPTY.
- **Read → write:** the synchronized read Gray pointer (`rgray_wr_sync2`) is compared with the local next write Gray pointer, using `FULL_MASK`, to determine FULL.
- **Memory access:** write data is stored on an accepted write handshake; the current read address exposes the FIFO head in a first-word-fall-through (FWFT) style when `rd_valid_o` is asserted.

The pointer logic implements:

```systemverilog
wr_full_next  = (wgray_next == (rgray_wr_sync2 ^ FULL_MASK));
rd_empty_next = (rgray_next == wgray_rd_sync2);
```

Each pointer has an additional wrap bit for FULL/EMPTY distinction. Data moves through the FIFO storage; the **synchronized Gray pointers carry occupancy information**, not the data payload.

### Arbitration and Output Flow Control

The round-robin arbiter examines `fifo_rd_valid` and generates a one-hot grant. On a successful handshake it advances priority to the next channel; under backpressure, the selected request remains the priority starting point. The output register slice accepts the packed `{grant, mux_data}` payload and exposes `{out_grant_o, out_data_o}`, keeping the channel association aligned through stalls.

## Functional Verification

Three self-checking SystemVerilog testbenches are executed with **Verilator**. The FIFO testbench runs under three different write/read clock configurations, yielding **five successful test runs** in the recorded default test suite.

| Testbench | Main checks | Result |
|---|---|---|
| [`async_fifo_tb.sv`](tb/async_fifo_tb.sv) | EMPTY/FULL, blocked transfers, data ordering, pointer wraparound, concurrent traffic, reset; three clock ratios | **PASS × 3** |
| [`rr_arbiter_tb.sv`](tb/rr_arbiter_tb.sv) | Round-robin order, one-hot grants, independent reference model, stalls, fairness, randomized requests, reset | **PASS** |
| [`multi_channel_top_tb.sv`](tb/multi_channel_top_tb.sv) | Four-channel integration, per-channel scoreboards, backpressure, data/channel alignment, isolation, throughput, reset | **PASS** |

### Recorded Simulation Results

| Metric | Result |
|---|---:|
| FIFO clock configurations passed | 3 / 3 |
| Arbiter transfers | 725 |
| Arbiter stalled cycles | 72 |
| Arbiter fairness checks | 1,064 |
| Integration accepted writes | 2,109 |
| Integration output transfers | 2,076 |
| Integration output stalled cycles | 497 |
| Sustained output throughput test | 40 consecutive read-clock cycles at one word per cycle |

The integration test intentionally exercises a **global reset while data is buffered**, so its aggregate accepted-write and output-transfer counts need not match across reset. The testbenches validate the specified scenarios; they do not claim exhaustive formal verification or measured 100% coverage. The recorded tests use the default top-level channel configuration.

## ASIC Synthesis & Static Timing Analysis

The RTL was synthesized with **Yosys**, mapped to the **Nangate45** standard-cell library, and analyzed using **OpenROAD** pre-layout STA. The reported results correspond to the default configuration: **4 channels, 32-bit data, FIFO depth 16**.

### Nangate45 Standard-Cell Utilization

![Standard-cell utilization](docs/standard_cell_utilization.png)

| Metric | Result |
|---|---:|
| Mapped standard cells | **7,543** |
| Flip-flops | 2,262 |
| Multiplexers | 2,546 |
| Other logic cells | 2,735 |
| Mapped cell area | **18,077.094 µm²** |

### OpenROAD Pre-Layout STA

![OpenROAD STA results](docs/sta_results.png)

| Clock scenario | Read clock | Write clocks (CH0 / CH1 / CH2 / CH3) | Setup slack | Hold slack | Recovery | Removal | Status |
|---|---:|---|---:|---:|---:|---:|---|
| Uniform | 100 MHz | 100 / 100 / 100 / 100 MHz | +3.64 ns | +0.08 ns | +4.50 ns | +4.83 ns | PASS |
| Slow Writes | 100 MHz | 80 / 70 / 60 / 50 MHz | +3.64 ns | +0.08 ns | +4.50 ns | +4.83 ns | PASS |
| Mixed | 80 MHz | 100 / 90 / 70 / 60 MHz | +4.21 ns | +0.08 ns | +4.86 ns | +4.89 ns | PASS |

The SDC files define independent asynchronous clock groups, so **inter-domain setup/hold timing checks are excluded**. These are **pre-layout estimates**, not placed-and-routed timing closure, physical signoff, or formal CDC signoff.

## How to Run

### Functional Simulation

**Requirements:** Linux (or WSL), Verilator with `--binary`/`--timing` support, a C++ compiler (such as `g++`), and `make`.

From the repository root:

```bash
bash scripts/run_all_tbs.sh
```

The script compiles all three testbenches and runs the asynchronous FIFO test in clock modes 0, 1, and 2. Generated build artifacts are placed in `obj_dir/` and ignored by Git.

### ASIC Synthesis and Timing

**Requirements:** compatible Yosys with `read_slang` support, OpenROAD, Python 3, and the Nangate45 Liberty/LEF technology files.

```bash
bash scripts/run_asic_checks.sh
```

The ASIC script currently expects an **OpenROAD-flow-scripts** installation beneath `$HOME/eda/OpenROAD-flow-scripts/`. If your environment differs, update the `YOSYS`, `OPENROAD`, and `LIB` paths near the beginning of [`run_asic_checks.sh`](scripts/run_asic_checks.sh). The script generates the netlist and reports locally; these outputs are intentionally excluded from Git.

The functional and ASIC scripts were both successfully run from a clean export containing only the tracked project files, using the configured local toolchain.

## Repository Structure

```text
.
├── rtl/                 # Synthesizable SystemVerilog modules
├── tb/                  # Self-checking SystemVerilog testbenches
├── scripts/             # Simulation and ASIC-analysis scripts
├── constraints/         # Three STA clock scenarios (SDC)
├── docs/                # Architecture diagrams and result images
├── .gitignore
└── README.md
```
