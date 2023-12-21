/////////////////////////////////////////////////////////////////
/*
  BLE RC Car Project, Version 1
  For More Information: https://youtu.be/A8SoJppPIok
  Created by Eric N. (ThatProject)
*/
/////////////////////////////////////////////////////////////////

// Version Info
// ESP32      2.0.14
// ESP32Servo 1.1.1

// Namespace collision on class BLEDescriptor between our BLE and ArduinoBLE.
// -> Remove ArduinoBLE

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#include <ESP32Servo.h>  //https://madhephaestus.github.io/ESP32Servo/annotated.html
#include "driver/mcpwm.h"
#include <Wire.h>

#define BLE_NAME "ESP32-RC-CAR"
#define SERVICE_UUID "fc96f65e-318a-4001-84bd-77e9d12af44b"
#define CHARACTERISTIC_UUID_TX "94b43599-5ea2-41e7-9d99-6ff9b904ae3a"
#define CHARACTERISTIC_UUID_RX "04d3552e-b9b3-4be6-a8b4-aa43c4507c4d"

#define GPIO_PWM0A_OUT 1
#define GPIO_PWM0B_OUT 2

Servo servo_motor;

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristicTX = NULL;
BLECharacteristic* pCharacteristicRX = NULL;

int servoAngle = 0;
int motorSpeed = 0;

// Motor Control
static void motor_forward(mcpwm_unit_t mcpwm_num, mcpwm_timer_t timer_num, float duty_cycle) {
  mcpwm_set_signal_low(mcpwm_num, timer_num, MCPWM_OPR_B);
  mcpwm_set_duty(mcpwm_num, timer_num, MCPWM_OPR_A, duty_cycle);
  mcpwm_set_duty_type(mcpwm_num, timer_num, MCPWM_OPR_A, MCPWM_DUTY_MODE_0);
}

static void motor_backward(mcpwm_unit_t mcpwm_num, mcpwm_timer_t timer_num, float duty_cycle) {
  mcpwm_set_signal_low(mcpwm_num, timer_num, MCPWM_OPR_A);
  mcpwm_set_duty(mcpwm_num, timer_num, MCPWM_OPR_B, duty_cycle);
  mcpwm_set_duty_type(mcpwm_num, timer_num, MCPWM_OPR_B, MCPWM_DUTY_MODE_0);
}
static void motor_stop(mcpwm_unit_t mcpwm_num, mcpwm_timer_t timer_num) {
  mcpwm_set_signal_low(mcpwm_num, timer_num, MCPWM_OPR_A);
  mcpwm_set_signal_low(mcpwm_num, timer_num, MCPWM_OPR_B);
}

// BLE Server Callback
class ServerCallback : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    Serial.println("Client Connected!");
  };

  void onDisconnect(BLEServer* pServer) {
    Serial.println("Client disconnecting... Waiting for new connection");
    pServer->startAdvertising();  // restart advertising
  }
};

// BLE RX Callback
class RXCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    uint8_t* data = pCharacteristic->getData();
    int size = pCharacteristic->getLength();

    if (size <= 1) {
      return;
    }

    switch (data[0]) {
      case 1:
        Serial.println("DC");
        motorSpeed = data[1] - 127;
        Serial.printf("DC Speed: %d\n", motorSpeed);
        if (motorSpeed == 0) {
          motor_stop(MCPWM_UNIT_0, MCPWM_TIMER_0);
        } else if (motorSpeed > 0) {
          motor_forward(MCPWM_UNIT_0, MCPWM_TIMER_0, motorSpeed);
        } else {
          motor_backward(MCPWM_UNIT_0, MCPWM_TIMER_0, motorSpeed);
        }
        break;

      case 2:
        servoAngle = data[1];
        if (servoAngle > 180) servoAngle = 180;

        Serial.printf("Servo Angle: %d\n", servoAngle);
        servo_motor.write(servoAngle);
        break;

      default:
        break;
    }
  }
};


static void motor_init() {
  // Servo Motor
  servo_motor.attach(3, 750, 2250);

  // DC Motor
  mcpwm_gpio_init(MCPWM_UNIT_0, MCPWM0A, GPIO_PWM0A_OUT);
  mcpwm_gpio_init(MCPWM_UNIT_0, MCPWM0B, GPIO_PWM0B_OUT);

  // MCPWM Config
  mcpwm_config_t pwm_config;
  pwm_config.frequency = 1000;
  pwm_config.cmpr_a = 0;
  pwm_config.cmpr_b = 0;
  pwm_config.counter_mode = MCPWM_UP_COUNTER;
  pwm_config.duty_mode = MCPWM_DUTY_MODE_0;

  mcpwm_init(MCPWM_UNIT_0, MCPWM_TIMER_0, &pwm_config);
}

void setup() {
  Serial.begin(115200);

  // Motor Initialization
  motor_init();

  // Create the BLE Device
  BLEDevice::init(BLE_NAME);
  Serial.printf("BLE Server Mac Address: %s\n", BLEDevice::getAddress().toString().c_str());

  // Create the BLE Server
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallback());

  // Create the BLE Service
  BLEService* pService = pServer->createService(SERVICE_UUID);

  // Create a BLE Characteristic For notifying
  pCharacteristicTX = pService->createCharacteristic(
    CHARACTERISTIC_UUID_TX,
    BLECharacteristic::PROPERTY_NOTIFY);

  // Create a BLE Descriptor
  pCharacteristicTX->addDescriptor(new BLE2902());

  // Create a BLE Characteristic For reading
  pCharacteristicRX = pService->createCharacteristic(
    CHARACTERISTIC_UUID_RX,
    BLECharacteristic::PROPERTY_WRITE);
  pCharacteristicRX->setCallbacks(new RXCallback());

  // Create a BLE Descriptor
  pCharacteristicRX->addDescriptor(new BLE2902());

  // Start the service
  pService->start();

  // Start advertising
  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(false);
  pAdvertising->setMinPreferred(0x0);  // set value to 0x00 to not advertise this parameter
  BLEDevice::startAdvertising();
  Serial.println("Waiting a client connection to notify...");
}

void loop() {}