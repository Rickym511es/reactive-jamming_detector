`timescale 1ns/1ps

/*
 * tb_detector_compare
 *
 * RTL-level experiment for comparing three packet detectors on a continuous
 * raw baseband I/Q sample stream.  This testbench does not synthesize RF,
 * constellation points, O-QPSK pulse shaping, a jammer, or a ZigBee PHY
 * waveform.  Those steps should be completed before simulation by an external
 * waveform/capture preparation flow.  The prepared raw I/Q samples are then
 * replayed here, one signed I/Q sample per sample-clock cycle.
 *
 * The testbench also reads packet start/end cycle metadata.  All detectors
 * receive the same raw stream in parallel.  The final summary reports packet
 * detections, detection delay, and detections that occurred during idle/noise
 * regions.
 */
module tb_detector_compare;

    parameter SAMPLE_WIDTH          = 12;
    parameter SAMPLE_CLK_PERIOD_NS  = 500;
    parameter HW_CLK_PERIOD_NS      = 10;
    parameter TOTAL_SAMPLES         = 120000;
    parameter PACKET_COUNT          = 100;
    parameter SHR_REF_LEN           = 320;
    parameter ENERGY_WINDOW_LEN     = 16;
    parameter AUTOCORR_WINDOW_LEN   = 32;
    parameter AUTOCORR_DELAY        = 32;
    parameter ENERGY_THRESHOLD      = 90000;
    parameter AUTOCORR_THRESHOLD    = 64'd30000000000;
    parameter SIGN_XCORR_OBS_LEN    = 64;
    parameter SIGN_XCORR_MATCH_PERCENT = 98;
    parameter SIGN_XCORR_METRIC_WIDTH = 10;
    parameter SIGN_XCORR_THRESHOLD    = (2 * SIGN_XCORR_OBS_LEN * SIGN_XCORR_MATCH_PERCENT) / 100;
    parameter ENERGY_HW_PROC_CYCLES   = ENERGY_WINDOW_LEN;
    parameter AUTOCORR_HW_PROC_CYCLES = AUTOCORR_WINDOW_LEN;
    parameter SIGN_XCORR_HW_PROC_CYCLES = SIGN_XCORR_OBS_LEN;

    reg clk;
    reg reset;
    reg signed [SAMPLE_WIDTH-1:0] sample_i;
    reg signed [SAMPLE_WIDTH-1:0] sample_q;
    reg packet_active;
    reg packet_start;

    wire energy_detect;
    wire autocorr_detect;
    wire xcorr_detect;

    reg signed [SAMPLE_WIDTH-1:0] rx_i_mem [0:TOTAL_SAMPLES-1];
    reg signed [SAMPLE_WIDTH-1:0] rx_q_mem [0:TOTAL_SAMPLES-1];
    reg [31:0] packet_start_mem [0:PACKET_COUNT-1];
    reg [31:0] packet_end_mem [0:PACKET_COUNT-1];

    integer current_cycle;
    integer active_packet_index;

    integer packet_start_cycle [0:PACKET_COUNT-1];
    integer packet_end_cycle [0:PACKET_COUNT-1];

    integer energy_detected_flag [0:PACKET_COUNT-1];
    integer autocorr_detected_flag [0:PACKET_COUNT-1];
    integer xcorr_detected_flag [0:PACKET_COUNT-1];

    integer energy_delay [0:PACKET_COUNT-1];
    integer autocorr_delay [0:PACKET_COUNT-1];
    integer xcorr_delay [0:PACKET_COUNT-1];

    integer energy_detected_count;
    integer autocorr_detected_count;
    integer xcorr_detected_count;

    integer energy_delay_sum;
    integer autocorr_delay_sum;
    integer xcorr_delay_sum;

    integer energy_max_delay;
    integer autocorr_max_delay;
    integer xcorr_max_delay;

    integer energy_false_alarm_count;
    integer autocorr_false_alarm_count;
    integer xcorr_false_alarm_count;

    integer pkt_idx;
    integer pkt_scan_idx;
    integer sample_idx;
    integer delay_value;
    integer rate_x100;
    integer avg_delay_value;
    integer hw_proc_value;
    integer packet_duration_value;
    integer packet_duration_sum;
    integer packet_duration_min;
    integer packet_duration_max;
    integer packet_duration_avg;

    energy_detector
    #(
        .SAMPLE_WIDTH(SAMPLE_WIDTH),
        .WINDOW_LEN(ENERGY_WINDOW_LEN),
        .ENERGY_WIDTH(40),
        .THRESHOLD(ENERGY_THRESHOLD)
    )
    u_energy_detector
    (
        .clk(clk),
        .reset(reset),
        .sample_i(sample_i),
        .sample_q(sample_q),
        .detect(energy_detect)
    );

    autocorr_detector
    #(
        .SAMPLE_WIDTH(SAMPLE_WIDTH),
        .WINDOW_LEN(AUTOCORR_WINDOW_LEN),
        .AUTO_DELAY(AUTOCORR_DELAY),
        .CORR_WIDTH(44),
        .METRIC_WIDTH(88),
        .THRESHOLD(AUTOCORR_THRESHOLD)
    )
    u_autocorr_detector
    (
        .clk(clk),
        .reset(reset),
        .sample_i(sample_i),
        .sample_q(sample_q),
        .detect(autocorr_detect)
    );

    xcorr_detector
    #(
        .SAMPLE_WIDTH(SAMPLE_WIDTH),
        .REF_LEN(SHR_REF_LEN),
        .OBS_LEN(SIGN_XCORR_OBS_LEN),
        .METRIC_WIDTH(SIGN_XCORR_METRIC_WIDTH),
        .THRESHOLD(SIGN_XCORR_THRESHOLD)
    )
    u_xcorr_detector
    (
        .clk(clk),
        .reset(reset),
        .sample_i(sample_i),
        .sample_q(sample_q),
        .detect(xcorr_detect)
    );

    initial begin
        clk = 0;
        forever #(SAMPLE_CLK_PERIOD_NS / 2) clk = ~clk;
    end

    initial begin
        $dumpfile("detector_compare.vcd");
        $dumpvars(0, tb_detector_compare);
    end

    /*
     * Scoreboard.  Detector outputs are registered in the detector modules,
     * so this block waits a delta after the clock edge before sampling them.
     */
    always @(posedge clk) begin
        if (reset) begin
            energy_detected_count <= 0;
            autocorr_detected_count <= 0;
            xcorr_detected_count <= 0;
            energy_delay_sum <= 0;
            autocorr_delay_sum <= 0;
            xcorr_delay_sum <= 0;
            energy_max_delay <= 0;
            autocorr_max_delay <= 0;
            xcorr_max_delay <= 0;
            energy_false_alarm_count <= 0;
            autocorr_false_alarm_count <= 0;
            xcorr_false_alarm_count <= 0;
        end else begin
            #1;

            if (energy_detect) begin
                if (packet_active && (active_packet_index >= 0) &&
                    (current_cycle >= packet_start_cycle[active_packet_index]) &&
                    (current_cycle <= packet_end_cycle[active_packet_index])) begin
                    if (energy_detected_flag[active_packet_index] == 0) begin
                        delay_value = current_cycle - packet_start_cycle[active_packet_index];
                        energy_delay[active_packet_index] = delay_value;
                        energy_delay_sum = energy_delay_sum + delay_value;
                        energy_detected_count = energy_detected_count + 1;
                        energy_detected_flag[active_packet_index] = 1;
                        if (delay_value > energy_max_delay) begin
                            energy_max_delay = delay_value;
                        end
                    end
                end else begin
                    energy_false_alarm_count = energy_false_alarm_count + 1;
                end
            end

            if (autocorr_detect) begin
                if (packet_active && (active_packet_index >= 0) &&
                    (current_cycle >= packet_start_cycle[active_packet_index]) &&
                    (current_cycle <= packet_end_cycle[active_packet_index])) begin
                    if (autocorr_detected_flag[active_packet_index] == 0) begin
                        delay_value = current_cycle - packet_start_cycle[active_packet_index];
                        autocorr_delay[active_packet_index] = delay_value;
                        autocorr_delay_sum = autocorr_delay_sum + delay_value;
                        autocorr_detected_count = autocorr_detected_count + 1;
                        autocorr_detected_flag[active_packet_index] = 1;
                        if (delay_value > autocorr_max_delay) begin
                            autocorr_max_delay = delay_value;
                        end
                    end
                end else begin
                    autocorr_false_alarm_count = autocorr_false_alarm_count + 1;
                end
            end

            if (xcorr_detect) begin
                if (packet_active && (active_packet_index >= 0) &&
                    (current_cycle >= packet_start_cycle[active_packet_index]) &&
                    (current_cycle <= packet_end_cycle[active_packet_index])) begin
                    if (xcorr_detected_flag[active_packet_index] == 0) begin
                        delay_value = current_cycle - packet_start_cycle[active_packet_index];
                        xcorr_delay[active_packet_index] = delay_value;
                        xcorr_delay_sum = xcorr_delay_sum + delay_value;
                        xcorr_detected_count = xcorr_detected_count + 1;
                        xcorr_detected_flag[active_packet_index] = 1;
                        if (delay_value > xcorr_max_delay) begin
                            xcorr_max_delay = delay_value;
                        end
                    end
                end else begin
                    xcorr_false_alarm_count = xcorr_false_alarm_count + 1;
                end
            end
        end
    end

    initial begin
        reset = 1;
        sample_i = 0;
        sample_q = 0;
        packet_active = 0;
        packet_start = 0;
        current_cycle = 0;
        active_packet_index = -1;

        energy_detected_count = 0;
        autocorr_detected_count = 0;
        xcorr_detected_count = 0;
        energy_delay_sum = 0;
        autocorr_delay_sum = 0;
        xcorr_delay_sum = 0;
        energy_max_delay = 0;
        autocorr_max_delay = 0;
        xcorr_max_delay = 0;
        energy_false_alarm_count = 0;
        autocorr_false_alarm_count = 0;
        xcorr_false_alarm_count = 0;

        for (sample_idx = 0; sample_idx < TOTAL_SAMPLES; sample_idx = sample_idx + 1) begin
            rx_i_mem[sample_idx] = 0;
            rx_q_mem[sample_idx] = 0;
        end

        for (pkt_idx = 0; pkt_idx < PACKET_COUNT; pkt_idx = pkt_idx + 1) begin
            packet_start_mem[pkt_idx] = 0;
            packet_end_mem[pkt_idx] = 0;
            packet_start_cycle[pkt_idx] = 0;
            packet_end_cycle[pkt_idx] = 0;
            energy_detected_flag[pkt_idx] = 0;
            autocorr_detected_flag[pkt_idx] = 0;
            xcorr_detected_flag[pkt_idx] = 0;
            energy_delay[pkt_idx] = -1;
            autocorr_delay[pkt_idx] = -1;
            xcorr_delay[pkt_idx] = -1;
        end

        /*
         * Raw input files are produced outside the RTL testbench.
         * testcase/nominal and testcase/stress contain raw replay files.
         * Samples use two's-complement hexadecimal values. Packet boundary
         * files contain PACKET_COUNT cycle indices.
         */
`ifdef TESTCASE_STRESS
        $readmemh("testcase/stress/rx_i.mem", rx_i_mem);
        $readmemh("testcase/stress/rx_q.mem", rx_q_mem);
        $readmemh("testcase/stress/packet_start.mem", packet_start_mem);
        $readmemh("testcase/stress/packet_end.mem", packet_end_mem);
`else
        $readmemh("testcase/nominal/rx_i.mem", rx_i_mem);
        $readmemh("testcase/nominal/rx_q.mem", rx_q_mem);
        $readmemh("testcase/nominal/packet_start.mem", packet_start_mem);
        $readmemh("testcase/nominal/packet_end.mem", packet_end_mem);
`endif

        packet_duration_sum = 0;
        packet_duration_min = 0;
        packet_duration_max = 0;

        for (pkt_idx = 0; pkt_idx < PACKET_COUNT; pkt_idx = pkt_idx + 1) begin
            packet_start_cycle[pkt_idx] = packet_start_mem[pkt_idx];
            packet_end_cycle[pkt_idx] = packet_end_mem[pkt_idx];
            packet_duration_value = packet_end_cycle[pkt_idx] - packet_start_cycle[pkt_idx] + 1;
            packet_duration_sum = packet_duration_sum + packet_duration_value;
            if (pkt_idx == 0) begin
                packet_duration_min = packet_duration_value;
                packet_duration_max = packet_duration_value;
            end else begin
                if (packet_duration_value < packet_duration_min) begin
                    packet_duration_min = packet_duration_value;
                end
                if (packet_duration_value > packet_duration_max) begin
                    packet_duration_max = packet_duration_value;
                end
            end
        end

        packet_duration_avg = packet_duration_sum / PACKET_COUNT;

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 0;

        for (sample_idx = 0; sample_idx < TOTAL_SAMPLES; sample_idx = sample_idx + 1) begin
            current_cycle = sample_idx;
            sample_i = rx_i_mem[sample_idx];
            sample_q = rx_q_mem[sample_idx];
            packet_active = 0;
            packet_start = 0;
            active_packet_index = -1;

            for (pkt_scan_idx = 0; pkt_scan_idx < PACKET_COUNT; pkt_scan_idx = pkt_scan_idx + 1) begin
                if ((sample_idx >= packet_start_cycle[pkt_scan_idx]) &&
                    (sample_idx <= packet_end_cycle[pkt_scan_idx])) begin
                    packet_active = 1;
                    active_packet_index = pkt_scan_idx;
                    if (sample_idx == packet_start_cycle[pkt_scan_idx]) begin
                        packet_start = 1;
                    end
                end
            end

            @(posedge clk);
            @(negedge clk);
        end

        packet_active = 0;
        packet_start = 0;
        active_packet_index = -1;
        #1;

        $display("");
        $display("Detector comparison summary");
`ifdef TESTCASE_STRESS
        $display("Testcase: stress");
`else
        $display("Testcase: nominal");
`endif
        $display("Packets expected: %0d", PACKET_COUNT);
        $display("Raw samples replayed: %0d", TOTAL_SAMPLES);
        $display("Sample cycles replayed: %0d", TOTAL_SAMPLES);
        $display("Sign-bit SHR xcorr observation window: %0d sample cycles", SIGN_XCORR_OBS_LEN);
        $display("Sign-bit SHR xcorr match threshold: %0d of %0d sign matches",
                 SIGN_XCORR_THRESHOLD, 2 * SIGN_XCORR_OBS_LEN);
        $display("Packet duration min/avg/max: %0d/%0d/%0d sample cycles",
                 packet_duration_min, packet_duration_avg, packet_duration_max);
        if (packet_duration_min == packet_duration_max) begin
            $display("Each packet duration: %0d sample cycles", packet_duration_avg);
        end
        $display("Note: packet_hit_count and idle_false_alarm_count are independent metrics.");
        $display("Note: sample delay counts raw I/Q samples after packet_start.");
        $display("Note: hardware process cycles are reported separately and are not added to sample delay.");
        $display("+----------------------+------------------+----------+------------------+------------------+---------------------+-------------------+");
        $display("| detector name        | packet_hit_count | det_rate | avg_sample_delay | max_sample_delay | hw_process_cycles   | false_alarm_count |");
        $display("+----------------------+------------------+----------+------------------+------------------+---------------------+-------------------+");

        rate_x100 = (energy_detected_count * 100) / PACKET_COUNT;
        if (energy_detected_count > 0) begin
            avg_delay_value = energy_delay_sum / energy_detected_count;
        end else begin
            avg_delay_value = 0;
        end
        hw_proc_value = ENERGY_HW_PROC_CYCLES;
        $display("| energy               | %16d | %3d.%02d    | %16d | %16d | %19d | %17d |",
                 energy_detected_count, rate_x100 / 100, rate_x100 % 100,
                 avg_delay_value, energy_max_delay, hw_proc_value,
                 energy_false_alarm_count);

        rate_x100 = (autocorr_detected_count * 100) / PACKET_COUNT;
        if (autocorr_detected_count > 0) begin
            avg_delay_value = autocorr_delay_sum / autocorr_detected_count;
        end else begin
            avg_delay_value = 0;
        end
        hw_proc_value = AUTOCORR_HW_PROC_CYCLES;
        $display("| auto-correlation     | %16d | %3d.%02d    | %16d | %16d | %19d | %17d |",
                 autocorr_detected_count, rate_x100 / 100, rate_x100 % 100,
                 avg_delay_value, autocorr_max_delay, hw_proc_value,
                 autocorr_false_alarm_count);

        rate_x100 = (xcorr_detected_count * 100) / PACKET_COUNT;
        if (xcorr_detected_count > 0) begin
            avg_delay_value = xcorr_delay_sum / xcorr_detected_count;
        end else begin
            avg_delay_value = 0;
        end
        hw_proc_value = SIGN_XCORR_HW_PROC_CYCLES;
        $display("| sign-bit SHR xcorr   | %16d | %3d.%02d    | %16d | %16d | %19d | %17d |",
                 xcorr_detected_count, rate_x100 / 100, rate_x100 % 100,
                 avg_delay_value, xcorr_max_delay, hw_proc_value,
                 xcorr_false_alarm_count);

        $display("+----------------------+------------------+----------+------------------+------------------+---------------------+-------------------+");
        $display("VCD waveform file: detector_compare.vcd");
        $finish;
    end

endmodule
