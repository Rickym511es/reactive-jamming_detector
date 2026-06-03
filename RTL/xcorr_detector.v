`timescale 1ns/1ps

/*
 * xcorr_detector
 *
 * Sign-bit cross-correlation / SHR-reference detector for a raw baseband I/Q
 * stream.  This is the low-complexity correlator form discussed in the report:
 * it uses only the sign bit of each incoming I/Q sample and compares those
 * signs against an externally prepared SHR reference sign pattern.
 *
 * Each sample-clock cycle, the detector stores the sign bits of the received
 * I/Q sample, compares the most recent OBS_LEN samples against the beginning
 * of the stored SHR sign reference, and emits a one-cycle detect pulse on
 * threshold crossing.  REF_LEN is the full reference file length; OBS_LEN is
 * the early observation window used by this detector.
 */
module xcorr_detector
#(
    parameter SAMPLE_WIDTH = 12,
    parameter REF_LEN      = 320,
    parameter OBS_LEN      = 64,
    parameter METRIC_WIDTH = 10,
    parameter THRESHOLD    = 125
)
(
    input clk,
    input reset,
    input signed [SAMPLE_WIDTH-1:0] sample_i,
    input signed [SAMPLE_WIDTH-1:0] sample_q,
    output reg detect
);

    reg rx_i_sign [0:REF_LEN-1];
    reg rx_q_sign [0:REF_LEN-1];
    reg ref_i_sign [0:REF_LEN-1];
    reg ref_q_sign [0:REF_LEN-1];

    reg [METRIC_WIDTH-1:0] metric;
    reg metric_above_d;
    integer valid_count;
    integer idx;

    initial begin
        for (idx = 0; idx < REF_LEN; idx = idx + 1) begin
            ref_i_sign[idx] = 0;
            ref_q_sign[idx] = 0;
        end

        /*
         * External files contain one binary sign bit per line, ordered from
         * the oldest SHR reference sample to the newest sample.
         * 0 represents a non-negative sample, 1 represents a negative sample.
         */
`ifdef TESTCASE_STRESS
        $readmemb("testcase/stress/shr_ref_i.mem", ref_i_sign);
        $readmemb("testcase/stress/shr_ref_q.mem", ref_q_sign);
`else
        $readmemb("testcase/nominal/shr_ref_i.mem", ref_i_sign);
        $readmemb("testcase/nominal/shr_ref_q.mem", ref_q_sign);
`endif
    end

    always @(posedge clk) begin
        if (reset) begin
            metric <= 0;
            metric_above_d <= 0;
            detect <= 0;
            valid_count <= 0;
            for (idx = 0; idx < REF_LEN; idx = idx + 1) begin
                rx_i_sign[idx] <= 0;
                rx_q_sign[idx] <= 0;
            end
        end else begin
            metric = 0;
            for (idx = 0; idx < OBS_LEN; idx = idx + 1) begin
                if (rx_i_sign[OBS_LEN-1-idx] == ref_i_sign[idx]) begin
                    metric = metric + 1;
                end
                if (rx_q_sign[OBS_LEN-1-idx] == ref_q_sign[idx]) begin
                    metric = metric + 1;
                end
            end

            if (valid_count < OBS_LEN) begin
                valid_count <= valid_count + 1;
                detect <= 0;
                metric_above_d <= 0;
            end else begin
                if ((metric >= THRESHOLD) && (metric_above_d == 0)) begin
                    detect <= 1;
                end else begin
                    detect <= 0;
                end

                if (metric >= THRESHOLD) begin
                    metric_above_d <= 1;
                end else begin
                    metric_above_d <= 0;
                end
            end

            for (idx = REF_LEN - 1; idx > 0; idx = idx - 1) begin
                rx_i_sign[idx] <= rx_i_sign[idx-1];
                rx_q_sign[idx] <= rx_q_sign[idx-1];
            end
            rx_i_sign[0] <= sample_i[SAMPLE_WIDTH-1];
            rx_q_sign[0] <= sample_q[SAMPLE_WIDTH-1];
        end
    end

endmodule
