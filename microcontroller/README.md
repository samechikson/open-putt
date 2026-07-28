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
- ⏳ **WiFi POST to a backend** — designed but not yet implemented (see "Next steps")

---

## Hardware

### Final build (ESP32)

| Part                                                       | Notes                                                               |
| ---------------------------------------------------------- | ------------------------------------------------------------------- |
| **ELEGOO ESP32 DevKit** (ESP32-WROOM-32, USB-C, CP2102)    | Classic dual-core, WiFi + BT/BLE 4.2. 2.4 GHz WiFi only.            |
| **3× Adafruit VL53L4CD** ToF distance sensors (~1–1300 mm) | All share I2C address `0x29`.                                       |
| **Adafruit PCA9548** I2C multiplexer (TCA9548A-compatible) | Address `0x70`. Isolates the 3 identical sensors — one per channel. |
| **5 mW laser module** (red +, black −, 3–5 V)              | Driven directly from a GPIO.                                        |
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

- Sensor face → far wall of the gate ≈ **170 mm**; center line measured at **80 mm**
  on the current mount (earlier mounts read 85 and 89 mm — it's a per-mount constant).
- A ToF sensor reads the distance to the ball's **near surface**, not its center.
  A standard golf ball is ⌀**42.67 mm** (radius **21.335 mm**).
- **Offset from center:**
  `offset_mm = (surface_reading_mm + BALL_RADIUS_MM) − CENTER_MM`
  - `> 0` → **PUSH**, `< 0` → **PULL**, within a small dead-band → **CENTER**
- A centered ball therefore correctly reports ~0 (the radius cancels the reference).
  Usable range is roughly ±64 mm before the ball touches a wall.

### Detection algorithm

1. **Calibrate** each channel's empty-gate baseline at startup (median of ~20 reads,
   ~170–180 mm).
2. A **ball is present** on a channel when its reading drops ≥ **25 mm** below that
   channel's baseline.
3. Capture the **minimum** reading per sensor during the pass = the ball's closest
   (perpendicular) approach = its true lateral distance.
4. **Finalize** once the gate has been clear for 150 ms; compute per-sensor offset +
   an average, print PUSH/PULL.

Tuning knobs live as constants at the top of the sketch: `CENTER_MM`,
`BALL_DIAMETER_MM`, `DETECT_MARGIN_MM`, `DEAD_BAND_MM`, `CLEAR_TIMEOUT_MS`,
`INVERT_PUSH_PULL` (flip if push/pull come out mirrored for your sensor side).

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
- Board FQBN: `esp32:esp32:esp32`
- Serial port (this Mac): `/dev/cu.usbserial-0001`

```bash
# compile + upload (from a sketch folder)
arduino-cli compile --fqbn esp32:esp32:esp32 --upload -p /dev/cu.usbserial-0001 .

# watch serial output (Ctrl-C to quit)
arduino-cli monitor -p /dev/cu.usbserial-0001 -c baudrate=115200
```

---

## Next steps

1. **WiFi POST (step 4).** Add `WiFi.begin()` + an HTTP `POST` of each putt's JSON in
   `report()`. Plan:
   - Credentials + backend URL in a separate `secrets.h` (gitignored).
   - Payload shape: `{ "putt": N, "avg_offset_mm": X, "label": "PUSH", "sensors": [...] }`
   - Connect to a **phone hotspot** for field use. **iPhone: enable Personal Hotspot →
     "Maximize Compatibility"** so it broadcasts 2.4 GHz (the ESP32 can't see 5 GHz).
   - Prove the pipeline against a free endpoint (e.g. webhook.site) before pointing at
     the real backend.
2. **Later / optional:** BLE-to-phone relay; a physical on/off (latching button on the
   ESP32 `EN` pin); a transistor to drive the laser cleanly; deep-sleep + button wake.

---

## Gotchas & lessons (hard-won)

- **Each identical-address sensor needs its own mux channel** — that's the whole reason
  for the PCA9548.
- **ESP32 serial quirks:** the boot-ROM prints at **74880 baud** (looks like garbage at
  115200 — ignore it), and the board **auto-resets when the serial port is opened**, which
  makes scripted/headless serial capture flaky. Use `arduino-cli monitor` interactively.
- **Ball-radius correction is essential** — without it a centered putt mis-reads by ~21 mm.
