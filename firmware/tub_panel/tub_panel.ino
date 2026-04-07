// tub_panel.ino — THE TUB central controller
// Reads 5 panel inputs (3-pos switch, 2 latched buttons, 1 momentary),
// sends mode + jolt state over USB serial to Mac app,
// and acts as RS-485 master polling up to 3 pedestals.
//
// USB protocol (to Mac):
//   M<mode>,J<0|1>\n                          panel state
//   P<addr>,B<0|1>,T<tof_mm>,H<pwm>\n        pedestal telemetry
//
// RS-485 protocol (to pedestals):
//   Master poll:    P<addr>?\n
//   Slave response: P<addr>,B<0|1>,T<tof_mm>,H<pwm>\n
//   Master command: P<addr>,H<pwm>,N<r>.<g>.<b>.<w>\n
//
// Baud: USB=115200, RS-485=115200

// ============================================================
// PIN ASSIGNMENTS
// ============================================================

// Panel inputs
static const uint8_t PIN_SW_LEFT  = 2;   // 3-position switch, LEFT contact
static const uint8_t PIN_SW_RIGHT = 3;   // 3-position switch, RIGHT contact
static const uint8_t PIN_LATCH1   = 4;   // Latched pushbutton 1
static const uint8_t PIN_LATCH2   = 5;   // Latched pushbutton 2
static const uint8_t PIN_JOLT     = 6;   // Momentary pushbutton (JOLT)

// RS-485 transceiver (MAX485)
static const uint8_t PIN_RS485_DE = 7;   // DE + RE tied together (HIGH=TX, LOW=RX)
// Serial1 TX = pin 1, Serial1 RX = pin 0 (Teensy 4.0 hardware UART)

// PATLITE MOSFET gates (accent: future use)
// static const uint8_t PIN_PATLITE_1 = 8;
// static const uint8_t PIN_PATLITE_2 = 9;
// static const uint8_t PIN_PATLITE_3 = 10;

// ============================================================
// DEBOUNCE
// ============================================================

static const unsigned long DEBOUNCE_MS = 15;

struct DebouncedInput {
  uint8_t pin;
  bool state;           // debounced state (true = pressed/engaged)
  bool rawLast;
  unsigned long lastChangeMs;
};

static DebouncedInput inputs[] = {
  { PIN_SW_LEFT,  false, false, 0 },
  { PIN_SW_RIGHT, false, false, 0 },
  { PIN_LATCH1,   false, false, 0 },
  { PIN_LATCH2,   false, false, 0 },
  { PIN_JOLT,     false, false, 0 },
};
static const int NUM_INPUTS = sizeof(inputs) / sizeof(inputs[0]);

enum { I_SW_LEFT = 0, I_SW_RIGHT, I_LATCH1, I_LATCH2, I_JOLT };

// ============================================================
// PANEL STATE
// ============================================================

static int  prevMode = -1;
static bool prevJolt = false;
static const unsigned long HEARTBEAT_MS = 200;
static unsigned long lastSendMs = 0;

// ============================================================
// RS-485 BUS
// ============================================================

static const int NUM_PEDESTALS = 3;
static const unsigned long RS485_POLL_INTERVAL_MS = 100;  // poll cycle every 100ms
static const unsigned long RS485_RESPONSE_TIMEOUT_MS = 50; // wait up to 50ms for reply
static unsigned long lastPollMs = 0;
static int currentPollAddr = 1;  // cycles 1, 2, 3

// Per-pedestal state cache (forwarded to USB)
struct PedestalState {
  bool online;
  bool button;
  int tofMm;
  int haloPwm;
  unsigned long lastSeenMs;
};
static PedestalState pedestals[NUM_PEDESTALS];  // index 0=addr1, 1=addr2, 2=addr3

// RS-485 receive buffer
static char rs485Buf[64];
static int rs485BufLen = 0;

// Pending commands from Mac (one per pedestal, overwritten)
struct PedestalCommand {
  bool pending;
  int haloPwm;
  uint8_t neoR, neoG, neoB, neoW;
};
static PedestalCommand pendingCmd[NUM_PEDESTALS];

// ============================================================
// USB RECEIVE BUFFER (commands from Mac)
// ============================================================

static char usbBuf[64];
static int usbBufLen = 0;

// ============================================================
// SETUP
// ============================================================

void setup() {
  // USB serial to Mac
  Serial.begin(115200);

  // RS-485 UART
  Serial1.begin(115200);
  pinMode(PIN_RS485_DE, OUTPUT);
  digitalWrite(PIN_RS485_DE, LOW);  // start in receive mode

  // Panel inputs
  for (int i = 0; i < NUM_INPUTS; i++) {
    pinMode(inputs[i].pin, INPUT_PULLUP);
    bool raw = (digitalRead(inputs[i].pin) == LOW);
    inputs[i].state = raw;
    inputs[i].rawLast = raw;
    inputs[i].lastChangeMs = millis();
  }

  // Init pedestal state
  for (int i = 0; i < NUM_PEDESTALS; i++) {
    pedestals[i].online = false;
    pedestals[i].button = false;
    pedestals[i].tofMm = 0;
    pedestals[i].haloPwm = 0;
    pedestals[i].lastSeenMs = 0;
    pendingCmd[i].pending = false;
  }

  prevMode = -1;
  prevJolt = false;
}

// ============================================================
// DEBOUNCE
// ============================================================

void debounceAll() {
  unsigned long now = millis();
  for (int i = 0; i < NUM_INPUTS; i++) {
    bool raw = (digitalRead(inputs[i].pin) == LOW);
    if (raw != inputs[i].rawLast) {
      inputs[i].lastChangeMs = now;
      inputs[i].rawLast = raw;
    }
    if ((now - inputs[i].lastChangeMs) >= DEBOUNCE_MS) {
      inputs[i].state = inputs[i].rawLast;
    }
  }
}

// ============================================================
// MODE COMPUTATION
// ============================================================

int computeMode() {
  bool swLeft  = inputs[I_SW_LEFT].state;
  bool swRight = inputs[I_SW_RIGHT].state;
  bool latch1  = inputs[I_LATCH1].state;
  bool latch2  = inputs[I_LATCH2].state;

  int base;
  if (swLeft && !swRight) {
    base = 0;
  } else if (swRight && !swLeft) {
    if (!latch1 && !latch2) return 8;
    if (latch1 && latch2)   return 10;
    return 9;
  } else {
    base = 4;
  }

  int latchBits = (latch1 ? 1 : 0) | (latch2 ? 2 : 0);
  return base + latchBits;
}

// ============================================================
// USB PANEL OUTPUT (to Mac)
// ============================================================

void sendPanelState(int mode, bool jolt) {
  Serial.print('M');
  Serial.print(mode);
  Serial.print(",J");
  Serial.println(jolt ? '1' : '0');
}

void forwardPedestalToUSB(int addr, const PedestalState& ps) {
  Serial.print('P');
  Serial.print(addr);
  Serial.print(",B");
  Serial.print(ps.button ? '1' : '0');
  Serial.print(",T");
  Serial.print(ps.tofMm);
  Serial.print(",H");
  Serial.println(ps.haloPwm);
}

// ============================================================
// RS-485 TRANSCEIVER CONTROL
// ============================================================

void rs485SetTX() {
  digitalWrite(PIN_RS485_DE, HIGH);
  delayMicroseconds(10);  // let DE settle
}

void rs485SetRX() {
  delayMicroseconds(10);  // let last byte finish
  // Flush any remaining TX bytes
  Serial1.flush();
  digitalWrite(PIN_RS485_DE, LOW);
}

// ============================================================
// RS-485 MASTER: POLL ONE PEDESTAL
// ============================================================

void rs485PollPedestal(int addr) {
  // Send poll: "P<addr>?\n"
  rs485SetTX();
  Serial1.print('P');
  Serial1.print(addr);
  Serial1.println('?');
  rs485SetRX();

  // Wait for response
  unsigned long start = millis();
  rs485BufLen = 0;

  while ((millis() - start) < RS485_RESPONSE_TIMEOUT_MS) {
    while (Serial1.available()) {
      char c = Serial1.read();
      if (c == '\n') {
        rs485Buf[rs485BufLen] = '\0';
        if (parseRS485Response(addr, rs485Buf)) {
          return;  // got valid response
        }
        rs485BufLen = 0;
      } else if (c != '\r' && rs485BufLen < (int)sizeof(rs485Buf) - 1) {
        rs485Buf[rs485BufLen++] = c;
      }
    }
  }

  // Timeout — mark pedestal offline if it's been too long
  int idx = addr - 1;
  if (idx >= 0 && idx < NUM_PEDESTALS) {
    if (pedestals[idx].online && (millis() - pedestals[idx].lastSeenMs) > 2000) {
      pedestals[idx].online = false;
    }
  }
}

// Parse "P<addr>,B<0|1>,T<tof_mm>,H<pwm>"
bool parseRS485Response(int expectedAddr, const char* line) {
  if (line[0] != 'P') return false;

  int addr = 0, btn = 0, tof = 0, halo = 0;
  int matched = sscanf(line, "P%d,B%d,T%d,H%d", &addr, &btn, &tof, &halo);
  if (matched < 4 || addr != expectedAddr) return false;
  if (addr < 1 || addr > NUM_PEDESTALS) return false;

  int idx = addr - 1;
  pedestals[idx].online = true;
  pedestals[idx].button = (btn != 0);
  pedestals[idx].tofMm = tof;
  pedestals[idx].haloPwm = halo;
  pedestals[idx].lastSeenMs = millis();

  // Forward to Mac over USB
  forwardPedestalToUSB(addr, pedestals[idx]);
  return true;
}

// ============================================================
// RS-485 MASTER: SEND COMMAND TO PEDESTAL
// ============================================================

void rs485SendCommand(int addr) {
  int idx = addr - 1;
  if (idx < 0 || idx >= NUM_PEDESTALS) return;
  if (!pendingCmd[idx].pending) return;

  rs485SetTX();
  Serial1.print('P');
  Serial1.print(addr);
  Serial1.print(",H");
  Serial1.print(pendingCmd[idx].haloPwm);
  Serial1.print(",N");
  Serial1.print(pendingCmd[idx].neoR);
  Serial1.print('.');
  Serial1.print(pendingCmd[idx].neoG);
  Serial1.print('.');
  Serial1.print(pendingCmd[idx].neoB);
  Serial1.print('.');
  Serial1.println(pendingCmd[idx].neoW);
  rs485SetRX();

  pendingCmd[idx].pending = false;
}

// ============================================================
// USB COMMAND PARSING (from Mac)
// ============================================================

void processUSBCommand(const char* line) {
  // H<addr>,<pwm> — set pedestal halo
  if (line[0] == 'H') {
    int addr = 0, pwm = 0;
    if (sscanf(line, "H%d,%d", &addr, &pwm) == 2) {
      if (addr >= 1 && addr <= NUM_PEDESTALS) {
        int idx = addr - 1;
        pendingCmd[idx].haloPwm = constrain(pwm, 0, 255);
        pendingCmd[idx].pending = true;
      }
    }
    return;
  }

  // N<addr>,<r>.<g>.<b>.<w> — set pedestal NeoPixel
  if (line[0] == 'N') {
    int addr = 0, r = 0, g = 0, b = 0, w = 0;
    if (sscanf(line, "N%d,%d.%d.%d.%d", &addr, &r, &g, &b, &w) == 5) {
      if (addr >= 1 && addr <= NUM_PEDESTALS) {
        int idx = addr - 1;
        pendingCmd[idx].neoR = constrain(r, 0, 255);
        pendingCmd[idx].neoG = constrain(g, 0, 255);
        pendingCmd[idx].neoB = constrain(b, 0, 255);
        pendingCmd[idx].neoW = constrain(w, 0, 255);
        pendingCmd[idx].pending = true;
      }
    }
    return;
  }
}

void readUSBCommands() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n') {
      usbBuf[usbBufLen] = '\0';
      if (usbBufLen > 0) {
        processUSBCommand(usbBuf);
      }
      usbBufLen = 0;
    } else if (c != '\r' && usbBufLen < (int)sizeof(usbBuf) - 1) {
      usbBuf[usbBufLen++] = c;
    }
  }
}

// ============================================================
// MAIN LOOP
// ============================================================

void loop() {
  unsigned long now = millis();

  // --- Panel inputs ---
  debounceAll();
  int  mode = computeMode();
  bool jolt = !inputs[I_JOLT].state;  // inverted: NC contact block

  bool changed = (mode != prevMode) || (jolt != prevJolt);
  bool heartbeat = (now - lastSendMs) >= HEARTBEAT_MS;

  if (changed || heartbeat) {
    sendPanelState(mode, jolt);
    prevMode = mode;
    prevJolt = jolt;
    lastSendMs = now;
  }

  // --- USB commands from Mac ---
  readUSBCommands();

  // --- RS-485 pedestal polling ---
  if ((now - lastPollMs) >= RS485_POLL_INTERVAL_MS) {
    lastPollMs = now;

    // Send any pending command first, then poll
    rs485SendCommand(currentPollAddr);
    rs485PollPedestal(currentPollAddr);

    // Advance to next pedestal
    currentPollAddr++;
    if (currentPollAddr > NUM_PEDESTALS) {
      currentPollAddr = 1;
    }
  }
}
