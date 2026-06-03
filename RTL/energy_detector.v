`timescale 1ns/1ps

/*
 * energy_detector
 *
 * Simplified packet detector for an IEEE 802.15.4-like baseband stream.
 * One signed I/Q sample is accepted every sample-clock cycle.  The detector keeps
 * a rolling window of I^2 + Q^2 energy values and asserts a one-cycle detect
 * pulse when the full rolling window crosses the configured threshold.
 *
 * This detector is intentionally protocol-agnostic: it is fast, but any
 * sufficiently strong idle/noise event can look packet-like.
 */
module energy_detector
#(
    parameter SAMPLE_WIDTH = 12,
    parameter WINDOW_LEN   = 16,
    parameter ENERGY_WIDTH = 40,
    parameter THRESHOLD    = 25000
)
(
    input clk,
    input reset,
    input signed [SAMPLE_WIDTH-1:0] sample_i,
    input signed [SAMPLE_WIDTH-1:0] sample_q,
    output reg detect
);

    reg [ENERGY_WIDTH-1:0] energy_window [0:WINDOW_LEN-1];
    reg [ENERGY_WIDTH-1:0] energy_sum;
    reg [ENERGY_WIDTH-1:0] sample_energy;
    reg [ENERGY_WIDTH-1:0] next_energy_sum;

    reg signed [(2*SAMPLE_WIDTH)-1:0] i_ext;
    reg signed [(2*SAMPLE_WIDTH)-1:0] q_ext;
    reg signed [(2*SAMPLE_WIDTH)-1:0] i_square;
    reg signed [(2*SAMPLE_WIDTH)-1:0] q_square;

    reg window_full;
    reg window_full_next;
    reg metric_above_d;
    integer write_ptr;
    integer sample_count;
    integer idx;

    always @(posedge clk) begin
        if (reset) begin
            energy_sum <= 0;
            sample_energy <= 0;
            next_energy_sum <= 0;
            i_ext <= 0;
            q_ext <= 0;
            i_square <= 0;
            q_square <= 0;
            window_full <= 0;
            window_full_next <= 0;
            metric_above_d <= 0;
            detect <= 0;
            write_ptr <= 0;
            sample_count <= 0;
            for (idx = 0; idx < WINDOW_LEN; idx = idx + 1) begin
                energy_window[idx] <= 0;
            end
        end else begin
            i_ext = sample_i;
            q_ext = sample_q;
            i_square = i_ext * i_ext;
            q_square = q_ext * q_ext;
            sample_energy = i_square + q_square;

            if (sample_count < WINDOW_LEN) begin
                next_energy_sum = energy_sum + sample_energy;
                if (sample_count == WINDOW_LEN - 1) begin
                    sample_count <= WINDOW_LEN;
                    window_full_next = 1;
                end else begin
                    sample_count <= sample_count + 1;
                    window_full_next = 0;
                end
            end else begin
                next_energy_sum = energy_sum + sample_energy - energy_window[write_ptr];
                window_full_next = 1;
            end

            energy_sum <= next_energy_sum;
            window_full <= window_full_next;
            energy_window[write_ptr] <= sample_energy;

            if (write_ptr == WINDOW_LEN - 1) begin
                write_ptr <= 0;
            end else begin
                write_ptr <= write_ptr + 1;
            end

            if (window_full_next && (next_energy_sum >= THRESHOLD) && (metric_above_d == 0)) begin
                detect <= 1;
            end else begin
                detect <= 0;
            end

            if (window_full_next && (next_energy_sum >= THRESHOLD)) begin
                metric_above_d <= 1;
            end else begin
                metric_above_d <= 0;
            end
        end
    end

endmodule
