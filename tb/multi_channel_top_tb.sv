
`timescale 1ns/1ps

// ============================================================
// MULTI-CHANNEL ASYNC FIFO + ROUND-ROBIN ARBITER INTEGRATION TB
// ============================================================
// End-to-end verification of four independent write domains,
// asynchronous FIFOs, round-robin arbitration, and an output
// register slice operating in a shared read clock domain.
//
// Verify:
// - Independent clock-domain operation and reset release
// - FIFO FULL conditions and write-side backpressure
// - End-to-end data integrity and per-channel ordering
// - Legal one-hot arbitration and channel identification
// - Output stability during downstream backpressure
// - Channel isolation and sustained output throughput
// - Randomized multi-channel traffic
// - Reset with buffered data and clean restart
//
// Exact round-robin order and fairness are tested separately
// in rr_arbiter_tb. This test focuses on system integration.
// ============================================================

module multi_channel_top_tb;

    // ------------------------------------------------------------
    // TEST CONFIGURATION
    // ------------------------------------------------------------
    // Four independent sources, 32-bit words, depth-eight FIFOs.
    // Each channel has a separate scoreboard of MAX_PER_CH words.

    localparam int unsigned NUM_CHANNELS = 4;
    localparam int unsigned DATA_WIDTH   = 32;
    localparam int unsigned FIFO_DEPTH   = 8;
    localparam int unsigned MAX_PER_CH   = 1024;

    // Test phases control source traffic and sink readiness.
    typedef enum logic [2:0] {
        PH_IDLE,
        PH_BLOCK,
        PH_DRAIN,
        PH_RANDOM,
        PH_ISOLATE,
        PH_CONT
    } phase_t;


    // ============================================================
    // CLOCKS, RESET, AND DUT INTERFACE
    // ============================================================

    logic global_rst_n = 1'b0;

    // Separate procedural clock drivers; concatenate only for
    // the DUT port. This avoids multiple procedural drivers
    // on different bits of a shared packed clock vector.
    wire [NUM_CHANNELS-1:0] wr_clk_i;

    logic wr_clk0 = 1'b0;
    logic wr_clk1 = 1'b0;
    logic wr_clk2 = 1'b0;
    logic wr_clk3 = 1'b0;
    logic rd_clk  = 1'b0;

    assign wr_clk_i = {wr_clk3, wr_clk2, wr_clk1, wr_clk0};

    // Four independent write interfaces.
    logic [NUM_CHANNELS-1:0][DATA_WIDTH-1:0] wr_data_i;
    logic [NUM_CHANNELS-1:0] wr_valid_i;
    logic [NUM_CHANNELS-1:0] wr_ready_o;

    // Shared output interface after arbitration and regslice.
    logic [DATA_WIDTH-1:0] out_data_o;
    logic [NUM_CHANNELS-1:0] out_grant_o;
    logic out_valid_o;
    logic out_ready_i;

    // Instantiate the complete multi-channel system.
    multi_channel_top #(
        .NUM_CHANNELS(NUM_CHANNELS),
        .DATA_WIDTH  (DATA_WIDTH),
        .FIFO_DEPTH  (FIFO_DEPTH)
    ) dut (
        .global_rst_n(global_rst_n),
        .wr_clk_i    (wr_clk_i),
        .wr_data_i   (wr_data_i),
        .wr_valid_i  (wr_valid_i),
        .wr_ready_o  (wr_ready_o),
        .rd_clk      (rd_clk),
        .out_data_o  (out_data_o),
        .out_grant_o (out_grant_o),
        .out_valid_o (out_valid_o),
        .out_ready_i (out_ready_i)
    );

    // Generate four independent write clocks.
    // Clock periods: 10, 14, 18, and 22 ns.
    always #5  wr_clk0 = ~wr_clk0;
    always #7  wr_clk1 = ~wr_clk1;
    always #9  wr_clk2 = ~wr_clk2;
    always #11 wr_clk3 = ~wr_clk3;

    // Shared read clock: 16 ns period.
    always #8 rd_clk = ~rd_clk;


    // ============================================================
    // SCOREBOARD AND COVERAGE STATE
    // ============================================================
    // Each channel maintains its own transaction history.
    // This allows independent verification of data ordering
    // even when words from different channels are interleaved.
    // ============================================================

    phase_t phase = PH_IDLE;

    // Enable or disable individual traffic sources.
    logic [NUM_CHANNELS-1:0] source_enable = '1;

    // Target number of writes for each channel.
    int unsigned target_writes[NUM_CHANNELS];

    // Actual accepted write and read counts per channel.
    int unsigned writes[NUM_CHANNELS];
    int unsigned reads[NUM_CHANNELS];

    // Reference data: expected[channel][word_index].
    logic [DATA_WIDTH-1:0] expected[NUM_CHANNELS][MAX_PER_CH];

    // Deterministic pseudo-random state and FULL coverage flags.
    logic [31:0] read_rng = 32'h7153_2468;
    logic [NUM_CHANNELS-1:0] saw_full;

    // Track output stability across stalled read-clock cycles.
    logic previous_output_stall;
    logic [DATA_WIDTH-1:0] previous_output_data;
    logic [NUM_CHANNELS-1:0] previous_output_grant;

    // Global transaction and backpressure coverage counters.
    int unsigned stalled_output_cycles;
    int unsigned total_writes;
    int unsigned total_reads;


    // ============================================================
    // FUNCTION: PSEUDO-RANDOM NUMBER GENERATOR
    // ============================================================
    // Advance a 32-bit LFSR.
    // Fixed initial seeds make randomized tests reproducible.
    // ============================================================

    function automatic logic [31:0] lfsr_next(
        input logic [31:0] x
    );
        return {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]};
    endfunction


    // ============================================================
    // FUNCTION: GENERATE CHANNEL-SPECIFIC DATA
    // ============================================================
    // Encode a fixed marker, channel number, and sequence number.
    // This helps identify channel mixing, lost words, duplicate
    // words, and incorrect ordering in the output scoreboard.
    // ============================================================

    function automatic logic [DATA_WIDTH-1:0] make_word(
        input int channel,
        input int unsigned number
    );
        return DATA_WIDTH'(
            32'hA500_0000 |
            (32'(channel) << 16) |
            32'(number)
        );
    endfunction


    // ============================================================
    // PER-CHANNEL WRITE DRIVER AND MONITOR
    // ============================================================
    // Generate one independent source driver and write monitor
    // for each write-clock domain.
    //
    // Driver: changes inputs on falling clock edges.
    // Monitor: observes accepted writes on rising clock edges.
    // ============================================================

    for (genvar ch = 0; ch < NUM_CHANNELS; ch++) begin : gen_source

        logic [31:0] write_rng;
        logic source_valid;
        logic [DATA_WIDTH-1:0] source_data;

        logic previous_write_fire;
        logic previous_write_stall;
        logic [DATA_WIDTH-1:0] previous_write_data;
        logic saw_full_local;

        // Connect each source to its corresponding DUT interface.
        assign wr_valid_i[ch] = source_valid;
        assign wr_data_i[ch]  = source_data;
        assign saw_full[ch]   = saw_full_local;


        // --------------------------------------------------------
        // WRITE SOURCE DRIVER
        // --------------------------------------------------------
        // Generate traffic according to the active test phase.
        // Hold VALID and DATA stable until a write is accepted.
        // --------------------------------------------------------

        always @(negedge wr_clk_i[ch] or negedge global_rst_n) begin

            if (!global_rst_n) begin
                source_valid <= 1'b0;
                source_data  <= '0;
                write_rng    <= 32'h1357_9BDF ^ (32'(ch) << 8);

            end else begin
                write_rng <= lfsr_next(write_rng);

                // Wait until this write clock domain exits reset.
                if (!dut.wr_rst_n[ch]) begin
                    source_valid <= 1'b0;

                end else if (source_valid && !previous_write_fire) begin
                    // Previous word was not accepted.
                    // Keep VALID and DATA unchanged.

                end else begin
                    source_valid <= 1'b0;

                    // Generate another word only when this source
                    // is enabled and its write target is not reached.
                    if (phase != PH_IDLE && source_enable[ch] &&
                        writes[ch] < target_writes[ch]) begin

                        // Insert occasional source gaps during
                        // the randomized traffic phase.
                        if (phase != PH_RANDOM ||
                            write_rng[1:0] != 2'b00) begin

                            source_data  <= make_word(ch, writes[ch]);
                            source_valid <= 1'b1;
                        end
                    end
                end
            end
        end


        // --------------------------------------------------------
        // WRITE MONITOR / INPUT SCOREBOARD
        // --------------------------------------------------------
        // Verify source handshake behavior and record every
        // accepted input word in its channel-specific scoreboard.
        // --------------------------------------------------------

        always @(posedge wr_clk_i[ch] or negedge global_rst_n) begin

            if (!global_rst_n) begin
                writes[ch]           = 0;
                previous_write_fire  = 1'b0;
                previous_write_stall = 1'b0;
                previous_write_data  = '0;
                saw_full_local       = 1'b0;

            end else if (dut.wr_rst_n[ch]) begin

                // CHECK 1: READY/VALID SOURCE STABILITY
                // A source must not withdraw VALID or change DATA
                // while its previous transaction was stalled.
                if (previous_write_stall &&
                    (!source_valid ||
                     source_data !== previous_write_data))
                    $fatal(1,
                        "CH%0d: source changed a stalled word", ch);

                // Record whether the current write was accepted
                // and whether backpressure was applied.
                previous_write_fire  = source_valid && wr_ready_o[ch];
                previous_write_stall = source_valid && !wr_ready_o[ch];
                previous_write_data  = source_data;

                // COVERAGE: confirm that write-side backpressure
                // actually occurred on this channel.
                if (source_valid && !wr_ready_o[ch])
                    saw_full_local = 1'b1;

                if (previous_write_fire) begin

                    // CHECK 2: SCOREBOARD CAPACITY
                    // Stop if the expected-data array is too small.
                    if (writes[ch] >= MAX_PER_CH)
                        $fatal(1,
                            "CH%0d: increase MAX_PER_CH", ch);

                    // Record an accepted word for later comparison
                    // against the shared output of the system.
                    expected[ch][writes[ch]] = source_data;
                    writes[ch]++;
                    total_writes++;
                end

            end else begin
                previous_write_fire  = 1'b0;
                previous_write_stall = 1'b0;
            end
        end
    end


    // ============================================================
    // SHARED OUTPUT / SINK DRIVER
    // ============================================================
    // Control downstream READY according to the test phase.
    //
    // PH_BLOCK:   Never accept output words.
    // PH_DRAIN:   Accept output words continuously.
    // PH_ISOLATE: Accept output words continuously.
    // PH_CONT:    Accept output words continuously.
    // PH_RANDOM:  Apply pseudo-random downstream backpressure.
    // PH_IDLE:    Do not accept output words.
    // ============================================================

    always @(negedge rd_clk or negedge global_rst_n) begin

        if (!global_rst_n) begin
            out_ready_i <= 1'b0;
            read_rng    <= 32'h7153_2468;

        end else begin
            read_rng <= lfsr_next(read_rng);

            case (phase)
                PH_DRAIN, PH_ISOLATE, PH_CONT:
                    out_ready_i <= 1'b1;

                PH_RANDOM:
                    out_ready_i <= (read_rng[2:0] != 3'b000);

                default:
                    out_ready_i <= 1'b0;
            endcase
        end
    end


    // ============================================================
    // END-TO-END OUTPUT MONITOR
    // ============================================================
    // Verify:
    // 1. Legal arbitration and FIFO selection.
    // 2. Stable output data and channel ID during backpressure.
    // 3. Correct output channel identification.
    // 4. No duplicate or unexpected output transactions.
    // 5. Exact per-channel data ordering and integrity.
    //
    // Exact round-robin ordering and fairness are checked
    // separately in rr_arbiter_tb.
    // ============================================================

    always @(posedge rd_clk or negedge global_rst_n)
        begin : check_output

        if (!global_rst_n) begin

            for (int ch = 0; ch < NUM_CHANNELS; ch++)
                reads[ch] = 0;

            previous_output_stall = 1'b0;
            previous_output_data  = '0;
            previous_output_grant = '0;

        end else if (dut.rd_rst_n) begin

            // CHECK 3: ONE-HOT ARBITRATION
            // A valid internal grant must select exactly one FIFO.
            if (dut.grant_valid && !$onehot(dut.grant))
                $fatal(1, "Arbiter grant is not one-hot");

            // CHECK 4: INVALID GRANT
            // No FIFO may be selected when grant_valid is low.
            if (!dut.grant_valid && dut.grant != '0)
                $fatal(1, "Grant asserted with grant_valid=0");

            // CHECK 5: GRANT ONLY VALID FIFOS
            // The arbiter must never select a FIFO that has
            // no valid data available for reading.
            if ((dut.grant & ~dut.fifo_rd_valid) != '0)
                $fatal(1, "Arbiter granted a FIFO with no valid data");

            // CHECK 6: READ READY ROUTING
            // An unselected FIFO must not receive read READY.
            if ((dut.fifo_rd_ready & ~dut.grant) != '0)
                $fatal(1, "An unselected FIFO received rd_ready");

            // CHECK 7: OUTPUT STABILITY UNDER BACKPRESSURE
            // If an output was stalled, VALID, DATA, and channel ID
            // must remain unchanged on the next clock cycle.
            if (previous_output_stall &&
                (!out_valid_o ||
                 out_data_o !== previous_output_data ||
                 out_grant_o !== previous_output_grant))
                $fatal(1,
                    "Output data/grant changed under backpressure");

            // Save the output state for the next clock cycle.
            previous_output_stall = out_valid_o && !out_ready_i;
            previous_output_data  = out_data_o;
            previous_output_grant = out_grant_o;

            // COVERAGE: count cycles with a valid output
            // that could not be accepted by the sink.
            if (previous_output_stall)
                stalled_output_cycles++;

            // CHECK 8: VALID OUTPUT CHANNEL IDENTIFIER
            // Every valid output word must identify exactly
            // one of the source channels.
            if (out_valid_o && !$onehot(out_grant_o))
                $fatal(1, "Output channel ID is not one-hot");

            // An output transaction is completed only when
            // both output VALID and READY are asserted.
            if (out_valid_o && out_ready_i) begin

                // CHECK 9: CHANNEL ISOLATION
                // During the isolation phase, no output may
                // originate from a disabled source.
                if (phase == PH_ISOLATE &&
                    (out_grant_o & source_enable) == '0)
                    $fatal(1,
                        "Isolation failure: inactive channel produced an output");

                for (int ch = 0; ch < NUM_CHANNELS; ch++) begin

                    if (out_grant_o[ch]) begin

                        // CHECK 10: NO DUPLICATE/UNEXPECTED OUTPUT
                        // A channel cannot output more words than
                        // were previously accepted on its input.
                        if (reads[ch] >= writes[ch])
                            $fatal(1,
                                "CH%0d: duplicate/unexpected output", ch);

                        // CHECK 11: DATA INTEGRITY AND ORDER
                        // Compare the received output word against
                        // the next expected word for this channel.
                        if (out_data_o !== expected[ch][reads[ch]])
                            $fatal(1,
                                "CH%0d word %0d: expected %h, got %h",
                                ch, reads[ch],
                                expected[ch][reads[ch]], out_data_o);

                        // Update accepted output transaction counters.
                        reads[ch]++;
                        total_reads++;
                    end
                end
            end

        end else begin
            previous_output_stall = 1'b0;
        end
    end


    // ============================================================
    // TASK: WAIT UNTIL ALL CHANNELS ARE DRAINED
    // ============================================================
    // Wait until every channel has:
    // - Accepted all its target input words.
    // - Produced the same number of output words.
    //
    // This detects lost data, stalled channels, and deadlocks.
    // ============================================================

    task automatic wait_until_drained(input int max_cycles);

        bit finished;
        finished = 1'b0;

        for (int cycle = 0;
             cycle < max_cycles && !finished;
             cycle++) begin

            @(negedge rd_clk);
            finished = 1'b1;

            for (int ch = 0; ch < NUM_CHANNELS; ch++) begin

                // CHECK 12: COMPLETE CHANNEL DRAIN
                // Both written and read counts must reach the
                // configured target for every source channel.
                if (writes[ch] != target_writes[ch] ||
                    reads[ch] != target_writes[ch])
                    finished = 1'b0;
            end
        end

        // CHECK 13: DRAIN TIMEOUT
        // Report each channel's progress if the entire
        // system did not complete within the allowed time.
        if (!finished) begin

            for (int ch = 0; ch < NUM_CHANNELS; ch++)
                $display(
                    "CH%0d target=%0d written=%0d read=%0d",
                    ch, target_writes[ch], writes[ch], reads[ch]
                );

            $fatal(1, "TIMEOUT waiting for all channels to drain");
        end
    endtask


    // ============================================================
    // MAIN INTEGRATION TEST SEQUENCE
    // ============================================================

    initial begin : run_test

        // Initialize write targets and overall coverage counters.
        for (int ch = 0; ch < NUM_CHANNELS; ch++)
            target_writes[ch] = 0;

        total_writes = 0;
        total_reads  = 0;
        stalled_output_cycles = 0;

        // Enable optional waveform dumping with +trace.
        if ($test$plusargs("trace")) begin
            $dumpfile("multi_channel_top_tb.vcd");
            $dumpvars(0, multi_channel_top_tb);
        end


        // ========================================================
        // PHASE 1: GLOBAL RESET RELEASE / EMPTY OUTPUT
        // ========================================================
        // Verify:
        // - All independent clock domains exit reset.
        // - Reset synchronizers release correctly.
        // - The system does not present unexpected output data.
        // ========================================================

        // Hold the system in reset, then release it.
        repeat (8) @(negedge rd_clk);
        global_rst_n = 1'b1;

        // Allow reset synchronization to complete.
        repeat (20) @(negedge rd_clk);

        // Display the current reset state for debugging.
        $display(
            "RESET CHECK: global_rst_n=%b wr_rst_n=%b rd_rst_n=%b",
            global_rst_n, dut.wr_rst_n, dut.rd_rst_n
        );

        // CHECK 14: RESET RELEASE
        // All four write-domain resets and the shared read-domain
        // reset must have been released before traffic begins.
        if (dut.wr_rst_n !== {NUM_CHANNELS{1'b1}} ||
            dut.rd_rst_n !== 1'b1)
            $fatal(1, "Reset did not release in all clock domains");

        // CHECK 15: EMPTY OUTPUT AFTER RESET
        // No output should be valid before any input transaction.
        if (out_valid_o)
            $fatal(1, "Unexpected output after initial reset");

        $display("PHASE 1: output empty after reset - OK");


        // ========================================================
        // PHASE 2: FILL ALL FIFOS / BACKPRESSURE
        // ========================================================
        // Verify:
        // - Every FIFO eventually becomes full.
        // - Write-side backpressure is generated.
        // - A valid output word remains buffered while stalled.
        // ========================================================

        // Request more writes than the capacity of each FIFO.
        for (int ch = 0; ch < NUM_CHANNELS; ch++)
            target_writes[ch] = FIFO_DEPTH + 6;

        // Block downstream output transfers.
        phase = PH_BLOCK;

        // Allow sources to fill their FIFOs.
        repeat (100) @(negedge rd_clk);

        for (int ch = 0; ch < NUM_CHANNELS; ch++) begin

            // Display per-channel write and backpressure status.
            $display(
                "PHASE 2: CH%0d written=%0d, target=%0d, wr_ready=%b, wr_valid=%b, saw_full=%b",
                ch, writes[ch], target_writes[ch],
                wr_ready_o[ch], wr_valid_i[ch], saw_full[ch]
            );

            // COVERAGE: each FIFO must have rejected at least
            // one write attempt because it was not ready.
            if (!saw_full[ch])
                $fatal(1,
                    "CH%0d never observed FULL; inspect write count and handshake above",
                    ch);
        end

        // CHECK 16: OUTPUT HELD UNDER BACKPRESSURE
        // A valid word should already be buffered at the output
        // while downstream READY remains low.
        if (!out_valid_o)
            $fatal(1, "Expected held output during stall");

        $display("PHASE 2: all FIFOs filled; FULL/backpressure seen - OK");


        // ========================================================
        // PHASE 3: ORDERED DRAIN OF ALL CHANNELS
        // ========================================================
        // Verify:
        // - Every source reaches its requested number of writes.
        // - All accepted data eventually reaches the output.
        // - The end-to-end scoreboard confirms correct ordering.
        // ========================================================

        // Enable continuous downstream acceptance.
        phase = PH_DRAIN;

        // CHECK: all channels must finish writing and reading
        // their target words before the timeout expires.
        wait_until_drained(3000);

        $display("PHASE 3: ordered drain of all channels - OK");


        // ========================================================
        // PHASE 4: CHANNEL ISOLATION
        // ========================================================
        // Verify:
        // - Each source works independently of the other sources.
        // - No disabled channel appears at the output.
        // - All data drains correctly after each isolation case.
        // ========================================================

        for (int isolated_ch = 0;
             isolated_ch < NUM_CHANNELS;
             isolated_ch++) begin

            // Disable all sources except the selected channel.
            source_enable = '0;
            source_enable[isolated_ch] = 1'b1;

            // Generate 35 additional words for this channel.
            target_writes[isolated_ch] += 35;
            phase = PH_ISOLATE;

            // CHECK: all expected data must reach the output.
            wait_until_drained(3000);

            for (int ch = 0; ch < NUM_CHANNELS; ch++) begin

                // CHECK 17: NO UNREAD WORDS AFTER ISOLATION
                // Each channel's accepted write and read
                // transaction counts must match.
                if (writes[ch] != reads[ch])
                    $fatal(1,
                        "CH%0d not drained during isolation test", ch);
            end
        end

        $display("PHASE 4: channel isolation - OK");


        // ========================================================
        // PHASE 5: SUSTAINED OUTPUT THROUGHPUT
        // ========================================================
        // Verify that the complete system can deliver one
        // accepted output word per read-clock cycle for
        // 40 consecutive cycles, without throughput bubbles.
        // ========================================================

        // Re-enable all sources.
        source_enable = '1;

        // Generate additional data for each channel.
        for (int ch = 0; ch < NUM_CHANNELS; ch++)
            target_writes[ch] += 100;

        // Prefill FIFOs while downstream output is blocked.
        phase = PH_BLOCK;
        repeat (100) @(negedge rd_clk);

        // CHECK 18: DATA AVAILABLE BEFORE THROUGHPUT TEST
        // There must be a valid buffered output before starting
        // the consecutive-transfer measurement.
        if (!out_valid_o)
            $fatal(1, "Expected prefilled output before throughput test");

        // Enable continuous output transfers.
        phase = PH_CONT;
        @(negedge rd_clk);

        for (int cyc = 0; cyc < 40; cyc++) begin
            @(posedge rd_clk);

            // CHECK 19: NO THROUGHPUT BUBBLES
            // VALID and READY must both be asserted on each
            // of the 40 consecutive read-clock rising edges.
            if (!out_valid_o || !out_ready_i)
                $fatal(1, "Throughput bubble at cycle %0d", cyc);
        end

        // CHECK: all remaining buffered data must eventually drain.
        wait_until_drained(5000);

        $display("PHASE 5: sustained one-word-per-cycle output - OK");


        // ========================================================
        // PHASE 6: RANDOMIZED MULTI-CHANNEL TRAFFIC
        // ========================================================
        // Verify:
        // - Independent sources can operate simultaneously.
        // - Random source gaps and output stalls do not lose data.
        // - Per-channel data remains correctly ordered.
        // ========================================================

        // Add 250 additional words per source.
        for (int ch = 0; ch < NUM_CHANNELS; ch++)
            target_writes[ch] += 250;

        // Enable pseudo-random write gaps and sink backpressure.
        phase = PH_RANDOM;

        // CHECK: all randomized transactions must complete
        // and match the end-to-end scoreboard.
        wait_until_drained(7000);

        $display("PHASE 6: randomized 4-channel traffic - OK");


        // ========================================================
        // PHASE 7: RESET WITH BUFFERED DATA
        // ========================================================
        // Verify:
        // - Global reset can interrupt traffic with data buffered.
        // - Previously buffered transactions are discarded.
        // - No stale output appears after reset release.
        // ========================================================

        // Request additional data from every source.
        for (int ch = 0; ch < NUM_CHANNELS; ch++)
            target_writes[ch] += 24;

        // Block downstream transfers and accumulate buffered data.
        phase = PH_BLOCK;
        repeat (80) @(negedge rd_clk);

        // CHECK 20: BUFFERED DATA EXISTS BEFORE RESET
        // Ensure the reset test actually begins with
        // valid data held inside the system.
        if (!out_valid_o)
            $fatal(1, "Expected buffered data before reset");

        // Stop generating traffic and assert global reset.
        phase = PH_IDLE;
        global_rst_n = 1'b0;

        // Hold reset and allow it to propagate to all domains.
        repeat (8) @(negedge rd_clk);
        global_rst_n = 1'b1;
        repeat (20) @(negedge rd_clk);

        // CHECK 21: NO STALE DATA AFTER RESET
        // Previously buffered words must not reappear
        // as valid output data.
        if (out_valid_o)
            $fatal(1, "Stale data appeared after reset");

        $display("PHASE 7: global reset with buffered data - OK");


        // ========================================================
        // POST-RESET RESTART / FINAL COVERAGE
        // ========================================================
        // Verify that the system resumes normal operation using
        // fresh words and reset scoreboard indices.
        // ========================================================

        // Request 120 new words from each channel after reset.
        for (int ch = 0; ch < NUM_CHANNELS; ch++)
            target_writes[ch] = 120;

        phase = PH_RANDOM;

        // CHECK: all new transactions must complete correctly.
        wait_until_drained(4500);

        // Drain any remaining pipeline state.
        phase = PH_DRAIN;
        repeat (10) @(negedge rd_clk);

        // CHECK 22: OUTPUT EMPTY AFTER FINAL DRAIN
        // No valid output should remain after all data is consumed.
        if (out_valid_o)
            $fatal(1, "Output remained valid after final drain");

        // COVERAGE CHECK:
        // At least one output stall must have occurred, and
        // at least 1000 output transactions must be observed.
        if (stalled_output_cycles == 0 || total_reads < 1000)
            $fatal(1,
                "Coverage missing: stalls=%0d outputs=%0d",
                stalled_output_cycles, total_reads);


        // ========================================================
        // FINAL TEST REPORT
        // ========================================================
        // Reaching this point means all functional, protocol,
        // scoreboard, and coverage checks passed.
        // ========================================================

        $display("PASS: multi_channel_top integration test");

        $display(
            "      total accepted writes=%0d, total outputs=%0d",
            total_writes, total_reads
        );

        $display(
            "      channel isolation=%0d cases, throughput=40 consecutive cycles",
            NUM_CHANNELS
        );

        $display(
            "      stalled output cycles=%0d",
            stalled_output_cycles
        );

        $finish;
    end


    // ============================================================
    // GLOBAL WATCHDOG TIMEOUT
    // ============================================================
    // Prevent the testbench from hanging indefinitely when
    // a deadlock, stalled pipeline, or missing transaction occurs.
    // ============================================================

    initial begin
        #500000;
        $fatal(1, "Global watchdog timeout");
    end

endmodule
