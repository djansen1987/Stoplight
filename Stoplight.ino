#include <WiFi.h>
#include <WebServer.h>
#include <Adafruit_NeoPixel.h>
#include <WiFiManager.h>
#include <Preferences.h>
#include <esp_wifi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
// arduino-cli compile --fqbn "esp32:esp32:esp32s3:FlashMode=qio,FlashSize=4M,CDCOnBoot=cdc" --upload --port COM5 . 2>&1 | Select-String "Connecting|Wrote|Hash|Hard|ERROR" -Context 1

// --- CONFIGURATION ---
#define LED_PIN    8
#define BUTTON_PIN 7
#define LED_COUNT  3
#define BRIGHTNESS 80

Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);
WebServer server(80);
WiFiManager wifiManager;
Preferences preferences;
TaskHandle_t ledTaskHandle = NULL;
SemaphoreHandle_t stripMutex;

uint8_t modeIndex = 0; // 0=off,1=green,2=orange,3=red,4=disco,5=fade
bool wifiConnected = false;
bool wifiSetupComplete = false;
unsigned long wifiSetupStartTime = 0;
bool wifiSetupActive = false;
bool lastButtonState = HIGH;
unsigned long lastDebounceTime = 0;
const unsigned long debounceDelay = 50;
unsigned long buttonPressStartTime = 0;
bool buttonLongPressHandled = false;
const unsigned long LONG_PRESS_DURATION = 10000; // 10 seconds

void ledLoop(void * parameter) {
  // Animation state
  static unsigned long lastUpdate = 0;
  static uint16_t discoHue = 0;
  static uint8_t discoPhase = 0;
  static unsigned long phaseStartTime = 0;
  static uint8_t sequenceOrder[8] = {0, 1, 2, 3, 4, 5, 6, 7};
  static bool sequenceOrderInitialized = false;
  static unsigned long lastFade = 0;
  static uint16_t fadeHue = 0;

  for(;;) {
    uint8_t currentMode = modeIndex; // simple lock-free read

    if (currentMode == 4) {
      if (!sequenceOrderInitialized) {
        for (int i = 7; i > 0; i--) {
          int j = random(0, i + 1);
          uint8_t temp = sequenceOrder[i];
          sequenceOrder[i] = sequenceOrder[j];
          sequenceOrder[j] = temp;
        }
        sequenceOrderInitialized = true;
        phaseStartTime = millis();
      }

      if (millis() - lastUpdate > 50) {
        lastUpdate = millis();
        discoHue += 500;
        if (millis() - phaseStartTime > 5000) {
          phaseStartTime = millis();
          discoPhase = (discoPhase + 1) % 8;
        }
        uint8_t currentSequence = sequenceOrder[discoPhase];

        if (xSemaphoreTake(stripMutex, portMAX_DELAY)) {
          switch(currentSequence) {
            case 0:
              for(int i = 0; i < LED_COUNT; i++) {
                uint16_t hue = discoHue + (i * 21845);
                uint32_t color = strip.gamma32(strip.ColorHSV(hue));
                strip.setPixelColor(i, color);
              }
              break;
            case 1:
              for(int i = 0; i < LED_COUNT; i++) {
                if ((millis() / 200 + i) % 2 == 0) {
                  uint16_t hue = discoHue;
                  uint32_t color = strip.gamma32(strip.ColorHSV(hue));
                  strip.setPixelColor(i, color);
                } else {
                  uint16_t hue = discoHue + 32768;
                  uint32_t color = strip.gamma32(strip.ColorHSV(hue));
                  strip.setPixelColor(i, color);
                }
              }
              break;
            case 2: {
              int wavePos = (millis() / 200) % LED_COUNT;
              for(int i = 0; i < LED_COUNT; i++) {
                if (i == wavePos) {
                  uint16_t hue = discoHue;
                  uint32_t color = strip.gamma32(strip.ColorHSV(hue));
                  strip.setPixelColor(i, color);
                } else {
                  strip.setPixelColor(i, 0);
                }
              }
            } break;
            case 3: {
              uint16_t basehue = discoHue;
              int brightness = 128 + 127 * sin(millis() / 500.0);
              for(int i = 0; i < LED_COUNT; i++) {
                uint32_t color = strip.gamma32(strip.ColorHSV(basehue, 255, brightness));
                strip.setPixelColor(i, color);
              }
            } break;
            case 4: {
              uint16_t hue = discoHue;
              uint32_t color = strip.gamma32(strip.ColorHSV(hue));
              if ((millis() / 100) % 2 == 0) {
                for(int i = 0; i < LED_COUNT; i++) {
                  strip.setPixelColor(i, color);
                }
              } else {
                strip.clear();
              }
            } break;
            case 5: {
              int chasePos = (millis() / 150) % LED_COUNT;
              strip.clear();
              for(int i = 0; i < LED_COUNT; i++) {
                int distance = (i - chasePos + LED_COUNT) % LED_COUNT;
                if (distance == 0) {
                  uint16_t hue = discoHue;
                  uint32_t color = strip.gamma32(strip.ColorHSV(hue));
                  strip.setPixelColor(i, color);
                } else if (distance == 1) {
                  uint16_t hue = discoHue;
                  uint32_t color = strip.gamma32(strip.ColorHSV(hue, 255, 150));
                  strip.setPixelColor(i, color);
                } else if (distance == 2) {
                  uint16_t hue = discoHue;
                  uint32_t color = strip.gamma32(strip.ColorHSV(hue, 255, 50));
                  strip.setPixelColor(i, color);
                }
              }
            } break;
            case 6:
              for(int i = 0; i < LED_COUNT; i++) {
                uint16_t hue = discoHue + (i * 21845);
                uint32_t color = strip.gamma32(strip.ColorHSV(hue));
                if (random(0, 10) > 6) {
                  strip.setPixelColor(i, color);
                } else {
                  strip.setPixelColor(i, 0);
                }
              }
              break;
            case 7:
              for(int i = 0; i < LED_COUNT; i++) {
                uint16_t hue = discoHue + ((i * 65535) / LED_COUNT) + (millis() / 10);
                uint32_t color = strip.gamma32(strip.ColorHSV(hue));
                strip.setPixelColor(i, color);
              }
              break;
          }
          strip.show();
          xSemaphoreGive(stripMutex);
        }
      }
    } else if (currentMode == 5) {
      if (millis() - lastFade > 20) {
        lastFade = millis();
        fadeHue += 80;
        if (fadeHue >= 65536) fadeHue = 0;
        uint32_t color = strip.gamma32(strip.ColorHSV(fadeHue));
        if (xSemaphoreTake(stripMutex, portMAX_DELAY)) {
          for(int i = 0; i < LED_COUNT; i++) {
            strip.setPixelColor(i, color);
          }
          strip.show();
          xSemaphoreGive(stripMutex);
        }
      }
    } else if (currentMode == 6) {
      // White strobe
      if (millis() - lastUpdate > 100) {
        lastUpdate = millis();
        if (xSemaphoreTake(stripMutex, portMAX_DELAY)) {
          if ((millis() / 100) % 2 == 0) {
            for(int i = 0; i < LED_COUNT; i++) {
              strip.setPixelColor(i, strip.Color(255, 255, 255)); // Wit
            }
          } else {
            strip.clear();
          }
          strip.show();
          xSemaphoreGive(stripMutex);
        }
      }
    } else if (currentMode == 7) {
      // Loop lamp: green -> orange -> red -> repeat
      if (millis() - lastUpdate > 500) {
        lastUpdate = millis();
        if (xSemaphoreTake(stripMutex, portMAX_DELAY)) {
          strip.clear();
          uint8_t loopPos = (millis() / 500) % 3;
          switch(loopPos) {
            case 0: strip.setPixelColor(0, strip.Color(0, 255, 0)); break;      // Groen
            case 1: strip.setPixelColor(1, strip.Color(255, 165, 0)); break;    // Oranje
            case 2: strip.setPixelColor(2, strip.Color(255, 0, 0)); break;      // Rood
          }
          strip.show();
          xSemaphoreGive(stripMutex);
        }
      }
    } else {
      // Non-animation modes: nothing to do here
    }

    delay(1); // keep watchdog happy
  }
}

// Status LED helpers (short pulses for snappy feedback)
void blinkSingle(uint8_t ledIndex, uint32_t color, uint8_t times = 2, uint16_t onMs = 80, uint16_t offMs = 60) {
  for (uint8_t t = 0; t < times; t++) {
    strip.clear();
    strip.setPixelColor(ledIndex, color);
    strip.show();
    delay(onMs);
    strip.clear();
    strip.show();
    delay(offMs);
  }
}

void signalConnected() {
  blinkSingle(0, strip.Color(0, 255, 0)); // bottom LED green
}

void signalError() {
  blinkSingle(2, strip.Color(255, 0, 0)); // top LED red
}

void signalBusy() {
  blinkSingle(1, strip.Color(255, 165, 0), 2, 100, 80); // middle LED orange
}

void signalSetupMode() {
  // All LEDs blinking blue for setup mode
  for (uint8_t t = 0; t < 5; t++) {
    for (uint8_t i = 0; i < LED_COUNT; i++) {
      strip.setPixelColor(i, strip.Color(0, 0, 255));
    }
    strip.show();
    delay(150);
    strip.clear();
    strip.show();
    delay(150);
  }
}

void resetWiFiSettings() {
  Serial.println("WiFi reset started...");
  signalSetupMode();
  
  // Reset WiFiManager + local prefs
  WiFi.disconnect(true, true);
  WiFi.mode(WIFI_OFF);
  delay(100);

  wifiManager.resetSettings();
  preferences.begin("stoplicht", false);
  preferences.putBool("force_setup", true);
  preferences.end();

  Serial.println("WiFi settings cleared! ESP restarting to start setup...");
  delay(300);
  ESP.restart();
}

void applyMode(uint8_t idx) {
  modeIndex = idx % 8;
  Serial.print("Mode -> ");
  Serial.println(modeIndex);
  
  strip.clear();
  switch (modeIndex) {
    case 1: strip.setPixelColor(0, strip.Color(0, 255, 0)); break;      // green
    case 2: strip.setPixelColor(1, strip.Color(255, 165, 0)); break;    // orange
    case 3: strip.setPixelColor(2, strip.Color(255, 0, 0)); break;      // red
    case 4: 
    case 5:
    case 6:
    case 7:
      // disco, fade, strobe, and loop lamp are handled in loop()
      break;
    default: break; // all off
  }
  if (modeIndex != 4 && modeIndex != 5 && modeIndex != 6 && modeIndex != 7) strip.show();
}

// --- HTML INTERFACE ---
const char index_html[] PROGMEM = R"rawliteral(
<!DOCTYPE HTML><html>
<head>
  <meta charset="UTF-8">
  <title>ESP32 Stoplight</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); color: white; min-height: 100vh; padding: 20px; }
    .container { max-width: 500px; margin: 0 auto; }
    h1 { margin: 30px 0 10px 0; font-size: 32px; display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .subtitle { color: #aaa; margin-bottom: 30px; font-size: 14px; }
    .lang-toggle { display: flex; gap: 8px; }
    .lang-toggle button { padding: 6px 10px; border: 1px solid rgba(255,255,255,0.2); border-radius: 8px; background: rgba(255,255,255,0.05); color: white; cursor: pointer; }
    .lang-toggle button.active { background: rgba(255,255,255,0.2); border-color: rgba(255,255,255,0.4); }
    
    section { background: rgba(255,255,255,0.05); border-radius: 15px; padding: 20px; margin: 20px 0; backdrop-filter: blur(10px); border: 1px solid rgba(255,255,255,0.1); }
    section h2 { font-size: 18px; margin-bottom: 15px; border-bottom: 2px solid rgba(255,255,255,0.2); padding-bottom: 10px; }
    
    .buttons-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
    
    .button { padding: 15px 20px; font-size: 16px; font-weight: bold; cursor: pointer; border: none; border-radius: 10px; color: white; transition: all 0.2s; box-shadow: 0 4px 15px rgba(0,0,0,0.2); }
    .button:active { transform: translateY(2px); box-shadow: 0 2px 5px rgba(0,0,0,0.2); }
    .button:disabled { opacity: 0.6; cursor: not-allowed; }
    
    .green { background: linear-gradient(135deg, #4CAF50, #45a049); }
    .orange { background: linear-gradient(135deg, #ff9800, #e68900); }
    .red { background: linear-gradient(135deg, #f44336, #da190b); }
    .disco { background: linear-gradient(135deg, #ff00ff, #00ffff); }
    .fade { background: linear-gradient(135deg, #ffd700, #ff69b4); }
    .strobe { background: linear-gradient(135deg, #cccccc, #ffffff); }
    .looplamp { background: linear-gradient(135deg, #00ff00, #ffff00); }
    .off { background: linear-gradient(135deg, #555, #333); }
    .reboot { background: linear-gradient(135deg, #9c27b0, #673ab7); }
    
    .bootmode-section { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; align-items: center; }
    .bootmode-label { grid-column: 1 / -1; }
    .bootmode-display { background: rgba(255,255,255,0.1); padding: 10px 15px; border-radius: 8px; font-size: 14px; border: 1px solid rgba(255,255,255,0.2); grid-column: 1 / -1; }
    .bootmode-display strong { color: #4CAF50; }
    
    .feedback { margin: 10px 0; padding: 10px 15px; border-radius: 8px; font-size: 13px; display: none; }
    .feedback.success { display: block; background: rgba(76, 175, 80, 0.2); color: #90EE90; border: 1px solid rgba(76, 175, 80, 0.5); }
    .feedback.error { display: block; background: rgba(244, 67, 54, 0.2); color: #FF6B6B; border: 1px solid rgba(244, 67, 54, 0.5); }
    
    .info-text { font-size: 12px; color: #aaa; margin-top: 20px; text-align: center; }
    
    .full-width { grid-column: 1 / -1; }
  </style>
</head>
<body>
  <div class="container">
    <h1><span id="title-text">🚦 Stoplight</span><span class="lang-toggle"><button id="lang-en" onclick="setLanguage('en')">EN</button><button id="lang-nl" onclick="setLanguage('nl')">NL</button></span></h1>
    <p class="subtitle" id="subtitle-text">Web interface</p>
    
    <section>
      <h2 id="control-title">Direct Control</h2>
      <div class="buttons-grid">
        <button id="btn-green" class="button green" onclick="setMode(1)">🟢 Green</button>
        <button id="btn-orange" class="button orange" onclick="setMode(2)">🟠 Orange</button>
        <button id="btn-red" class="button red" onclick="setMode(3)">🔴 Red</button>
        <button id="btn-disco" class="button disco" onclick="setMode(4)">✨ Disco</button>
        <button id="btn-fade" class="button fade" onclick="setMode(5)">🌈 Fade</button>
        <button id="btn-strobe" class="button strobe" onclick="setMode(6)">⚡ Strobe</button>
        <button id="btn-loop" class="button looplamp" onclick="setMode(7)">🔄 Loop</button>
        <button id="btn-off" class="button off" onclick="setMode(0)">⭕ Off</button>
      </div>
    </section>
    
    <section>
      <h2 id="boot-title">Boot Mode (default)</h2>
      <div class="bootmode-section">
        <div class="bootmode-label" id="boot-label">Default mode after boot:</div>
        <div class="bootmode-display"><strong id="bootmode-name">loading...</strong></div>
        <button id="btn-boot-off" class="button off" style="width:100%;" onclick="setBootMode(0)">⭕ Off</button>
        <button id="btn-boot-green" class="button green" style="width:100%;" onclick="setBootMode(1)">🟢 Green</button>
        <button id="btn-boot-orange" class="button orange" style="width:100%;" onclick="setBootMode(2)">🟠 Orange</button>
        <button id="btn-boot-red" class="button red" style="width:100%;" onclick="setBootMode(3)">🔴 Red</button>
        <div id="bootmode-feedback" class="feedback full-width"></div>
      </div>
    </section>
    
    <section>
      <h2 id="settings-title">Settings</h2>
      <button id="btn-reboot" class="button reboot full-width" onclick="rebootDevice()">🔄 Reboot device</button>
      <div id="reboot-feedback" class="feedback full-width"></div>
    </section>
    
    <p class="info-text" id="info-text">API: /api/mode?value=[0-7] | /getBootMode | /setBootMode?mode=[0-7]</p>
  </div>
  
  <script>
    const translations = {
      en: {
        pageTitle: 'ESP32 Stoplight',
        title: '🚦 Stoplight',
        subtitle: 'Web interface',
        controlTitle: 'Direct Control',
        bootTitle: 'Boot Mode (default)',
        bootLabel: 'Default mode after boot:',
        settingsTitle: 'Settings',
        rebootButton: '🔄 Reboot device',
        info: 'API: /api/mode?value=[0-7] | /getBootMode | /setBootMode?mode=[0-7]',
        saving: 'Saving...',
        savedPrefix: '✓ Boot mode set to ',
        errorPrefix: '✗ Error: ',
        connError: '✗ Connection error',
        rebootConfirm: 'Device will reboot and the connection will drop. Proceed?',
        rebooting: '🔄 Device rebooting...',
        unknown: 'unknown',
        loading: 'loading...'
      },
      nl: {
        pageTitle: 'ESP32 Stoplicht',
        title: '🚦 Stoplicht',
        subtitle: 'Webinterface',
        controlTitle: 'Directe Besturing',
        bootTitle: 'Boot Mode (standaard)',
        bootLabel: 'Standaard mode na opstarten:',
        settingsTitle: 'Instellingen',
        rebootButton: '🔄 Herstart apparaat',
        info: 'API: /api/mode?value=[0-7] | /getBootMode | /setBootMode?mode=[0-7]',
        saving: 'Opslaan...',
        savedPrefix: '✓ Boot mode opgeslagen als ',
        errorPrefix: '✗ Fout: ',
        connError: '✗ Verbindingsfout',
        rebootConfirm: 'Apparaat wordt herstart. Verbinding wordt verbroken. Doorgaan?',
        rebooting: '🔄 Apparaat herstart...',
        unknown: 'onbekend',
        loading: 'laden...'
      }
    };

    const modeLabels = {
      en: ['Off','Green','Orange','Red','Disco','Fade','Strobe','Loop'],
      nl: ['Uit','Groen','Oranje','Rood','Disco','Fade','Strobe','Looplamp']
    };

    let currentLang = 'en';

    function applyLanguage(lang) {
      currentLang = translations[lang] ? lang : 'en';
      const t = translations[currentLang];
      const m = modeLabels[currentLang];
      document.title = t.pageTitle;
      document.getElementById('title-text').textContent = t.title;
      document.getElementById('subtitle-text').textContent = t.subtitle;
      document.getElementById('control-title').textContent = t.controlTitle;
      document.getElementById('boot-title').textContent = t.bootTitle;
      document.getElementById('boot-label').textContent = t.bootLabel;
      document.getElementById('settings-title').textContent = t.settingsTitle;
      document.getElementById('btn-reboot').textContent = t.rebootButton;
      document.getElementById('info-text').textContent = t.info;
      document.getElementById('bootmode-name').textContent = t.loading;

      document.getElementById('btn-off').textContent = '⭕ ' + m[0];
      document.getElementById('btn-green').textContent = '🟢 ' + m[1];
      document.getElementById('btn-orange').textContent = '🟠 ' + m[2];
      document.getElementById('btn-red').textContent = '🔴 ' + m[3];
      document.getElementById('btn-disco').textContent = '✨ ' + m[4];
      document.getElementById('btn-fade').textContent = '🌈 ' + m[5];
      document.getElementById('btn-strobe').textContent = '⚡ ' + m[6];
      document.getElementById('btn-loop').textContent = '🔄 ' + m[7];

      document.getElementById('btn-boot-off').textContent = '⭕ ' + m[0];
      document.getElementById('btn-boot-green').textContent = '🟢 ' + m[1];
      document.getElementById('btn-boot-orange').textContent = '🟠 ' + m[2];
      document.getElementById('btn-boot-red').textContent = '🔴 ' + m[3];

      document.getElementById('lang-en').classList.toggle('active', currentLang === 'en');
      document.getElementById('lang-nl').classList.toggle('active', currentLang === 'nl');
    }

    function getModes() {
      return modeLabels[currentLang] || modeLabels.en;
    }

    function setLanguage(lang) {
      applyLanguage(lang);
      updateBootModeDisplay();
    }
    
    function updateBootModeDisplay() {
      const t = translations[currentLang];
      const modes = getModes();
      fetch('/getBootMode')
        .then(r => r.json())
        .then(d => {
          document.getElementById('bootmode-name').textContent = modes[d.mode] || t.unknown;
        })
        .catch(e => console.log('Boot mode fetch error:', e));
    }
    
    function setBootMode(mode) {
      const t = translations[currentLang];
      const modes = getModes();
      const feedback = document.getElementById('bootmode-feedback');
      feedback.className = 'feedback';
      feedback.textContent = t.saving;
      
      fetch('/setBootMode?mode=' + mode)
        .then(r => r.json())
        .then(d => {
          if (d.success) {
            feedback.className = 'feedback success';
            feedback.textContent = t.savedPrefix + modes[mode];
            updateBootModeDisplay();
            setTimeout(() => { feedback.className = 'feedback'; }, 3000);
          } else {
            feedback.className = 'feedback error';
            feedback.textContent = t.errorPrefix + (d.error || t.unknown);
          }
        })
        .catch(e => {
          feedback.className = 'feedback error';
          feedback.textContent = t.connError;
        });
    }
    
    function setMode(m) {
      fetch('/api/mode?value=' + m)
        .then(r => r.json())
        .catch(e => console.log('Mode set error:', e));
    }
    
    function rebootDevice() {
      const t = translations[currentLang];
      if (confirm(t.rebootConfirm)) {
        const feedback = document.getElementById('reboot-feedback');
        feedback.className = 'feedback success';
        feedback.textContent = t.rebooting;
        
        fetch('/reboot')
          .then(r => r.json())
          .catch(e => console.log('Reboot initiated'));
      }
    }
    
    applyLanguage('en');
    updateBootModeDisplay();
  </script>
</body>
</html>
)rawliteral";

void handleRoot() {
  server.send(200, "text/html", index_html);
}

void handleSetBootMode() {
  if (server.hasArg("mode")) {
    int mode = server.arg("mode").toInt();
    if (mode >= 0 && mode <= 7) {
      preferences.begin("stoplicht", false);
      preferences.putUChar("boot_mode", mode);
      preferences.end();
      Serial.print("Boot mode set to: ");
      Serial.println(mode);
      server.send(200, "application/json", "{\"success\":true,\"mode\":" + String(mode) + "}");
    } else {
      server.send(400, "application/json", "{\"success\":false,\"error\":\"mode 0-7 expected\"}");
    }
  } else {
    server.send(400, "application/json", "{\"success\":false,\"error\":\"mode parameter missing\"}");
  }
}

void handleReboot() {
  server.send(200, "application/json", "{\"success\":true,\"message\":\"Rebooting...\"}");
  delay(100);
  ESP.restart();
}

void handleGetBootMode() {
  preferences.begin("stoplicht", false);
  uint8_t mode = preferences.getUChar("boot_mode", 1);
  preferences.end();
  server.send(200, "application/json", "{\"mode\":" + String(mode) + "}");
}

void handleGroen() {
  applyMode(1);
  server.send(200, "text/html", index_html);
}

void handleOranje() {
  applyMode(2);
  server.send(200, "text/html", index_html);
}

void handleRood() {
  applyMode(3);
  server.send(200, "text/html", index_html);
}

void handleDisco() {
  applyMode(4);
  server.send(200, "text/html", index_html);
}

void handleUit() {
  applyMode(0);
  server.send(200, "text/html", index_html);
}

void handleFade() {
  applyMode(5);
  server.send(200, "text/html", index_html);
}

void handleApiMode() {
  if (server.hasArg("value")) {
    int mode = server.arg("value").toInt();
    if (mode >= 0 && mode <= 7) {
      applyMode(mode);
      server.send(200, "application/json", "{\"status\":\"ok\",\"mode\":" + String(mode) + "}");
    } else {
      server.send(400, "application/json", "{\"status\":\"error\",\"message\":\"Invalid mode 0-7\"}");
    }
  } else {
    server.send(200, "application/json", "{\"status\":\"ok\",\"mode\":" + String(modeIndex) + "}");
  }
}

void handleFavicon() {
  const char favicon_svg[] = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' fill='%23222'/><rect x='30' y='10' width='40' height='80' fill='%23444' rx='8'/><circle cx='50' cy='25' r='12' fill='%23ff6666'/><circle cx='50' cy='50' r='12' fill='%23ffcc00'/><circle cx='50' cy='75' r='12' fill='%2366ff66'/></svg>";
  server.sendHeader("Content-Type", "image/svg+xml");
  server.send(200, "image/svg+xml", favicon_svg);
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n\n=== BOOT START ===");

  strip.begin();
  strip.clear();
  strip.show();
  strip.setBrightness(BRIGHTNESS);
  Serial.println("Strip initialized");

  // Boot blink: white on all LEDs
  for (int i = 0; i < 3; i++) {
    for (uint8_t led = 0; led < LED_COUNT; led++) {
      strip.setPixelColor(led, strip.Color(50, 50, 50));
    }
    strip.show();
    delay(100);
    strip.clear();
    strip.show();
    delay(100);
  }
  Serial.println("Boot blink done");

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  Serial.println("Button configured on GPIO7");
  Serial.println("Hold button >10s to reset WiFi");

  // Mutex for safe strip updates across tasks
  stripMutex = xSemaphoreCreateMutex();
  
  // Start LED task on core 0
  xTaskCreatePinnedToCore(
    ledLoop,
    "LedTask",
    8192,
    NULL,
    1,
    &ledTaskHandle,
    0
  );

  // WiFi boot logic: connect when known network exists, otherwise skip
  wifiConnected = false;
  wifiSetupActive = false;
  wifiSetupComplete = false;
  
  preferences.begin("stoplicht", false);
  bool forceSetup = preferences.getBool("force_setup", false);
  if (forceSetup) {
    preferences.putBool("force_setup", false);
  }
  preferences.end();

  wifiManager.setConfigPortalTimeout(180);
  wifiManager.setConnectTimeout(30);

  if (forceSetup) {
    Serial.println("WiFi setup mode (force_setup) started...");
    
    // Set LED 3 (index 2) to blue during setup mode
    xSemaphoreTake(stripMutex, portMAX_DELAY);
    strip.clear();
    strip.setPixelColor(2, strip.Color(0, 0, 255)); // Blue
    strip.show();
    xSemaphoreGive(stripMutex);
    
    // Blocking portal; LED task keeps running on core 0
    if (wifiManager.startConfigPortal("Stoplicht-Setup")) {
      wifiConnected = true;
      Serial.println("\nWiFi connected via setup!");
      Serial.print("IP: ");
      Serial.println(WiFi.localIP());
      signalConnected();
      
      // Start webserver
      server.on("/", handleRoot);
      server.on("/favicon.ico", handleFavicon);
      server.on("/setBootMode", handleSetBootMode);
      server.on("/getBootMode", handleGetBootMode);
      server.on("/reboot", handleReboot);
      server.on("/groen", handleGroen);
      server.on("/oranje", handleOranje);
      server.on("/rood", handleRood);
      server.on("/disco", handleDisco);
      server.on("/fade", handleFade);
      server.on("/uit", handleUit);
      server.on("/api/mode", handleApiMode);
      server.begin();
      Serial.println("Webserver started");
    } else {
      Serial.println("WiFi setup cancelled/timeout - continue without WiFi");
      signalError();
      wifiConnected = false;
    }
  } else {
    // Only try to connect with stored network, NO portal
    wifiManager.setEnableConfigPortal(false);
    Serial.println("Trying WiFi auto-connect (no portal)...");
    if (wifiManager.autoConnect("Stoplicht-Setup")) {
      wifiConnected = true;
      Serial.println("\nWiFi connected!");
      Serial.print("IP: ");
      Serial.println(WiFi.localIP());
      signalConnected();
      
      // Start webserver
      server.on("/", handleRoot);
      server.on("/favicon.ico", handleFavicon);
      server.on("/setBootMode", handleSetBootMode);
      server.on("/getBootMode", handleGetBootMode);
      server.on("/reboot", handleReboot);
      server.on("/groen", handleGroen);
      server.on("/oranje", handleOranje);
      server.on("/rood", handleRood);
      server.on("/disco", handleDisco);
      server.on("/fade", handleFade);
      server.on("/uit", handleUit);
      server.on("/api/mode", handleApiMode);
      server.begin();
      Serial.println("Webserver started");
    } else {
      Serial.println("No stored WiFi or connection failed - continuing without WiFi");
      wifiConnected = false;
    }
  }
  
  // Load boot mode default from preferences
  preferences.begin("stoplicht", false);
  uint8_t bootMode = preferences.getUChar("boot_mode", 1); // default mode 1 (groen)
  preferences.end();
  
  applyMode(0); // start off
  applyMode(bootMode); // set default boot mode
  Serial.println("=== READY ===\n");
}

void loop() {
  // No non-blocking setup loop; setup portal only runs on long-press with reboot
  
  // Serial API: mode:0-7, status, ping, help (process FIRST for fast response)
  if (Serial.available()) {
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    
    if (cmd.length() == 0) {
      return;
    }
    
    // ACK: client receives immediate echo
    Serial.print("[ACK] ");  
    Serial.println(cmd);
    
    // Process command and send result
    if (cmd.startsWith("mode:")) {
      int m = cmd.substring(5).toInt();
      if (m >= 0 && m <= 7) {
        applyMode(m);
        Serial.println("[OK] Mode set");
      } else {
        Serial.println("[ERR] Mode 0-7 expected");
      }
    } else if (cmd == "status") {
      Serial.print("[DATA] mode=");
      Serial.print(modeIndex);
      Serial.print("|wifi=");
      Serial.println(wifiConnected ? "1" : "0");
    } else if (cmd == "ping") {
      Serial.println("[PONG]");
    } else if (cmd == "help") {
      Serial.println("[DATA] Commands: mode:0-7, status, ping, help");
    } else {
      Serial.println("[ERR] Unknown command");
    }
  }

  // Handle web requests if connected
  if (wifiConnected) {
    server.handleClient();
  }

  // LED animations now run in the ledLoop task on core 0

  // Button handling: short press = mode switch, long press (>10s) = WiFi reset
  static bool handled = false;
  int reading = digitalRead(BUTTON_PIN);
  
  if (reading != lastButtonState) {
    lastDebounceTime = millis();
    lastButtonState = reading;
    
    if (reading == LOW) {
      // Button just pressed
      buttonPressStartTime = millis();
      buttonLongPressHandled = false;
    } else {
      // Button released
      buttonPressStartTime = 0;
    }
  }

  // Check for long-press (>10 seconds)
  if (reading == LOW && buttonPressStartTime > 0 && !buttonLongPressHandled) {
    unsigned long pressDuration = millis() - buttonPressStartTime;
    
    if (pressDuration >= LONG_PRESS_DURATION) {
      // Long press detected - start WiFi setup mode without reboot
      buttonLongPressHandled = true;
      Serial.println("Long press gedetecteerd - WiFi setup mode wordt gestart!");
      resetWiFiSettings();
    } else if (pressDuration >= 8000 && pressDuration % 500 < 50) {
      // Warning from 8 seconds (red LED blinks quickly)
      strip.clear();
      strip.setPixelColor(2, strip.Color(255, 0, 0));
      strip.show();
      delay(50);
      strip.clear();
      strip.show();
    }
  }

  // Normal button behavior (short press)
  if ((millis() - lastDebounceTime) > debounceDelay) {
    if (reading == LOW && buttonPressStartTime > 0) {
      unsigned long pressDuration = millis() - buttonPressStartTime;
      
      // Only switch mode on a short press
      if (!handled && pressDuration < 1000) {
        applyMode(modeIndex + 1);
        handled = true;
      }
    } else {
      handled = false;
    }
  }

  // Heartbeat every 5 seconds
  static unsigned long lastHeart = 0;
  if (millis() - lastHeart > 5000) {
    lastHeart = millis();
    Serial.print("Alive, mode=");
    Serial.println(modeIndex);
  }
}
