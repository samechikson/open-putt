# Putt Offline Detector

A device that a golf ball rolls through (a 3D-printed "bridge" gate) which measures
how far **offline** each putt is from the center line, reporting it as **PUSH**
(ball past center) or **PULL** (ball short of center) in millimeters. Built first on
a Raspberry Pi, then migrated to an ESP32 for portability.

---

## Current status

- ✅ **Laser** on at startup
- ✅ **3× VL53L4CD** distance sensors read through an I2C multiplexer
- ✅ **Putt detection + push/pull offset** working standalone on the ESP32 (verified:
  a real putt reported a consistent ~+43 mm PUSH across all three sensors)
- ✅ **Per-sensor speed + center calibration** (per-sensor `CENTER_READING`, jig-measured)
- ✅ **BLE to the phone** — each putt is sent over BLE to the iOS app, which relays it to
  the backend under the signed-in user (no WiFi/hotspot on the ESP32). See "Transport".

---

## Hardware

### Final build (ESP32)

| Part                                                       | Notes                                                               |
| ---------------------------------------------------------- | ------------------------------------------------------------------- |
| **ELEGOO ESP32 DevKit** (ESP32-WROOM-32, USB-C, CP2102)    | Classic dual-core, WiFi + BT/BLE 4.2. 2.4 GHz WiFi only.            |
| **3× Adafruit VL53L4CD** ToF distance sensors (~1–1300 mm) | All share I2C address `0x29`.                                       |
| **Adafruit PCA9548** I2C multiplexer (TCA9548A-compatible) | Address `0x70`. Isolates the 3 identical sensors — one per channel. |
| **Green laser module** (520 nm, 3–5 V)                     | Driven directly from a GPIO. Red + / black − leads.                 |
| STEMMA QT / Qwiic cabling + jumpers, Wago 221 connectors   |                                                                     |
| 10,000 mAh USB power bank                                  | Field power via USB-C.                                              |

Sensors are on mux **channels 0, 7, 4** (Sensor 1, 2, 3), mounted in a row along the
roll direction.

### ESP32 wiring

| From            | To (ESP32) |
| --------------- | ---------- |
| Laser red (+)   | **GPIO26** |
| Laser black (−) | **GND**    |
| Mux SDA         | **GPIO21** |
| Mux SCL         | **GPIO22** |
| Mux VIN         | **3V3**    |
| Mux GND         | **GND**    |

Pin rules learned: avoid input-only **GPIO34–39** for outputs, and avoid strapping
pins (0, 2, 5, 12, 15) for buttons.

---

## The measurement (geometry + math)

- Sensor face → far wall of the gate ≈ **170 mm**; a centered ball's near surface
  reads ~**70–77 mm** depending on the sensor.
- A ToF sensor reads the distance to the ball's **near surface**, not its center.
  A standard golf ball is ⌀**42.67 mm** (radius **21.335 mm**).
- **Per-sensor calibration.** Rather than a shared geometric reference, each sensor
  stores `CENTER_READING[i]` — what it reads for a ball rolled dead-center through
  the gate (measured with a centering jig). The offset is the deviation from that:
  `offset_mm = closest_reading_mm − CENTER_READING[i]`
  - `> 0` → **PUSH**, `< 0` → **PULL**, within a small dead-band → **CENTER**
- This zeroes a center hit and absorbs each sensor's fixed bias — mounting
  differences and the middle sensor's crosstalk offset — in one step, so there's no
  single `CENTER_MM` or ball-radius term to tune. Re-measure `CENTER_READING` if the
  mount changes. Usable range is roughly ±64 mm before the ball touches a wall.

### Detection algorithm

1. **Calibrate** each channel's empty-gate baseline at startup (median of ~20 reads,
   ~170–180 mm).
2. A **ball is present** on a channel when its reading drops ≥ **25 mm** below that
   channel's baseline.
3. Capture the **closest approach** per sensor during the pass — the lowest of the
   *middle* samples (the first/last are the ball caught off-axis at the edge of the
   ~18° cone, so they read long and are dropped) = its true lateral distance.
4. **Finalize** once the gate has been clear for 150 ms; compute per-sensor offset +
   an average, print PUSH/PULL.

Tuning knobs live as constants at the top of the sketch: `CENTER_READING[]`
(per-sensor center calibration), `DETECT_MARGIN_MM`, `DEAD_BAND_MM`,
`CLEAR_TIMEOUT_MS`, `SENSOR_SPACING_MM` (for speed), `INVERT_PUSH_PULL` (flip if
push/pull come out mirrored for your sensor side).

---

## Code

### ESP32 (Arduino C++) — current platform

- `putt_tracker/putt_tracker.ino` — **the main program**: laser on, calibrate,
  detect putts, report push/pull.
- `sensors/sensors.ino` — reads all 3 sensors (bring-up/debug).
- `laser/laser.ino` — blinks the laser (GPIO26 bring-up).
- `blink/blink.ino` — onboard-LED blink (toolchain smoke test).

---

## Toolchain (macOS, ESP32)

Uses `arduino-cli` (installed via Homebrew).

- ESP32 core: `esp32:esp32` **3.3.11**
- Library: **STM32duino VL53L4CD** 1.0.5 (`arduino-cli lib install "STM32duino VL53L4CD"`)
- Board FQBN: `esp32:esp32:esp32:PartitionScheme=huge_app` (the `huge_app` partition is
  required — BLE overflows the default 1.3 MB app partition)
- Serial port (this Mac): `/dev/cu.usbserial-0001`

```bash
# compile + upload (from a sketch folder)
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app --upload -p /dev/cu.usbserial-0001 .

# watch serial output (Ctrl-C to quit)
arduino-cli monitor -p /dev/cu.usbserial-0001 -c baudrate=115200
```

---

## Transport (BLE → phone → backend)

The ESP32 has **no WiFi**. It advertises over BLE as **`PuttingGate`** and sends each
finalized putt as a notification; the iOS app (a BLE central) receives it and relays it
to `POST /api/device/putts` under the signed-in user's Firebase login. This means no
hotspot, no WiFi credentials, and putts are attributed to the real user.

- Service UUID `6b1a0001-8c2f-4d3a-9e5b-1f2c3d4e5f60`, notify characteristic
  `6b1a0002-…` — these must match the iOS app (`GateConnection.swift`).
- Payload (UTF-8 JSON, fits one BLE notification):
  `{ "session_id", "putt_index", "offset_mm", "label", "speed_mps", "sensors": [...] }`.
- The laser flashes only when a phone is connected and received the notification.
- **BLE needs the bigger app partition** — build with
  `--fqbn esp32:esp32:esp32:PartitionScheme=huge_app` (BLE overflows the default).

### Next steps

- **Later / optional:** a physical on/off (latching button on the `EN` pin); a
  transistor to drive the laser cleanly; deep-sleep + button wake; a BLE write
  characteristic so the phone can confirm a *backend*-accepted putt (flash on 201).

---

## Gotchas & lessons (hard-won)

- **Each identical-address sensor needs its own mux channel** — that's the whole reason
  for the PCA9548.
- **ESP32 serial quirks:** the boot-ROM prints at **74880 baud** (looks like garbage at
  115200 — ignore it), and the board **auto-resets when the serial port is opened**, which
  makes scripted/headless serial capture flaky. Use `arduino-cli monitor` interactively.
- **Per-sensor center calibration beats a shared geometric model** — the sensors differ
  enough (mounting + optical crosstalk on the middle one) that a single `CENTER_MM` left
  a consistent multi-mm bias. Zeroing each sensor against a dead-center ball fixes it.
