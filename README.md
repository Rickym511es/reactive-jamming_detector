# RTL Packet Detector Comparison

This repository contains a compact Verilog-2001 simulation project for comparing
three packet detectors on a continuous raw baseband I/Q sample stream.

## Directory Layout

- `RTL/energy_detector.v`: rolling-window energy threshold detector.
- `RTL/autocorr_detector.v`: delayed complex auto-correlation detector.
- `RTL/xcorr_detector.v`: sign-bit SHR cross-correlation detector.
- `testbench/tb_detector_compare.v`: testbench that replays raw I/Q samples,
  sends them to all detectors, records metrics, prints the summary table, and
  dumps VCD.
- `testcase/nominal/*.mem`: clean nominal raw I/Q replay data.
- `testcase/stress/*.mem`: degraded/stress raw I/Q replay data.

## Testbench Model

- One signed raw I/Q sample is provided per baseband sample-clock cycle.
- The default sample-clock period is `SAMPLE_CLK_PERIOD_NS = 500 ns`, equivalent
  to a 2 Msps stream. Set this to match the raw trace sample rate.
- The summary reports counts in sample cycles or hardware latency cycles only.
  Cycle time can be interpreted later for the selected hardware clock.
- Exactly `PACKET_COUNT = 100` packet intervals are expected by default.
- The testbench does not create ZigBee packets, RF, constellation points,
  O-QPSK pulse shaping, noise, or a jammer. Those conditions are prepared
  outside RTL and then fed into this testbench as raw I/Q.
- Idle/noise regions are whatever appears outside the packet intervals in the
  raw trace.
- During replay, `sample_i` and `sample_q` are driven from the selected
  testcase's `rx_i.mem` and `rx_q.mem`. `packet_active` and `packet_start` are
  derived only from the selected `packet_start.mem` and `packet_end.mem`.
- All three detectors receive the exact same sample stream on every
  sample-clock cycle.

## Testcases

The included testcase files are example raw-IQ replay sets, not measured
captures and not a guarantee that every packet interval is a complete
standards-valid ZigBee frame. They are intended to make the detector comparison
reproducible.

- `TOTAL_SAMPLES = 120000`
- `PACKET_COUNT = 100`
- Each packet interval: 960 sample cycles
- SHR reference length: 320 I/Q samples
- Sign-bit SHR xcorr observation window: 64 I/Q samples
- Sign-bit SHR xcorr match requirement: 98 percent
- Energy detector window: 16 samples

## ZigBee Timing Verification

The testcase uses a chip-level abstraction of the 2.4 GHz IEEE 802.15.4 PHY:

- Data rate: 250 kb/s
- Symbol width: 4 bits
- Symbol rate: 62.5 ksymbol/s
- DSSS spreading: 32 chips per symbol
- Chip rate: 2 Mchip/s
- Current testcase assumption: one raw I/Q sample per chip

Therefore:

- 1 chip-sample = 0.5 us
- 8 chip-samples = 4 us
- 1 symbol = 32 chip-samples = 16 us
- 1 byte = 2 symbols = 64 chip-samples
- 960 chip-samples = 30 symbols = 15 bytes

The included packets are 960 chip-samples long. This corresponds to a compact
15-byte PPDU-like replay interval: 4-byte preamble, 1-byte SFD, 1-byte PHR, and
9 bytes of payload-like content.

The report has two related but different detector contexts:

- In the ZigBee/IEEE 802.15.4 case, the receiver demodulates RF samples into a
  chip stream and searches for the known SHR pattern. The paper reports less
  than 4 us of additional FPGA processing delay for that detector path.
- In the raw-IQ appendix experiment here, the testbench directly replays raw
  baseband I/Q samples. The SHR-aware detector is modeled as a sign-bit I/Q
  cross-correlator against the beginning of the 320-sample SHR reference. The
  detector does not wait for all 320 samples. By default it uses a 64-sample
  early SHR prefix window, and its threshold is derived from the requested match
  percentage:

  `threshold = 2 * SIGN_XCORR_OBS_LEN * SIGN_XCORR_MATCH_PERCENT / 100`

  This keeps the RTL appendix simple and avoids full-precision matched-filter
  arithmetic in Verilog.

The `hw_process_cycles` field is separate from observation delay and represents a
conservative serial calculation proxy after enough samples are present. The
included defaults are: energy window = 16 cycles, auto-correlation window = 32
cycles, and sign-bit SHR compare = 64 cycles. A more parallel hardware
implementation can reduce these values without changing the raw-IQ observation
delay.

Local verification results:

- `testcase/nominal`: 100 packet intervals, each 960 samples; 320-sample
  sign-bit SHR reference; first packet start matches the reference.
- `testcase/stress`: 100 packet intervals, each 960 samples; 320-sample
  sign-bit SHR reference; first packet start matches the reference.

`testcase/nominal` is a clean packet replay:

- Idle regions contain low-amplitude raw I/Q noise only.
- Packet regions contain normal ZigBee/IEEE 802.15.4-like raw I/Q samples with
  an SHR reference region and payload-like sample content.
- High packet hit counts are expected. This testcase is mainly for comparing
  detection delay.

`testcase/stress` is designed to make the three detectors separate:

- Some packets are normal.
- Some packets are lower-energy but keep the correct SHR sign reference.
- Some packets are weak/noisy.
- Some packet intervals have high energy but a corrupted SHR reference.
- A few idle regions contain non-packet high-energy bursts.

This stress case is not meant to be a clean packet-loss model. It is a detector
selectivity/robustness case: energy detection, auto-correlation, sign-bit SHR
correlation should no longer all produce identical hit and false alarm behavior.

## Input Files

Each testcase directory contains:

- `rx_i.mem`: one signed I sample per line, two's-complement hex.
- `rx_q.mem`: one signed Q sample per line, two's-complement hex.
- `packet_start.mem`: 100 packet start cycle indices, hex.
- `packet_end.mem`: 100 packet end cycle indices, hex.
- `shr_ref_i.mem`: 320-sample SHR reference I sign bits.
- `shr_ref_q.mem`: 320-sample SHR reference Q sign bits.

These files can be replaced by measured or externally generated ZigBee-plus-noise
raw I/Q traces as long as the file names, sample width, packet count, and
parameter lengths are kept consistent.

For the sign-bit reference files, `0` means a non-negative sample and `1` means
a negative sample. The entries are ordered from the oldest SHR reference sample
to the newest reference sample. The reference should be generated from the same
raw-IQ preparation flow as the packet trace, so it matches the chosen sample
rate, filtering, and I/Q convention.

For the included testcase files, the sign-bit reference is derived from the
first packet's raw I/Q samples. This makes the reference match the exact I/Q
convention used by the replay files instead of assuming a separate RF or O-QPSK
model inside the testbench.

## Metrics

The testbench reports, for each detector:

- `packet_hit_count`
- `detection_rate`
- `avg_sample_delay`
- `max_sample_delay`
- `hw_process_cycles`
- `idle_false_alarm_count`

A detection is successful only when the detect pulse occurs between the stored
packet start and end cycles. Detections outside packet intervals are counted as
idle false alarms. Packet hits and idle false alarms are independent metrics, so
a detector can hit all 100 packets and still produce idle false alarms.

Observation delay counts how many raw I/Q samples after `packet_start` are seen
before the first detect pulse. This is useful for comparing how much packet
evidence each method needs, but it is not the detector hardware execution time.
The hardware execution-time proxy for final-report `t_detect` is reported as
`hw_process_cycles`. Do not add `avg_sample_delay` and `hw_process_cycles`
directly unless the report explicitly maps the raw-IQ sample period and hardware
clock period to the same time unit. They are intentionally reported as separate
scales.

The summary also prints replay length and packet duration in sample cycles.

## Tunable Parameters

Main parameters are at the top of `testbench/tb_detector_compare.v`: sample
width, sample clock period, hardware clock period, total replay samples, packet
count, SHR reference length, detector window lengths, auto-correlation delay,
metric widths, xcorr observation length, match percentage, and thresholds.

## Simulation Environment

The simulation is run on the 231 workstation using VCS.

Nominal testcase:

`vcs RTL/energy_detector.v RTL/autocorr_detector.v RTL/xcorr_detector.v testbench/tb_detector_compare.v -full64 -R +v2k -debug_access+all`

Stress testcase:

`vcs +define+TESTCASE_STRESS RTL/energy_detector.v RTL/autocorr_detector.v RTL/xcorr_detector.v testbench/tb_detector_compare.v -full64 -R +v2k -debug_access+all`
