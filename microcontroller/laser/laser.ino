// Laser test — drives the laser on GPIO26.
//   Laser red (+)  -> GPIO26
//   Laser black (-) -> GND
// Blinks 2s on / 2s off to confirm GPIO26 is under program control.
// (In the final putt tracker the laser just stays on.)

const int LASER_PIN = 26;

void setup() {
  pinMode(LASER_PIN, OUTPUT);
  digitalWrite(LASER_PIN, LOW);   // start off
  Serial.begin(115200);
  Serial.println("Laser test starting on GPIO26");
}

void loop() {
  digitalWrite(LASER_PIN, HIGH);
  Serial.println("Laser ON");
  delay(2000);
  digitalWrite(LASER_PIN, LOW);
  Serial.println("Laser OFF");
  delay(2000);
}
