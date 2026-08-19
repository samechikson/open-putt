// Putt offline-detector for ESP32.
//   Laser  red (+) -> GPIO26, black (-) -> GND
//   Mux    SDA -> GPIO21, SCL -> GPIO22, VIN -> 3V3, GND -> GND
//   3x VL53L4CD on mux channels 0, 7, 4 (Sensor 1, 2, 3)
// Turns the laser on, calibrates the empty gate, then reports each putt's offset
// from center as PUSH (past center) / PULL (short of center) and sends it over
// BLE to the phone app, which relays it to the backend under the user's login.

#include <Wire.h>
#include <math.h>
#include <vl53l4cd_class.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ---------- Tuning constants (ported from putt_tracker.py) ----------
#define MUX_ADDR 0x70
const uint8_t CHANNELS[3] = {0, 7, 4};        // Sensor 1, 2, 3
const int     N = 3;

const int      LASER_PIN        = 26;
const int      LASER_FLASH_COUNT = 3;         // blinks that confirm a captured putt
const uint32_t LASER_FLASH_MS    = 120;       // on/off half-period of each blink
// Per-sensor raw reading (mm) with a ball rolled dead-center through the gate,
// measured with the centering jig. The offset is the deviation from this, so a
// center hit reads ~0 and each sensor's fixed bias — mounting differences and the
// middle sensor's crosstalk offset — is absorbed. Re-measure if the mount changes.
// Order matches CHANNELS {ch0, ch7, ch4} = Sensor 1, 2, 3.
const float    CENTER_READING[N] = {72.2, 77.2, 70.0};
const float    DETECT_MARGIN_MM = 25.0;       // drop below baseline = ball present
const float    DEAD_BAND_MM     = 2.0;        // |offset| within this -> CENTER
const uint32_t CLEAR_TIMEOUT_MS = 150;        // gate clear this long -> finalize
const int      CALIB_SAMPLES    = 20;         // empty-gate reads per sensor at startup
const bool     INVERT_PUSH_PULL = false;      // flip if labels come out backwards
const float    GAP_MM_FALLBACK  = 178.0;      // used only if a sensor won't calibrate
// Center-to-center distance between adjacent in-line sensors (along the roll
// direction). Speed = distance travelled / time between sensor crossings.
// MEASURE THIS on your mount — an inaccurate value scales every speed linearly.
// Assumes the three sensors are evenly spaced (Sensor 1 -> 2 -> 3).
const float    SENSOR_SPACING_MM = 33.32;

VL53L4CD sensor0(&Wire, -1);
VL53L4CD sensor1(&Wire, -1);
VL53L4CD sensor2(&Wire, -1);
VL53L4CD *sensors[3] = {&sensor0, &sensor1, &sensor2};

float baseline[N];
float threshold[N];

// detection state
bool     eventActive = false;
uint32_t lastSeen    = 0;
float    minReading[N];       // -1 = sensor hasn't seen the ball this event
uint32_t minReadingTime[N];   // millis() at each sensor's closest approach (for speed)
float    maxReading[N];       // farthest ball-present reading this event (diagnostic)
int      sampleCount[N];      // how many ball-present samples this sensor took (diagnostic)
const int MAX_SAMPLES = 128;  // cap on stored per-sensor samples per putt (diagnostic)
float    samples[N][MAX_SAMPLES];  // raw ball-present readings, in capture order
int      puttNum     = 0;

// One session per boot; every putt this power-cycle is grouped under it.
String   sessionId;

// ---------- BLE (putts are sent to the phone app, which relays them) ----------
// Custom 128-bit UUIDs; must match the iOS app (GateConnection).
#define SERVICE_UUID        "6b1a0001-8c2f-4d3a-9e5b-1f2c3d4e5f60"
#define CHARACTERISTIC_UUID "6b1a0002-8c2f-4d3a-9e5b-1f2c3d4e5f60"

BLECharacteristic *puttChar = nullptr;
bool centralConnected = false;   // a phone is connected (and can receive notifies)

// Track connect/disconnect so we only flash the laser when a phone is listening,
// and re-advertise after a disconnect so it can reconnect.
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *s) override {
    centralConnected = true;
    Serial.println("BLE: phone connected");
  }
  void onDisconnect(BLEServer *s) override {
    centralConnected = false;
    Serial.println("BLE: phone disconnected, re-advertising");
    BLEDevice::startAdvertising();
  }
};

void muxSelect(uint8_t ch) {
  Wire.beginTransmission(MUX_ADDR);
  Wire.write(1 << ch);
  Wire.endTransmission();
}

// --- Reading-quality gate (rejects sun / IR-flooded samples) ---------------
// The VL53L4CD ranges with a 940 nm IR laser, and sunlight is very bright at
// 940 nm. When the gate's far wall is lit by the sun it reflects that IR back
// into the sensors, which can still return range_status 0 but with a distance
// biased *short* — reading the empty wall as ~120 mm instead of ~175 mm. That
// trips the ball-present threshold and produces phantom putts (observed
// outdoors as a consistent +48..+60 mm PUSH). These gates drop such samples so
// they never look like a ball. Both fields are already in real units (the ULD
// converts them): sigma_mm is the sensor's own std-dev estimate of the distance
// in mm; a trustworthy target reads a few mm, sun blows it up. The signal:ambient
// test requires the target return to stand clearly above the ambient IR floor —
// it self-scales, so it stays lax indoors (near-zero ambient) and tightens in
// sun. Tune from the serial log with GATE_QUALITY_DEBUG set to 1.
#define GATE_QUALITY_DEBUG 0
const float SIGMA_MAX_MM       = 15.0;   // reject a reading noisier than this
const float MIN_SIGNAL_AMBIENT = 1.5;    // signal_rate must be >= this x ambient_rate

// Distance in mm for sensor i (channel must already be selected).
// Returns -1 if there's no fresh reading, the sensor flags it invalid, or it
// fails the sun/IR quality gate above.
float readSensorMM(int i) {
  uint8_t ready = 0;
  sensors[i]->VL53L4CD_CheckForDataReady(&ready);
  if (!ready) return -1;
  sensors[i]->VL53L4CD_ClearInterrupt();
  VL53L4CD_Result_t res;
  sensors[i]->VL53L4CD_GetResult(&res);
  if (res.range_status != 0) return -1;       // 0 = valid target
  // Quality gate: drop noisy / IR-flooded samples that pass range_status but
  // aren't trustworthy (see the note above).
  if (res.sigma_mm > SIGMA_MAX_MM ||
      (float)res.signal_rate_kcps < MIN_SIGNAL_AMBIENT * (float)res.ambient_rate_kcps) {
#if GATE_QUALITY_DEBUG
    Serial.print("  ch"); Serial.print(CHANNELS[i]);
    Serial.print(" reject: d=");    Serial.print(res.distance_mm);
    Serial.print(" sigma=");        Serial.print(res.sigma_mm);
    Serial.print(" signal=");       Serial.print(res.signal_rate_kcps);
    Serial.print(" ambient=");      Serial.println(res.ambient_rate_kcps);
#endif
    return -1;
  }
  return (float)res.distance_mm;
}

float medianOf(float *a, int n) {
  for (int i = 1; i < n; i++) {                // insertion sort
    float key = a[i];
    int j = i - 1;
    while (j >= 0 && a[j] > key) { a[j + 1] = a[j]; j--; }
    a[j + 1] = key;
  }
  return a[n / 2];
}

void calibrate() {
  Serial.println("Calibrating empty gate - keep the bridge clear...");
  for (int i = 0; i < N; i++) {
    float samples[CALIB_SAMPLES];
    int got = 0;
    uint32_t start = millis();
    while (got < CALIB_SAMPLES && millis() - start < 3000) {
      muxSelect(CHANNELS[i]);
      float d = readSensorMM(i);
      if (d > 0) samples[got++] = d;
    }
    if (got == 0) {
      baseline[i] = GAP_MM_FALLBACK;
      Serial.print("  ch"); Serial.print(CHANNELS[i]);
      Serial.print(": no reading, using "); Serial.println(GAP_MM_FALLBACK, 0);
    } else {
      baseline[i] = medianOf(samples, got);
      Serial.print("  ch"); Serial.print(CHANNELS[i]);
      Serial.print(": baseline "); Serial.print(baseline[i], 1); Serial.println(" mm");
    }
    threshold[i] = baseline[i] - DETECT_MARGIN_MM;
  }
}

void classify(float offset, const char **label, float *mag) {
  float o = INVERT_PUSH_PULL ? -offset : offset;
  if (o > DEAD_BAND_MM)       { *label = "PUSH";   *mag = o; }
  else if (o < -DEAD_BAND_MM) { *label = "PULL";   *mag = -o; }
  else                        { *label = "CENTER"; *mag = fabs(o); }
}

// Closest-approach distance for sensor i, ignoring the first and last samples.
// Those are the ball caught off-axis at the edge of the ~18° cone, so they read
// long; the true perpendicular distance is the lowest of the middle samples.
// Falls back to the overall min when there are too few samples to trim safely.
float closestMiddle(int i) {
  int n = sampleCount[i];
  if (n < 3 || n > MAX_SAMPLES) return minReading[i];
  float m = samples[i][1];
  for (int k = 2; k < n - 1; k++) if (samples[i][k] < m) m = samples[i][k];
  return m;
}

void report() {
  // Only count a putt when every sensor saw the ball. A real putt rolls over all
  // three in-line sensors in sequence; a partial detection (some sensor never
  // saw it) is almost always an errant read — e.g. sunlight tripping a single
  // sensor outdoors — so ignore it entirely: no putt number, no BLE notify, no
  // laser flash.
  int detected = 0;
  for (int i = 0; i < N; i++) if (minReading[i] >= 0) detected++;
  if (detected < N) {
    Serial.print("Ignoring partial detection (");
    Serial.print(detected); Serial.print("/"); Serial.print(N);
    Serial.println(" sensors) - not counted as a putt.");
    return;
  }

  puttNum++;
  Serial.print("\n--- Putt #"); Serial.print(puttNum); Serial.println(" ---");
  float sum = 0;
  float sumReading = 0;
  int count = 0;
  for (int i = 0; i < N; i++) {
    Serial.print("  Sensor "); Serial.print(i + 1);
    Serial.print(" (ch"); Serial.print(CHANNELS[i]); Serial.print("): ");
    if (minReading[i] < 0) {
      Serial.println("no detection");
      continue;
    }
    float closest = closestMiddle(i);   // lowest of the middle samples (drop first/last)
    float offset = closest - CENTER_READING[i];   // deviation from this sensor's center
    const char *label;
    float mag;
    classify(offset, &label, &mag);
    sum += offset;
    sumReading += closest;
    count++;
    // Full spread for diagnosis, then the value actually used (trimmed closest
    // approach) and the offset it maps to.
    Serial.print("min "); Serial.print(minReading[i], 1);
    Serial.print(" / max "); Serial.print(maxReading[i], 1);
    Serial.print(" mm ("); Serial.print(sampleCount[i]); Serial.print(" samples), used ");
    Serial.print(closest, 1); Serial.print(" mm  ->  ");
    Serial.print(offset >= 0 ? "+" : "-");
    Serial.print(mag, 1); Serial.print(" mm  "); Serial.println(label);

    // Full per-sample trace of the pass (capture order), for diagnosis.
    Serial.print("      samples: ");
    int shown = sampleCount[i] < MAX_SAMPLES ? sampleCount[i] : MAX_SAMPLES;
    for (int k = 0; k < shown; k++) {
      if (k) Serial.print(' ');
      Serial.print(samples[i][k], 0);
    }
    if (sampleCount[i] > MAX_SAMPLES) Serial.print(" ...(capped)");
    Serial.println();
  }
  if (count > 0) {
    float avg = sum / count;
    const char *label;
    float mag;
    classify(avg, &label, &mag);
    Serial.print("  Avg reading:    ");
    Serial.print(sumReading / count, 1); Serial.println(" mm");
    Serial.print("  Avg offset:     ");
    Serial.print(avg >= 0 ? "+" : "-");
    Serial.print(mag, 1); Serial.print(" mm  "); Serial.println(label);

    // Speed: the ball crosses the in-line sensors in sequence, so the separation
    // between the first and last sensor it tripped, over the time between those
    // crossings, is its speed. mm/ms == m/s, so no unit conversion is needed.
    // Needs the ball to trip >= 2 sensors; otherwise it's not measurable (null).
    float speed_mps = -1.0;
    int firstIdx = -1, lastIdx = -1;
    for (int i = 0; i < N; i++) {
      if (minReading[i] < 0) continue;
      if (firstIdx < 0) firstIdx = i;
      lastIdx = i;
    }
    if (firstIdx >= 0 && lastIdx > firstIdx) {
      uint32_t t0 = minReadingTime[firstIdx], t1 = minReadingTime[lastIdx];
      uint32_t dt = (t1 >= t0) ? (t1 - t0) : (t0 - t1);
      if (dt > 0) {
        speed_mps = (SENSOR_SPACING_MM * (lastIdx - firstIdx)) / (float)dt;
        Serial.print("  Speed:          ");
        Serial.print(speed_mps, 2); Serial.println(" m/s");
      }
    }

    // Build the putt payload and send it to the phone over BLE. Per-sensor
    // entries are the signed offset (or null where that sensor didn't see the
    // ball); speed_mps is null when the ball tripped fewer than two sensors.
    // The phone relays this JSON verbatim to POST /api/device/putts.
    String json = "{";
    json += "\"session_id\":\"" + sessionId + "\",";
    json += "\"putt_index\":" + String(puttNum) + ",";
    json += "\"offset_mm\":" + String(avg, 1) + ",";
    json += "\"label\":\"" + String(label) + "\",";
    json += "\"speed_mps\":" + (speed_mps >= 0 ? String(speed_mps, 2) : String("null")) + ",";
    json += "\"sensors\":[";
    for (int i = 0; i < N; i++) {
      if (i) json += ",";
      json += (minReading[i] < 0)
        ? "null"
        : String(closestMiddle(i) - CENTER_READING[i], 1);
    }
    json += "]}";
    if (notifyPutt(json)) flashLaser();   // confirm only when a phone received it
  }
}

void resetEvent() {
  eventActive = false;
  for (int i = 0; i < N; i++) {
    minReading[i] = -1;
    maxReading[i] = -1;
    sampleCount[i] = 0;
  }
}

// Blink the gate laser a few times to confirm a putt was received by the phone,
// then leave it on (it's the aiming reference for the next putt). Detection uses
// the ToF sensors, not the laser, so blinking it doesn't affect measurement.
void flashLaser() {
  for (int i = 0; i < LASER_FLASH_COUNT; i++) {
    digitalWrite(LASER_PIN, LOW);
    delay(LASER_FLASH_MS);
    digitalWrite(LASER_PIN, HIGH);
    delay(LASER_FLASH_MS);
  }
}

// A canonical UUID (8-4-4-4-12 hex) for this session. The backend stores it as
// sessions.id (a uuid column), so it must be UUID-shaped. Randomness comes from
// esp_random() (hardware RNG, seeded once the BLE radio is up).
String makeSessionId() {
  uint8_t b[16];
  for (int i = 0; i < 16; i += 4) {
    uint32_t r = esp_random();
    b[i] = r; b[i + 1] = r >> 8; b[i + 2] = r >> 16; b[i + 3] = r >> 24;
  }
  b[6] = (b[6] & 0x0F) | 0x40;   // version 4
  b[8] = (b[8] & 0x3F) | 0x80;   // variant 1
  char buf[37];
  snprintf(buf, sizeof(buf),
           "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
           b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
  return String(buf);
}

// Bring up the BLE peripheral: one service with a notify characteristic that
// carries each putt's JSON. Advertises as "PuttingGate" so the phone app can
// find and connect to it.
void startBLE() {
  BLEDevice::init("PuttingGate");
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(SERVICE_UUID);
  puttChar = service->createCharacteristic(
    CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  puttChar->addDescriptor(new BLE2902());   // lets the phone subscribe to notifies
  service->start();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  // The 128-bit service UUID (16 bytes) and the "PuttingGate" name together
  // overflow the 31-byte advertising packet, which would silently drop the UUID
  // and make iOS's UUID-filtered scan miss the gate. Put the UUID in the primary
  // advertisement and the name in the scan response so both fit.
  BLEAdvertisementData advData;
  advData.setFlags(0x06);   // LE General Discoverable + BR/EDR not supported
  advData.setCompleteServices(BLEUUID(SERVICE_UUID));
  BLEAdvertisementData scanResp;
  scanResp.setName("PuttingGate");
  adv->setAdvertisementData(advData);
  adv->setScanResponseData(scanResp);
  BLEDevice::startAdvertising();
  Serial.println("BLE: advertising as 'PuttingGate'");
}

// Send one putt's JSON to the connected phone as a BLE notification. Returns
// false (no-op) when no phone is connected — detection keeps running either way.
bool notifyPutt(const String &json) {
  if (!centralConnected || puttChar == nullptr) return false;
  puttChar->setValue((uint8_t *)json.c_str(), json.length());
  puttChar->notify();
  Serial.println("BLE: putt sent");
  return true;
}

void setup() {
  // Laser ON first, as always.
  pinMode(LASER_PIN, OUTPUT);
  digitalWrite(LASER_PIN, HIGH);

  Serial.begin(115200);
  delay(500);
  Serial.println("Laser ON.");

  Wire.begin(21, 22);            // SDA=GPIO21, SCL=GPIO22
  Wire.setClock(400000);

  Serial.println("Initializing sensors...");
  for (int i = 0; i < N; i++) {
    muxSelect(CHANNELS[i]);
    sensors[i]->begin();
    if (sensors[i]->InitSensor() != 0) {
      Serial.print("  ch"); Serial.print(CHANNELS[i]); Serial.println(": INIT FAILED");
      continue;
    }
    sensors[i]->VL53L4CD_SetRangeTiming(10, 0);   // 10 ms budget, continuous
    sensors[i]->VL53L4CD_StartRanging();
    Serial.print("  ch"); Serial.print(CHANNELS[i]); Serial.println(": OK");
  }

  startBLE();
  sessionId = makeSessionId();
  Serial.print("Session: "); Serial.println(sessionId);

  resetEvent();
  calibrate();
  Serial.println("\nReady - roll a putt through the gate.");
}

void loop() {
  uint32_t now = millis();
  for (int i = 0; i < N; i++) {
    muxSelect(CHANNELS[i]);
    float d = readSensorMM(i);
    if (d > 0 && d < threshold[i]) {              // ball in this beam
      eventActive = true;
      lastSeen = now;
      if (sampleCount[i] < MAX_SAMPLES) samples[i][sampleCount[i]] = d;  // keep the trace
      sampleCount[i]++;
      if (d > maxReading[i]) maxReading[i] = d;       // spread of ball-present samples
      if (minReading[i] < 0 || d < minReading[i]) {  // closest approach
        minReading[i] = d;
        minReadingTime[i] = now;                     // when the ball was nearest this sensor
      }
    }
  }
  if (eventActive && (now - lastSeen) > CLEAR_TIMEOUT_MS) {
    report();         // print + BLE notify; flashes the laser if a phone received it
    resetEvent();
  }
}
