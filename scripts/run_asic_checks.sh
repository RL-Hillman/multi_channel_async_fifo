
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ASIC FRONT-END CHECKS: MULTI-CHANNEL ASYNC FIFO + ARBITER
# ============================================================
# Run from the project directory:
#   bash scripts/run_asic_checks.sh
#
# Flow:
#   1. Synthesize RTL using Yosys and the Nangate45 library.
#   2. Summarize mapped standard-cell area and utilization.
#   3. Run OpenROAD pre-layout STA for three clock scenarios.
#   4. Compare Setup, Hold, Recovery, and Removal slack.
#   5. Show the generated report locations.
#
# The OpenROAD Tcl scripts are generated automatically.
# No pre-existing run_sta.tcl is required.
# ============================================================

# Resolve paths relative to this script.
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Toolchain and Nangate45 standard-cell timing library.
# Update these paths if OpenROAD-flow-scripts is installed elsewhere.
YOSYS="$HOME/eda/OpenROAD-flow-scripts/tools/install/yosys/bin/yosys"
OPENROAD="$HOME/eda/OpenROAD-flow-scripts/tools/install/OpenROAD/bin/openroad"
LIB="$HOME/eda/OpenROAD-flow-scripts/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib"

# Input constraints, generated netlist, and output reports.
SDC="$PROJECT_ROOT/constraints/multi_channel_top.sdc"
NETLIST="$PROJECT_ROOT/netlist/multi_channel_top_nangate45.v"
SYNTH_LOG="$PROJECT_ROOT/reports/synth_nangate45.log"
SYNTH_CONSOLE="$PROJECT_ROOT/reports/synth_console.log"
STA_LOG="$PROJECT_ROOT/reports/sta_nangate45.log"
STA_TCL="$PROJECT_ROOT/reports/run_sta.generated.tcl"

# Check prerequisites before starting the flow.
for entry in "$YOSYS" "$OPENROAD" "$LIB" "$SDC"; do
    if [[ ! -e "$entry" ]]; then
        printf 'ERROR: required file not found: %s\n' "$entry" >&2
        exit 1
    fi
done

if [[ ! -f rtl/multi_channel_top.sv ]]; then
    printf 'ERROR: missing RTL top module: rtl/multi_channel_top.sv\n' >&2
    exit 1
fi

mkdir -p reports netlist


# ------------------------------------------------------------
# STEP 1: RTL SYNTHESIS
# - Read all SystemVerilog RTL files.
# - Check the synthesized design for structural problems.
# - Map the logic to Nangate45 standard cells.
# - Export the gate-level netlist and report cell area.
# ------------------------------------------------------------

printf '\n=== 1. YOSYS SYNTHESIS (Nangate45) ===\n'

if ! "$YOSYS" -l "$SYNTH_LOG" -p "
    read_slang --top multi_channel_top rtl/*.sv
    synth -top multi_channel_top -noabc
    check -assert
    dfflibmap -liberty $LIB
    abc -liberty $LIB
    clean
    stat -liberty $LIB
    write_verilog -noattr -noexpr $NETLIST
" > "$SYNTH_CONSOLE" 2>&1; then
    printf 'Synthesis failed. Last 40 lines of %s:\n' "$SYNTH_CONSOLE" >&2
    tail -n 40 "$SYNTH_CONSOLE" >&2
    exit 1
fi

# Extract mapped cell area from the final synthesis report.
area="$(sed -n 's/^[[:space:]]*Chip area for module.*: *//p' "$SYNTH_LOG" | tail -n 1)"

printf 'Synthesis: PASS\n'
printf 'Mapped cell area: %s um^2\n' "${area:-not reported}"
printf 'Gate-level netlist: %s\n' "$NETLIST"


# ------------------------------------------------------------
# GENERATE OPENROAD STA TCL
# - Load Nangate45 LEF and Liberty files.
# - Load the synthesized netlist and default SDC.
# - Report timing paths and each timing-check type separately.
# - Reuse this script with alternative SDC files below.
# ------------------------------------------------------------

cat > "$STA_TCL" <<'TCL'
set root $::env(ASIC_PROJECT_ROOT)
set lib $::env(ASIC_NANGATE_LIB)

# Technology data and standard-cell models.
set lef_dir [file join [file dirname [file dirname $lib]] lef]
read_lef "$lef_dir/NangateOpenCellLibrary.tech.lef"

set macro_lef "$lef_dir/NangateOpenCellLibrary.macro.mod.lef"
if {![file exists $macro_lef]} {
    set macro_lef "$lef_dir/NangateOpenCellLibrary.macro.lef"
}

read_lef $macro_lef
read_liberty $lib

# Gate-level design and clock constraints.
read_verilog "$root/netlist/multi_channel_top_nangate45.v"
link_design multi_channel_top
read_sdc "$root/constraints/multi_channel_top.sdc"

puts "\n========== CLOCKS / CONSTRAINTS =========="
puts "Number of clocks: [llength [all_clocks]]"

if {[llength [all_clocks]] == 0} {
    error "No clocks were loaded from the SDC"
}

check_setup

# Maximum-delay analysis: Setup and Recovery.
puts "\n========== SETUP / RECOVERY PATHS =========="
report_checks -path_delay max -group_path_count 10

# Minimum-delay analysis: Hold and Removal.
puts "\n========== HOLD / REMOVAL PATHS =========="
report_checks -path_delay min -group_path_count 10

# Separate timing-check reports.
# CHECK_TYPE markers are used by the Python summary parser.
puts "\n========== TIMING CHECKS BY TYPE =========="

puts "CHECK_TYPE_SETUP"
report_check_types -max_delay -format slack_only

puts "CHECK_TYPE_HOLD"
report_check_types -min_delay -format slack_only

puts "CHECK_TYPE_RECOVERY"
report_check_types -recovery -format slack_only

puts "CHECK_TYPE_REMOVAL"
report_check_types -removal -format slack_only

puts "CHECK_TYPE_END"

# Overall worst setup/hold slack.
puts "\n========== WORST SLACK =========="
report_worst_slack -max
report_worst_slack -min

puts "\n========== STA COMPLETE =========="
TCL


# ------------------------------------------------------------
# STEP 2: STANDARD-CELL UTILIZATION
# Parse the final Yosys statistics for the top module.
# Display the number of each mapped standard-cell type.
# Group cells into flip-flops, multiplexers, and other logic.
# ------------------------------------------------------------

printf '\n=== 2. STANDARD CELL UTILIZATION (Nangate45) ===\n'

python3 - <<'PY'
import re
from pathlib import Path

log = Path("reports/synth_nangate45.log").read_text()

# Extract the final top-module statistics.
section = log.rsplit("=== multi_channel_top ===", 1)[-1]

# Typical Yosys row:
# <cell_count> <cell_area> <cell_name>
pattern = r"^\s*(\d+)\s+[\d.eE+-]+\s+(\w+_X\d+)\s*$"

cells = {
    name: int(count)
    for count, name in re.findall(
        pattern, section, re.MULTILINE
    )
}

if not cells:
    raise SystemExit(
        "ERROR: No mapped cells found in synthesis report"
    )

# Print standard-cell utilization sorted by count.
print(f"{'Cell Type':<20} {'Count':>8}")
print("-" * 30)

for name, count in sorted(
    cells.items(), key=lambda x: -x[1]
):
    print(f"{name:<20} {count:>8}")

print("-" * 30)

# Categorize mapped standard cells.
total = sum(cells.values())

flops = sum(
    v for k, v in cells.items()
    if k.startswith("DFF")
)

muxes = sum(
    v for k, v in cells.items()
    if k.startswith("MUX")
)

other_logic = total - flops - muxes

print(f"{'Total Cells':<20} {total:>8}")
print(f"{'Flip-Flops':<20} {flops:>8}")
print(f"{'Multiplexers':<20} {muxes:>8}")
print(f"{'Other Logic':<20} {other_logic:>8}")
PY


# ------------------------------------------------------------
# STEP 3: PRE-LAYOUT STATIC TIMING ANALYSIS
#
# Run STA on the same synthesized netlist using three
# different clock-frequency configurations:
#
# Uniform:
#   rd=100, wr0=100, wr1=100, wr2=100, wr3=100 MHz
#
# Slow Writes:
#   rd=100, wr0=80, wr1=70, wr2=60, wr3=50 MHz
#
# Mixed:
#   rd=80, wr0=100, wr1=90, wr2=70, wr3=60 MHz
#
# Independent asynchronous clock groups are defined
# in the SDC files.
#
# This excludes inter-domain Setup/Hold timing checks.
# These runs do NOT constitute CDC signoff or
# physical timing closure.
#
# NOTE: Displayed frequencies must match the SDC files.
# ------------------------------------------------------------

printf '\n=== 3. OPENROAD STA SCENARIOS ===\n'


# ------------------------------------------------------------
# SCENARIO 1: UNIFORM 100 MHz
# Use the default SDC with all clock domains at 100 MHz.
# ------------------------------------------------------------

printf '\nRunning STA: Uniform\n'
printf '  rd=100 | wr0=100 | wr1=100 | wr2=100 | wr3=100 MHz\n'

if ! ASIC_PROJECT_ROOT="$PROJECT_ROOT" ASIC_NANGATE_LIB="$LIB" \
    "$OPENROAD" -exit "$STA_TCL" > "$STA_LOG" 2>&1; then

    printf 'STA failed. Last 40 lines of %s:\n' "$STA_LOG" >&2
    tail -n 40 "$STA_LOG" >&2
    exit 1
fi

# Verify the overall maximum and minimum slack.
# A negative or missing value causes the script to fail.
max_slack="$(awk '$1 == "worst" && $2 == "slack" && $3 == "max" {v=$4} END {print v}' "$STA_LOG")"

min_slack="$(awk '$1 == "worst" && $2 == "slack" && $3 == "min" {v=$4} END {print v}' "$STA_LOG")"

if ! awk -v a="$max_slack" -v b="$min_slack" 'BEGIN {
    number = "^-?[0-9]+([.][0-9]+)?$"

    if (a !~ number || b !~ number ||
        a + 0 < 0 || b + 0 < 0) {
        exit 1
    }
}'; then

    printf '\nFAIL: A worst slack value is negative or missing.\n' >&2
    printf 'Check the STA log: %s\n' "$STA_LOG" >&2
    exit 1
fi


# ------------------------------------------------------------
# SCENARIOS 2 AND 3: SLOW WRITES / MIXED
#
# Reuse the SAME synthesized netlist.
# Only the SDC clock constraints are changed.
#
# This allows timing comparison without performing
# synthesis again for every clock configuration.
# ------------------------------------------------------------

for scenario in slow_writes mixed; do

    scenario_sdc="$PROJECT_ROOT/constraints/multi_channel_top_${scenario}.sdc"
    scenario_tcl="$PROJECT_ROOT/reports/run_sta_${scenario}.generated.tcl"
    scenario_log="$PROJECT_ROOT/reports/sta_${scenario}.log"

    # Verify the scenario-specific constraint file.
    if [[ ! -f "$scenario_sdc" ]]; then
        printf 'ERROR: Missing SDC: %s\n' "$scenario_sdc" >&2
        exit 1
    fi

    # Generate the scenario Tcl using the alternative SDC.
    sed "s@constraints/multi_channel_top.sdc@constraints/multi_channel_top_${scenario}.sdc@" \
        "$STA_TCL" > "$scenario_tcl"

    # Display the clock configuration.
    case "$scenario" in

        slow_writes)
            printf '\nRunning STA: Slow Writes\n'
            printf '  rd=100 | wr0=80 | wr1=70 | wr2=60 | wr3=50 MHz\n'
            ;;

        mixed)
            printf '\nRunning STA: Mixed\n'
            printf '  rd=80 | wr0=100 | wr1=90 | wr2=70 | wr3=60 MHz\n'
            ;;

    esac

    # Run pre-layout STA for the selected scenario.
    if ! ASIC_PROJECT_ROOT="$PROJECT_ROOT" ASIC_NANGATE_LIB="$LIB" \
        "$OPENROAD" -exit "$scenario_tcl" > "$scenario_log" 2>&1; then

        printf 'STA failed for scenario: %s\n' "$scenario" >&2
        tail -n 40 "$scenario_log" >&2
        exit 1
    fi

done


# ------------------------------------------------------------
# STEP 4: STA COMPARISON
#
# Read the three generated OpenROAD reports.
# Extract the worst slack for each timing-check type:
#
#   Setup
#   Hold
#   Recovery
#   Removal
#
# Display all results in a single comparison table.
# A missing or negative slack results in FAIL.
# ------------------------------------------------------------

python3 - <<'PY_STA_SUMMARY'
import re
from pathlib import Path

# Scenario names and corresponding STA reports.
scenarios = {
    "Uniform 100MHz": "sta_nangate45.log",
    "Slow Writes": "sta_slow_writes.log",
    "Mixed": "sta_mixed.log",
}

types = (
    "SETUP",
    "HOLD",
    "RECOVERY",
    "REMOVAL",
)

print("\n=== 4. STA COMPARISON (Slack in ns) ===")

print(
    f"{'Scenario':<18} "
    f"{'Setup':>9} "
    f"{'Hold':>9} "
    f"{'Recovery':>10} "
    f"{'Removal':>10} "
    f"{'Status':>9}"
)

print("-" * 75)

all_passed = True

for scenario, filename in scenarios.items():

    text = Path("reports", filename).read_text()

    results = {}
    current = None

    # Locate each CHECK_TYPE section in the STA log.
    for line in text.splitlines():

        if line.startswith("CHECK_TYPE_"):
            name = line.replace("CHECK_TYPE_", "")
            current = name if name in types else None
            continue

        if current:

            match = re.fullmatch(
                r"\s*\S+\s+([-+]?\d+(?:\.\d+)?)\s*",
                line
            )

            if match:
                value = float(match.group(1))

                # Keep the worst (smallest) slack.
                results[current] = min(
                    results.get(current, float("inf")),
                    value
                )

    # All four timing checks must be reported and pass.
    passed = all(
        t in results and results[t] >= 0
        for t in types
    )

    all_passed &= passed

    values = [
        f"{results[t]:+.2f}" if t in results else "N/A"
        for t in types
    ]

    print(
        f"{scenario:<18} "
        f"{values[0]:>9} "
        f"{values[1]:>9} "
        f"{values[2]:>10} "
        f"{values[3]:>10} "
        f"{'PASS' if passed else 'FAIL':>9}"
    )

# Fail if any scenario has negative or missing timing slack.
if not all_passed:
    raise SystemExit(
        "FAIL: Negative or missing timing slack"
    )

print(
    "\nPASS: All three STA scenarios passed "
    "reported timing checks."
)
PY_STA_SUMMARY


# ------------------------------------------------------------
# STEP 5: REPORT LOCATIONS
#
# Display the synthesis and STA report paths.
# These files are generated during execution.
#
# Results are based on pre-layout timing models.
# They do not include physical implementation effects.
# ------------------------------------------------------------

printf '\n=== REPORT FILES ===\n'

printf 'Synthesis: %s\n' "$SYNTH_LOG"
printf 'Uniform STA: %s\n' "$STA_LOG"

printf 'Slow Writes STA: %s\n' \
    "$PROJECT_ROOT/reports/sta_slow_writes.log"

printf 'Mixed STA: %s\n' \
    "$PROJECT_ROOT/reports/sta_mixed.log"

printf '\nNOTE: Pre-layout STA only; no physical timing closure or CDC signoff.\n'
