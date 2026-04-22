// pedestal.ino — THE TUB pedestal controller (Waveshare RP2040-Zero)
//
// Each pedestal runs this firmware with a unique PEDESTAL_ADDR (1, 2, or 3).
// Communicates with central Teensy over RS-485 as a slave.
//
// RS-485 protocol:
//   Master poll:    P<addr>?\n
//   Slave response: P<addr>,B<0|1>,T<tof_mm>,H<pwm>\n
//   Master command: P<addr>,H<pwm>,N<r>.<g>.<b>.<w>\n
//
// Hardware per pedestal:
//   - MAX485 transceiver on Serial1
//   - VL6180X ToF sensor on I2C
//   - N-channel MOSFET for 24V halo LED (PWM)
//   - RGBW NeoPixel strip
//   - One button/switch input (NO contact, pull-up, active LOW)

#include <Wire.h>
#include <Adafruit_NeoPixel.h>

// ============================================================
// CONFIGURATION — CHANGE THIS PER PEDESTAL
// ============================================================

static const int PEDESTAL_ADDR = 1;  // Set to 1, 2, or 3

// ============================================================
// PIN ASSIGNMENTS (RP2040-Zero)
// ============================================================

static const uint8_t PIN_RS485_DE  = 2;   // GP2 → MAX485 E (DE+RE combined)
// Serial1 TX = GP0, Serial1 RX = GP1 (RP2040 UART0)

static const uint8_t PIN_HALO_PWM  = 6;   // GP6 → MOSFET gate (unused on pedestals without halo)
#ifdef PIN_NEOPIXEL
#undef PIN_NEOPIXEL   // Waveshare variant pre-defines this for onboard LED (GP16); we use our own pin
#endif
static const uint8_t PIN_NEO_RING  = 3;   // GP3 → NeoPixel ring data (via 330Ω at ring)
static const uint8_t PIN_BUTTON    = 7;   // GP7 → local button input (unused on pedestals without button)

// I2C uses default pins: SDA=GP4, SCL=GP5 (Wire / I2C0)

// ============================================================
// NEOPIXEL CONFIG
// ============================================================

static const int NEOPIXEL_COUNT = 16;  // 16-LED RGBW ring (w28666-c)
Adafruit_NeoPixel pixels(NEOPIXEL_COUNT, PIN_NEO_RING, NEO_GRBW + NEO_KHZ800);

// ============================================================
// VL6180X REGISTERS (direct I2C, no library dependency)
// ============================================================

static const uint8_t VL6180X_ADDR = 0x29;

static bool vl6180xReady = false;

void vl6180xWrite8(uint16_t reg, uint8_t val) {
  Wire.beginTransmission(VL6180X_ADDR);
  Wire.write((reg >> 8) & 0xFF);
  Wire.write(reg & 0xFF);
  Wire.write(val);
  Wire.endTransmission();
}

uint8_t vl6180xRead8(uint16_t reg) {
  Wire.beginTransmission(VL6180X_ADDR);
  Wire.write((reg >> 8) & 0xFF);
  Wire.write(reg & 0xFF);
  Wire.endTransmission();
  Wire.requestFrom(VL6180X_ADDR, (uint8_t)1);
  return Wire.read();
}

bool vl6180xInit() {
  // Check model ID
  uint8_t id = vl6180xRead8(0x0000);
  if (id != 0xB4) return false;

  // Fresh-out-of-reset check
  if (vl6180xRead8(0x0016) & 0x01) {
    // Standard init sequence (from ST application note AN4545)
    vl6180xWrite8(0x0207, 0x01);
    vl6180xWrite8(0x0208, 0x01);
    vl6180xWrite8(0x0096, 0x00);
    vl6180xWrite8(0x0097, 0xFD);
    vl6180xWrite8(0x00E3, 0x00);
    vl6180xWrite8(0x00E4, 0x04);
    vl6180xWrite8(0x00E5, 0x02);
    vl6180xWrite8(0x00E6, 0x01);
    vl6180xWrite8(0x00E7, 0x03);
    vl6180xWrite8(0x00F5, 0x02);
    vl6180xWrite8(0x00D9, 0x05);
    vl6180xWrite8(0x00DB, 0xCE);
    vl6180xWrite8(0x00DC, 0x03);
    vl6180xWrite8(0x00DD, 0xF8);
    vl6180xWrite8(0x009F, 0x00);
    vl6180xWrite8(0x00A3, 0x3C);
    vl6180xWrite8(0x00B7, 0x00);
    vl6180xWrite8(0x00BB, 0x3C);
    vl6180xWrite8(0x00B2, 0x09);
    vl6180xWrite8(0x00CA, 0x09);
    vl6180xWrite8(0x0198, 0x01);
    vl6180xWrite8(0x01B0, 0x17);
    vl6180xWrite8(0x01AD, 0x00);
    vl6180xWrite8(0x00FF, 0x05);
    vl6180xWrite8(0x0100, 0x05);
    vl6180xWrite8(0x0199, 0x05);
    vl6180xWrite8(0x01A6, 0x1B);
    vl6180xWrite8(0x01AC, 0x3E);
    vl6180xWrite8(0x01A7, 0x1F);
    vl6180xWrite8(0x0030, 0x00);

    // Clear fresh-out-of-reset bit
    vl6180xWrite8(0x0016, 0x00);
  }

  // Continuous ranging mode, 100ms interval
  vl6180xWrite8(0x001B, 0x09);  // range intermeasurement period (~100ms)
  vl6180xWrite8(0x0014, 0x24);  // interrupt on new range ready
  vl6180xWrite8(0x0018, 0x03);  // start continuous ranging

  return true;
}

int vl6180xReadRange() {
  // Check if new data ready
  uint8_t status = vl6180xRead8(0x004F);
  if (!(status & 0x04)) return -1;  // no new data

  uint8_t range = vl6180xRead8(0x0062);

  // Clear interrupt
  vl6180xWrite8(0x0015, 0x07);

  return (int)range;
}

// ============================================================
// DEBOUNCE
// ============================================================

static const unsigned long DEBOUNCE_MS = 15;

struct DebouncedInput {
  bool state;
  bool rawLast;
  unsigned long lastChangeMs;
};
static DebouncedInput button = { false, false, 0 };

void debounceButton() {
  unsigned long now = millis();
  bool raw = (digitalRead(PIN_BUTTON) == LOW);
  if (raw != button.rawLast) {
    button.lastChangeMs = now;
    button.rawLast = raw;
  }
  if ((now - button.lastChangeMs) >= DEBOUNCE_MS) {
    button.state = button.rawLast;
  }
}

// ============================================================
// STATE
// ============================================================

static int  currentTofMm = 0;
static int  currentHaloPwm = 0;
static uint8_t neoR = 0, neoG = 0, neoB = 0, neoW = 0;
static bool neoPixelDirty = true;  // force initial update

// RS-485 receive buffer
static char rxBuf[64];
static int rxBufLen = 0;

// Install-verification debug output over USB Serial
static unsigned long lastDebugMs = 0;
static const unsigned long DEBUG_INTERVAL_MS = 1000;

// ============================================================
// RS-485 TRANSCEIVER CONTROL
// ============================================================

void rs485SetTX() {
  digitalWrite(PIN_RS485_DE, HIGH);
  delayMicroseconds(10);
}

void rs485SetRX() {
  Serial1.flush();
  delayMicroseconds(10);
  digitalWrite(PIN_RS485_DE, LOW);
}

// ============================================================
// RS-485 PROTOCOL: RESPOND TO POLL
// ============================================================

void sendResponse() {
  rs485SetTX();
  Serial1.print('P');
  Serial1.print(PEDESTAL_ADDR);
  Serial1.print(",B");
  Serial1.print(button.state ? '1' : '0');
  Serial1.print(",T");
  Serial1.print(currentTofMm);
  Serial1.print(",H");
  Serial1.println(currentHaloPwm);
  rs485SetRX();
}

// ============================================================
// RS-485 PROTOCOL: PROCESS INCOMING
// ============================================================

void processRS485Line(const char* line) {
  if (line[0] != 'P') return;

  // Check if addressed to us
  int addr = 0;
  int pos = 1;
  while (line[pos] >= '0' && line[pos] <= '9') {
    addr = addr * 10 + (line[pos] - '0');
    pos++;
  }
  if (addr != PEDESTAL_ADDR) return;

  // Poll: "P<addr>?"
  if (line[pos] == '?') {
    sendResponse();
    return;
  }

  // Command: "P<addr>,H<pwm>,N<r>.<g>.<b>.<w>"
  if (line[pos] == ',') {
    pos++;
    while (line[pos]) {
      if (line[pos] == 'H') {
        pos++;
        int pwm = 0;
        while (line[pos] >= '0' && line[pos] <= '9') {
          pwm = pwm * 10 + (line[pos] - '0');
          pos++;
        }
        currentHaloPwm = constrain(pwm, 0, 255);
        analogWrite(PIN_HALO_PWM, currentHaloPwm);
      } else if (line[pos] == 'N') {
        pos++;
        int vals[4] = {0, 0, 0, 0};
        for (int v = 0; v < 4; v++) {
          while (line[pos] >= '0' && line[pos] <= '9') {
            vals[v] = vals[v] * 10 + (line[pos] - '0');
            pos++;
          }
          if (line[pos] == '.') pos++;  // skip separator
        }
        neoR = constrain(vals[0], 0, 255);
        neoG = constrain(vals[1], 0, 255);
        neoB = constrain(vals[2], 0, 255);
        neoW = constrain(vals[3], 0, 255);
        neoPixelDirty = true;
      }

      // Skip to next field
      while (line[pos] && line[pos] != ',') pos++;
      if (line[pos] == ',') pos++;
    }
  }
}

// ============================================================
// SETUP
// ============================================================

void setup() {
  // USB Serial for install-verification output
  Serial.begin(115200);

  // RS-485 UART
  Serial1.begin(115200);
  pinMode(PIN_RS485_DE, OUTPUT);
  digitalWrite(PIN_RS485_DE, LOW);  // start in receive mode

  // Button input
  pinMode(PIN_BUTTON, INPUT_PULLUP);
  bool raw = (digitalRead(PIN_BUTTON) == LOW);
  button.state = raw;
  button.rawLast = raw;
  button.lastChangeMs = millis();

  // Halo MOSFET PWM output
  pinMode(PIN_HALO_PWM, OUTPUT);
  analogWrite(PIN_HALO_PWM, 0);

  // NeoPixels + visible boot test: R, G, B, W each for 1s at bright level
  pixels.begin();
  pixels.setBrightness(24);  // ~10% — keeps ring under ~150mA to avoid USB brownout
  uint32_t testSeq[4] = {
    pixels.Color(255, 0, 0, 0),  // red
    pixels.Color(0, 255, 0, 0),  // green
    pixels.Color(0, 0, 255, 0),  // blue
    pixels.Color(0, 0, 0, 255),  // white (dedicated W channel)
  };
  for (int c = 0; c < 4; c++) {
    for (int i = 0; i < NEOPIXEL_COUNT; i++) pixels.setPixelColor(i, testSeq[c]);
    pixels.show();
    delay(1000);
  }
  pixels.clear();
  pixels.show();
  // Keep low brightness for main-loop test (USB-powered). Raise to 255 once running off buck 5V.
  pixels.setBrightness(24);

  // I2C + VL6180X
  Wire.begin();
  delay(100);

  // I2C bus scan for install-verification
  delay(2000);  // let USB CDC enumerate before printing banner
  Serial.print("PED");
  Serial.print(PEDESTAL_ADDR);
  Serial.print(" I2C scan:");
  int found = 0;
  for (uint8_t addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      Serial.print(" 0x");
      if (addr < 0x10) Serial.print('0');
      Serial.print(addr, HEX);
      found++;
    }
  }
  Serial.print(" (");
  Serial.print(found);
  Serial.println(" device(s))");

  vl6180xReady = vl6180xInit();

  Serial.print("PED");
  Serial.print(PEDESTAL_ADDR);
  Serial.print(" boot OK, tof=");
  Serial.println(vl6180xReady ? "ready" : "MISSING");
}

// ============================================================
// MAIN LOOP
// ============================================================

void loop() {
  // --- Read button ---
  debounceButton();

  // --- Read ToF sensor ---
  if (vl6180xReady) {
    int range = vl6180xReadRange();
    if (range >= 0) {
      currentTofMm = range;
    }
  }

  // --- LOCAL NEOPIXEL TEST PATTERN (overrides RS-485 until removed) ---
  // Cycles R→G→B→W at 1s per color on all 16 LEDs.
  {
    static unsigned long lastColorMs = 0;
    static uint8_t colorIdx = 0;
    unsigned long nowMs = millis();
    if (nowMs - lastColorMs >= 1000) {
      lastColorMs = nowMs;
      colorIdx = (colorIdx + 1) & 0x03;
      uint32_t c;
      switch (colorIdx) {
        case 0: c = pixels.Color(255, 0, 0, 0); break;  // red
        case 1: c = pixels.Color(0, 255, 0, 0); break;  // green
        case 2: c = pixels.Color(0, 0, 255, 0); break;  // blue
        default: c = pixels.Color(0, 0, 0, 255); break; // white
      }
      for (int i = 0; i < NEOPIXEL_COUNT; i++) pixels.setPixelColor(i, c);
      pixels.show();
    }
  }

  // --- Update NeoPixels if changed (RS-485 path, disabled by local test above) ---
  if (false && neoPixelDirty) {
    for (int i = 0; i < NEOPIXEL_COUNT; i++) {
      pixels.setPixelColor(i, pixels.Color(neoR, neoG, neoB, neoW));
    }
    pixels.show();
    neoPixelDirty = false;
  }

  // --- Process RS-485 bus ---
  while (Serial1.available()) {
    char c = Serial1.read();
    if (c == '\n') {
      rxBuf[rxBufLen] = '\0';
      if (rxBufLen > 0) {
        processRS485Line(rxBuf);
      }
      rxBufLen = 0;
    } else if (c != '\r' && rxBufLen < (int)sizeof(rxBuf) - 1) {
      rxBuf[rxBufLen++] = c;
    }
  }

  // --- 1Hz install-verification status over USB Serial ---
  unsigned long now = millis();
  if (now - lastDebugMs >= DEBUG_INTERVAL_MS) {
    lastDebugMs = now;
    // I2C live scan each tick
    int i2cFound = 0;
    bool sawTof = false;
    for (uint8_t addr = 1; addr < 127; addr++) {
      Wire.beginTransmission(addr);
      if (Wire.endTransmission() == 0) {
        i2cFound++;
        if (addr == VL6180X_ADDR) sawTof = true;
      }
    }

    Serial.print("PED");
    Serial.print(PEDESTAL_ADDR);
    Serial.print(" i2c=");
    Serial.print(i2cFound);
    Serial.print(" tofAck=");
    Serial.print(sawTof ? 1 : 0);
    Serial.print(" tofReady=");
    Serial.print(vl6180xReady ? 1 : 0);
    Serial.print(" tof=");
    Serial.print(currentTofMm);
    Serial.print(" button=");
    Serial.print(button.state ? 1 : 0);
    Serial.print(" halo=");
    Serial.print(currentHaloPwm);
    Serial.print(" neo=");
    Serial.print(neoR); Serial.print('.');
    Serial.print(neoG); Serial.print('.');
    Serial.print(neoB); Serial.print('.');
    Serial.println(neoW);
  }
}
