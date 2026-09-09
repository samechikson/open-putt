# Assembly & Getting Started

How to build an Open Putt from scratch and roll your first measured putt. It ties
together the parts list, the printable enclosure, the firmware, and the apps — each
of which has its own deeper doc, linked as you go.

**Roughly what's involved:** gather the parts → print the enclosure → mount and wire
the electronics → flash the ESP32 → set up Firebase and the app → calibrate → putt.
Plan on an afternoon, plus print time.

---

## 1. Gather the parts

See [`PARTS_LIST.md`](PARTS_LIST.md) for the full bill of materials with links and
approximate prices (~$122 in electronics). In short you need: an **ESP32 DevKit**,
**3× Adafruit VL53L4CD** ToF sensors, an **Adafruit PCA9548** I²C mux, a **green
laser module**, a USB-C power bank, STEMMA QT / Qwiic cables, jumper wires, and
**M3 + M4 heat-set inserts**.

## 2. Print the enclosure

The models live in Onshape; see [`cad/README.md`](cad/README.md) for the link and
print settings. You'll need a printer with at least a **210 × 210 × 200 mm** build
volume, **PLA or PETG**, and the M3/M4 heat-set inserts above.

Export each part from Onshape, slice, and print. After printing, **heat-set the
threaded inserts** into their bosses while the plastic is warm.

## 3. Mount the electronics

Fit the boards and laser into their printed mounts:

- The **3 ToF sensors** sit in a row along the roll direction, facing across the
  gate. Their alignment is load-bearing for the measurement, so seat them fully and
  squarely in the printed mount.
- The **PCA9548 mux** and **ESP32** go in the electronics mount/tray.
- The **laser** goes in its holder, aimed down the gate's center line.

## 4. Wire it up

Chain the sensors to the mux with STEMMA QT / Qwiic cables (each sensor on its own
channel — **0, 7, 4** for Sensor 1, 2, 3, since all three share I²C address `0x29`),
then wire the mux and laser to the ESP32:

| From                 | Signal      | ESP32 pin  |
| -------------------- | ----------- | ---------- |
| Mux — Red            | VIN (3.3 V) | **3V3**    |
| Mux — Black          | GND         | **GND**    |
| Mux — Blue           | SDA         | **GPIO21** |
| Mux — Yellow         | SCL         | **GPIO22** |
| Laser red (+)        | —           | **GPIO26** |
| Laser black (−)      | —           | **GND**    |

Full wiring, pin rules, and the measurement geometry are in
[`microcontroller/README.md`](microcontroller/README.md).

## 5. Flash the firmware

Install [`arduino-cli`](https://arduino.github.io/arduino-cli/) with the ESP32 core
and the **STM32duino VL53L4CD** library, then flash the main program from
`microcontroller/putt_tracker/`. The **`huge_app` partition scheme is required** —
BLE overflows the default partition:

```bash
cd microcontroller/putt_tracker
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app --upload -p /dev/cu.usbserial-0001 .
arduino-cli monitor -p /dev/cu.usbserial-0001 -c baudrate=115200
```

(Adjust the serial port for your machine.) On boot the laser should light and the
serial monitor should show the sensors calibrating their empty-gate baseline. The
`sensors/`, `laser/`, and `blink/` sketches are there for bring-up if a step
misbehaves. See [`microcontroller/README.md`](microcontroller/README.md) for the
toolchain versions and gotchas.

## 6. Calibrate center

The gate zeroes each sensor against a ball rolled dead-center (per-sensor
`CENTER_READING`, measured with a centering jig) — this absorbs each sensor's fixed
mounting/optical bias. Set these constants at the top of
`microcontroller/putt_tracker/putt_tracker.ino` and re-flash, or use the app's
in-gate calibration. Re-measure if you ever change the mounting.

## 7. Set up the app and Firebase

Putts are stored in **your own** Firebase project — there's no shared backend. Follow
[`SETUP.md`](SETUP.md) to create the Firebase project (Auth + Firestore + rules),
then build and run the **iOS app** on a real device (BLE doesn't work in the
Simulator). Optionally run the **web app** to browse your history in a browser.

## 8. Roll your first putt

1. Power the gate from the USB-C bank; it advertises over BLE as **`PuttingGate`**.
2. Open the iOS app, sign in, and let it connect to the gate on the **Gate** tab.
3. Roll a putt through the gate. The ESP32 measures the offset on-device and sends
   it over BLE; the app records it to Firestore and the laser flashes to confirm.
4. Check the **History** tab (or the web app) to see the putt, its push/pull offset
   in mm, and speed.

That's a working gate. From here, build up sessions per putter, distance, and break
to see your tendencies over time.

---

For how the whole system fits together, see [`README.md`](README.md); for running
the software on your own infrastructure, [`SETUP.md`](SETUP.md).
