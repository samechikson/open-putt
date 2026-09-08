# Parts List

Physical parts needed to build the **Putting Gate** — the 3D-printed "bridge"
gate a golf ball rolls through, which measures how far offline each putt crosses
(PUSH/PULL in mm) and its speed, then sends each putt over BLE to the iOS app.

Wiring, geometry, and the measurement math live in
[`microcontroller/README.md`](microcontroller/README.md).

## Electronics

| #   | Part                                                                                                                                                      | Qty | Price (approx, ea) | Notes                                                                                                                                                          |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **[ELEGOO ESP32 DevKit](https://www.amazon.com/ELEGOO-ESP-WROOM-32-Development-Bluetooth-Microcontroller/dp/B0D8T53CQ5)** (ESP32-WROOM-32, USB-C, CP2102) | 1   | ~$10               | Classic dual-core, WiFi + BT/BLE 4.2 — the gate uses **BLE only** (no WiFi). This could be any bluetooth enabled ESP32.                                        |
| 2   | **[Adafruit VL53L4CD](https://www.adafruit.com/product/5396)** ToF distance sensor (~1–1300 mm)                                                           | 3   | ~$15               | Measure the ball's near surface as it passes. All three share I²C address `0x29`, which is why the mux is required. Mounted in a row along the roll direction. |
| 3   | **[Adafruit PCA9548](https://www.adafruit.com/product/5626)** I²C multiplexer (TCA9548A-compatible)                                                       | 1   | ~$7                | Address `0x70`. Gives each identical-address sensor its own channel. Sensors sit on channels **0, 7, 4** (Sensor 1, 2, 3).                                     |
| 4   | **[apinex TZ12X20-520L green laser module](https://www.apinex.com/ret2/TZ12X20-520L.html)** (520 nm, 3–5 V)                                               | 1   | ~$50               | Defines the center line of the gate. Driven directly from a GPIO.                                                                                              |
| 5   | **[PM11 battery module](https://github.com/nulllaborg/pm11-module)**                                                                                      | 1   | ~$10               | Field power to the ESP32 over USB-C. Sold as a pack.                                                                                                           |

Electronics subtotal: **~$122** (VL53L4CD ×3 = ~$45).

## Wiring & connectors

| #   | Part                     | Price (approx) | Notes                                                                   |
| --- | ------------------------ | -------------- | ----------------------------------------------------------------------- |
| 6   | STEMMA QT / Qwiic cables | ~$4            | Chain the VL53L4CD sensors and PCA9548 mux (both are STEMMA QT boards). |
| 7   | Jumper wires (M–M / M–F) | ~$5            | Laser, power, and I²C tie-ins to the ESP32 header pins.                 |
| 8   | USB-C cable              | ~$5            | ESP32 ↔ power bank (and ESP32 ↔ Mac for flashing/serial).               |

## Connections (ESP32 pinout)

| From            | To (ESP32) |
| --------------- | ---------- |
| Laser red (+)   | **GPIO26** |
| Laser black (−) | **GND**    |
| Mux SDA         | **GPIO21** |
| Mux SCL         | **GPIO22** |
| Mux VIN         | **3V3**    |
| Mux GND         | **GND**    |

Pin notes: avoid input-only **GPIO34–39** for outputs, and avoid strapping pins
(0, 2, 5, 12, 15).

## 3D Printing

- A filament 3D printer with at least 210x210x200mm in printable surface area
- PLA/PETG filament
- 3mm and 4mm heat thread inserts
