// Putt offline-detector for ESP32.
//   Laser  red (+) -> GPIO26, black (-) -> GND
//   Mux    SDA -> GPIO21, SCL -> GPIO22, VIN -> 3V3, GND -> GND
//   3x VL53L4CD on mux channels 0, 7, 4 (Sensor 1, 2, 3)
// Turns the laser on, calibrates the empty gate, then reports each putt's
// offset from center as PUSH (past center) / PULL (short of center).

#include <Wire.h>
#include <math.h>
#include <vl53l4cd_class.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include "secrets.h"

// ---------- Tuning constants (ported from putt_tracker.py) ----------
#define MUX_ADDR 0x70
const uint8_t CHANNELS[3] = {0, 7, 4};        // Sensor 1, 2, 3
const int     N = 3;

const int      LASER_PIN        = 26;
const float    CENTER_MM        = 89.0;       // measured center distance (this mount)
const float    BALL_DIAMETER_MM = 42.67;      // standard golf ball
const float    BALL_RADIUS_MM   = BALL_DIAMETER_MM / 2.0;
const float    DETECT_MARGIN_MM = 25.0;       // drop below baseline = ball present
const float    DEAD_BAND_MM     = 2.0;        // |offset| within this -> CENTER
const uint32_t CLEAR_TIMEOUT_MS = 150;        // gate clear this long -> finalize
const int      CALIB_SAMPLES    = 20;         // empty-gate reads per sensor at startup
const bool     INVERT_PUSH_PULL = false;      // flip if labels come out backwards
const float    GAP_MM_FALLBACK  = 178.0;      // used only if a sensor won't calibrate

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
int      puttNum     = 0;

// One session per boot; every putt this power-cycle is grouped under it.
String   sessionId;

void muxSelect(uint8_t ch) {
  Wire.beginTransmission(MUX_ADDR);
  Wire.write(1 << ch);
  Wire.endTransmission();
}

// Distance in mm for sensor i (channel must already be selected).
// Returns -1 if no fresh, valid reading.
float readSensorMM(int i) {
  uint8_t ready = 0;
  sensors[i]->VL53L4CD_CheckForDataReady(&ready);
  if (!ready) return -1;
  sensors[i]->VL53L4CD_ClearInterrupt();
  VL53L4CD_Result_t res;
  sensors[i]->VL53L4CD_GetResult(&res);
  if (res.range_status != 0) return -1;       // 0 = valid target
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

void report() {
  puttNum++;
  Serial.print("\n--- Putt #"); Serial.print(puttNum); Serial.println(" ---");
  float sum = 0;
  int count = 0;
  for (int i = 0; i < N; i++) {
    Serial.print("  Sensor "); Serial.print(i + 1);
    Serial.print(" (ch"); Serial.print(CHANNELS[i]); Serial.print("): ");
    if (minReading[i] < 0) {
      Serial.println("no detection");
      continue;
    }
    float offset = (minReading[i] + BALL_RADIUS_MM) - CENTER_MM;
    const char *label;
    float mag;
    classify(offset, &label, &mag);
    sum += offset;
    count++;
    Serial.print(offset >= 0 ? "+" : "-");
    Serial.print(mag, 1); Serial.print(" mm  "); Serial.println(label);
  }
  if (count > 0) {
    float avg = sum / count;
    const char *label;
    float mag;
    classify(avg, &label, &mag);
    Serial.print("  Average:        ");
    Serial.print(avg >= 0 ? "+" : "-");
    Serial.print(mag, 1); Serial.print(" mm  "); Serial.println(label);

    // Build the putt payload and POST it. Per-sensor entries are the signed
    // offset (or null where that sensor didn't see the ball). Matches the
    // backend's POST /api/device/putts body.
    String json = "{";
    json += "\"session_id\":\"" + sessionId + "\",";
    json += "\"putt_index\":" + String(puttNum) + ",";
    json += "\"offset_mm\":" + String(avg, 1) + ",";
    json += "\"label\":\"" + String(label) + "\",";
    json += "\"sensors\":[";
    for (int i = 0; i < N; i++) {
      if (i) json += ",";
      json += (minReading[i] < 0)
        ? "null"
        : String((minReading[i] + BALL_RADIUS_MM) - CENTER_MM, 1);
    }
    json += "]}";
    postPutt(json);
  }
}

void resetEvent() {
  eventActive = false;
  for (int i = 0; i < N; i++) minReading[i] = -1;
}

// A canonical UUID (8-4-4-4-12 hex) for this session. The backend stores it as
// sessions.id (a uuid column), so it must be UUID-shaped. Randomness comes from
// esp_random() (hardware RNG, seeded once WiFi/RF is up).
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

void connectWiFi() {
  Serial.print("WiFi: connecting to "); Serial.println(WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) {
    delay(250); Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("\nWiFi: connected, IP "); Serial.println(WiFi.localIP());
  } else {
    Serial.println("\nWiFi: FAILED (keeping detection running offline).");
  }
}

// POST one putt as JSON. Returns the HTTP status, or -1 on transport failure.
// Never blocks detection: a failure just logs and the next putt still runs.
int postPutt(const String &json) {
  if (WiFi.status() != WL_CONNECTED) return -1;
  WiFiClientSecure client;
  client.setInsecure();                 // skip cert validation — fine for a hobby device
  HTTPClient http;
  if (!http.begin(client, POST_URL)) return -1;
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-Device-Token", DEVICE_TOKEN);   // ignored by webhook.site
  int code = http.POST(json);
  Serial.print("POST -> "); Serial.println(code);
  http.end();
  return code;
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

  connectWiFi();
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
      if (minReading[i] < 0 || d < minReading[i]) minReading[i] = d;  // closest approach
    }
  }
  if (eventActive && (now - lastSeen) > CLEAR_TIMEOUT_MS) {
    report();
    resetEvent();
  }
}
