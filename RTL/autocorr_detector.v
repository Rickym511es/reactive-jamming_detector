`timescale 1ns/1ps

/*
 * autocorr_detector
 *
 * Simplified delayed auto-correlation detector for a continuous complex
 * baseband stream.  One signed I/Q sample is accepted every sample-clock
 * cycle.  The detector forms:
 *
 *   A[n] = sum over WINDOW_LEN samples of r[n-k] * conj(r[n-k-AUTO_DELAY])
 *
 * It thresholds |A[n]|^2 and emits a one-cycle detect pulse on threshold
 * crossing.  This favors repeated preamble-like structure, but it does not
 * check the full protocol-specific SHR reference.
 */
module autocorr_detector
#(
    parameter SAMPLE_WIDTH = 12,
    parameter WINDOW_LEN   = 16,
    parameter AUTO_DELAY   = 8,
    parameter CORR_WIDTH   = 44,
    parameter METRIC_WIDTH = 88,
    parameter THRESHOLD    = 64'd5000000000
)
(
    input clk,
    input reset,
    input signed [SAMPLE_WIDTH-1:0] sample_i,
    input signed [SAMPLE_WIDTH-1:0] sample_q,
    output reg detect
);

    reg signed [SAMPLE_WIDTH-1:0] delay_i [0:AUTO_DELAY-1];
    reg signed [SAMPLE_WIDTH-1:0] delay_q [0:AUTO_DELAY-1];

    reg signed [CORR_WIDTH-1:0] corr_real_window [0:WINDOW_LEN-1];
    reg signed [CORR_WIDTH-1:0] corr_imag_window [0:WINDOW_LEN-1];

    reg signed [CORR_WIDTH-1:0] corr_real_sum;
    reg signed [CORR_WIDTH-1:0] corr_imag_sum;
    reg signed [CORR_WIDTH-1:0] next_corr_real_sum;
    reg signed [CORR_WIDTH-1:0] next_corr_imag_sum;
    reg signed [CORR_WIDTH-1:0] corr_real_new;
    reg signed [CORR_WIDTH-1:0] corr_imag_new;

    reg signed [(2*SAMPLE_WIDTH)-1:0] sample_i_ext;
    reg signed [(2*SAMPLE_WIDTH)-1:0] sample_q_ext;
    reg signed [(2*SAMPLE_WIDTH)-1:0] delay_i_ext;
    reg signed [(2*SAMPLE_WIDTH)-1:0] delay_q_ext;
    reg signed [(2*SAMPLE_WIDTH)-1:0] prod_ii;
    reg signed [(2*SAMPLE_WIDTH)-1:0] prod_qq;
    reg signed [(2*SAMPLE_WIDTH)-1:0] prod_qi;
    reg signed [(2*SAMPLE_WIDTH)-1:0] prod_iq;

    reg signed [(2*CORR_WIDTH)-1:0] real_square;
    reg signed [(2*CORR_WIDTH)-1:0] imag_square;
    reg [METRIC_WIDTH-1:0] metric_next;

    reg metric_above_d;
    integer delay_ptr;
    integer corr_ptr;
    integer delay_count;
    integer corr_count;
    integer idx;

    always @(posedge clk) begin
        if (reset) begin
            corr_real_sum <= 0;
            corr_imag_sum <= 0;
            next_corr_real_sum <= 0;
            next_corr_imag_sum <= 0;
            corr_real_new <= 0;
            corr_imag_new <= 0;
            sample_i_ext <= 0;
            sample_q_ext <= 0;
            delay_i_ext <= 0;
            delay_q_ext <= 0;
            prod_ii <= 0;
            prod_qq <= 0;
            prod_qi <= 0;
            prod_iq <= 0;
            real_square <= 0;
            imag_square <= 0;
            metric_next <= 0;
            metric_above_d <= 0;
            detect <= 0;
            delay_ptr <= 0;
            corr_ptr <= 0;
            delay_count <= 0;
            corr_count <= 0;

            for (idx = 0; idx < AUTO_DELAY; idx = idx + 1) begin
                delay_i[idx] <= 0;
                delay_q[idx] <= 0;
            end

            for (idx = 0; idx < WINDOW_LEN; idx = idx + 1) begin
                corr_real_window[idx] <= 0;
                corr_imag_window[idx] <= 0;
            end
        end else begin
            sample_i_ext = sample_i;
            sample_q_ext = sample_q;
            delay_i_ext = delay_i[delay_ptr];
            delay_q_ext = delay_q[delay_ptr];

            prod_ii = sample_i_ext * delay_i_ext;
            prod_qq = sample_q_ext * delay_q_ext;
            prod_qi = sample_q_ext * delay_i_ext;
            prod_iq = sample_i_ext * delay_q_ext;

            corr_real_new = prod_ii + prod_qq;
            corr_imag_new = prod_qi - prod_iq;

            if (delay_count < AUTO_DELAY) begin
                delay_count <= delay_count + 1;
                detect <= 0;
                metric_above_d <= 0;
            end else begin
                if (corr_count < WINDOW_LEN) begin
                    next_corr_real_sum = corr_real_sum + corr_real_new;
                    next_corr_imag_sum = corr_imag_sum + corr_imag_new;
                    corr_count <= corr_count + 1;
                end else begin
                    next_corr_real_sum = corr_real_sum + corr_real_new - corr_real_window[corr_ptr];
                    next_corr_imag_sum = corr_imag_sum + corr_imag_new - corr_imag_window[corr_ptr];
                end

                corr_real_sum <= next_corr_real_sum;
                corr_imag_sum <= next_corr_imag_sum;
                corr_real_window[corr_ptr] <= corr_real_new;
                corr_imag_window[corr_ptr] <= corr_imag_new;

                if (corr_ptr == WINDOW_LEN - 1) begin
                    corr_ptr <= 0;
                end else begin
                    corr_ptr <= corr_ptr + 1;
                end

                real_square = next_corr_real_sum * next_corr_real_sum;
                imag_square = next_corr_imag_sum * next_corr_imag_sum;
                metric_next = real_square + imag_square;

                if (corr_count >= WINDOW_LEN - 1) begin
                    if ((metric_next >= THRESHOLD) && (metric_above_d == 0)) begin
                        detect <= 1;
                    end else begin
                        detect <= 0;
                    end

                    if (metric_next >= THRESHOLD) begin
                        metric_above_d <= 1;
                    end else begin
                        metric_above_d <= 0;
                    end
                end else begin
                    detect <= 0;
                    metric_above_d <= 0;
                end
            end

            delay_i[delay_ptr] <= sample_i;
            delay_q[delay_ptr] <= sample_q;

            if (delay_ptr == AUTO_DELAY - 1) begin
                delay_ptr <= 0;
            end else begin
                delay_ptr <= delay_ptr + 1;
            end
        end
    end

endmodule
