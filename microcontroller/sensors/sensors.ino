// Read 3x VL53L4CD through a PCA9548 (TCA9548A-compatible) I2C mux.
//   Mux SDA -> GPIO21, SCL -> GPIO22, VIN -> 3V3, GND -> GND
//   Sensors on mux channels 0, 7, 4 (Sensor 1, 2, 3).
// All three sensors share address 0x29, so the mux isolates them by channel.

#include <Wire.h>
#include <vl53l4cd_class.h>

#define MUX_ADDR 0x70
const uint8_t CHANNELS[3] = {0, 7, 4};

// XSHUT is not wired (STEMMA QT doesn't break it out) -> pass -1.
VL53L4CD sensor0(&Wire, -1);
VL53L4CD sensor1(&Wire, -1);
VL53L4CD sensor2(&Wire, -1);
VL53L4CD *sensors[3] = {&sensor0, &sensor1, &sensor2};

void muxSelect(uint8_t ch) {
  Wire.beginTransmission(MUX_ADDR);
  Wire.write(1 << ch);
  Wire.endTransmission();
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Wire.begin(21, 22);          // SDA=GPIO21, SCL=GPIO22
  Wire.setClock(400000);       // VL53L4CD supports 400 kHz I2C

  Serial.println("Initializing sensors...");
  for (int i = 0; i < 3; i++) {
    muxSelect(CHANNELS[i]);
    sensors[i]->begin();
    int status = sensors[i]->InitSensor();   // verifies sensor ID + inits
    if (status != 0) {
      Serial.print("  ch"); Serial.print(CHANNELS[i]);
      Serial.println(": INIT FAILED - check that this channel is wired to a sensor");
      continue;
    }
    sensors[i]->VL53L4CD_SetRangeTiming(10, 0);   // 10 ms budget, 0 = continuous
    sensors[i]->VL53L4CD_StartRanging();
    Serial.print("  ch"); Serial.print(CHANNELS[i]); Serial.println(": OK");
  }
  Serial.println("Reading distances:");
}

void loop() {
  for (int i = 0; i < 3; i++) {
    muxSelect(CHANNELS[i]);
    uint8_t ready = 0;
    sensors[i]->VL53L4CD_CheckForDataReady(&ready);
    Serial.print("ch"); Serial.print(CHANNELS[i]); Serial.print(": ");
    if (ready) {
      sensors[i]->VL53L4CD_ClearInterrupt();
      VL53L4CD_Result_t res;
      sensors[i]->VL53L4CD_GetResult(&res);
      if (res.range_status == 0) {
        Serial.print(res.distance_mm); Serial.print(" mm");
      } else {
        Serial.print("(no target)");
      }
    } else {
      Serial.print("...");
    }
    Serial.print("    ");
  }
  Serial.println();
  delay(200);
}
