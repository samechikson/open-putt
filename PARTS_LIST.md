# Parts List

Physical parts needed to build the **Putting Gate** — the 3D-printed "bridge"
gate a golf ball rolls through, which measures how far offline each putt crosses
(PUSH/PULL in mm) and its speed, then sends each putt over BLE to the iOS app.

Wiring, geometry, and the measurement math live in
[`microcontroller/README.md`](microcontroller/README.md).

## Electronics

| # | Part | Qty | Notes |
|---|------|-----|-------|
| 1 | **[ELEGOO ESP32 DevKit](https://www.amazon.com/ELEGOO-ESP-WROOM-32-Development-Bluetooth-Microcontroller/dp/B0D8T53CQ5)** (ESP32-WROOM-32, USB-C, CP2102) | 1 | Classic dual-core, WiFi + BT/BLE 4.2 — the gate uses **BLE only** (no WiFi). This could be any bluetooth enabled ESP32. |
| 2 | **[Adafruit VL53L4CD](https://www.adafruit.com/product/5396)** ToF distance sensor (~1–1300 mm) | 3 | Measure the ball's near surface as it passes. All three share I²C address `0x29`, which is why the mux is required. Mounted in a row along the roll direction. |
| 3 | **[Adafruit PCA9548](https://www.adafruit.com/product/5626)** I²C multiplexer (TCA9548A-compatible) | 1 | Address `0x70`. Gives each identical-address sensor its own channel. Sensors sit on channels **0, 7, 4** (Sensor 1, 2, 3). |
| 4 | **[apinex TZ12X20-520L green laser module](https://www.apinex.com/ret2/TZ12X20-520L.html)** (520 nm, 3–5 V) | 1 | Defines the center line of the gate. Driven directly from a GPIO. |
| 5 | **[PM11 battery module](https://github.com/nulllaborg/pm11-module)** | 1 | Field power to the ESP32 over USB-C. |

## Wiring & connectors

| # | Part | Notes |
|---|------|-------|
| 6 | STEMMA QT / Qwiic cables | Chain the VL53L4CD sensors and PCA9548 mux (both are STEMMA QT boards). |
| 7 | Jumper wires (M–M / M–F) | Laser, power, and I²C tie-ins to the ESP32 header pins. |
| 8 | USB-C cable | ESP32 ↔ power bank (and ESP32 ↔ Mac for flashing/serial). |

## Connections (ESP32 pinout)

| From | To (ESP32) |
|------|-----------|
| Laser red (+) | **GPIO26** |
| Laser black (−) | **GND** |
| Mux SDA | **GPIO21** |
| Mux SCL | **GPIO22** |
| Mux VIN | **3V3** |
| Mux GND | **GND** |

Pin notes: avoid input-only **GPIO34–39** for outputs, and avoid strapping pins
(0, 2, 5, 12, 15).

## Reference geometry

- Sensor face → far wall of the gate ≈ **170 mm**.
- A centered ball's near surface reads ~**70–77 mm** (varies per sensor).
- Usable measurement range is roughly **±64 mm** before the ball touches a wall.

## Optional / future

Called out as "next steps" in the firmware README, not required for a working build:

- A latching on/off button on the ESP32 `EN` pin.
- A transistor to drive the laser cleanly (instead of straight off a GPIO).
- Deep-sleep + button wake for battery life.

## What's NOT needed

- **No camera / no video hardware** — putts are measured entirely by the gate's
  ToF sensors.
- **No WiFi networking gear** — the ESP32 talks to the phone over BLE.
