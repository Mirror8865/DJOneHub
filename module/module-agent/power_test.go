package main

import (
	"math"
	"os"
	"path/filepath"
	"testing"
)

func TestReadSystemPowerReadsThermalZone(t *testing.T) {
	root := t.TempDir()
	writePowerFixture(t, root, "sys/class/power_supply/usb/voltage_now", "5050000\n")
	writePowerFixture(t, root, "sys/class/power_supply/usb/current_now", "720000\n")
	writePowerFixture(t, root, "sys/class/thermal/thermal_zone0/type", "soc\n")
	writePowerFixture(t, root, "sys/class/thermal/thermal_zone0/temp", "43250\n")

	status := readSystemPower(root)
	if !status.Supported || len(status.Readings) != 2 {
		t.Fatalf("温度接口应被识别，status=%#v", status)
	}
	thermal := status.Readings[1]
	if thermal.Kind != "thermal" || thermal.Name != "soc" {
		t.Fatalf("温度接口身份错误: %#v", thermal)
	}
	if thermal.TemperatureC == nil || math.Abs(*thermal.TemperatureC-43.25) > 0.000_001 {
		t.Fatalf("temperature_c=%v，期望 43.25", thermal.TemperatureC)
	}
}

func TestReadTemperatureAcceptsQDC507NativeCelsius(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "temperature")
	if err := os.WriteFile(path, []byte("40\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	value := readTemperature(path)
	if value == nil || *value != 40 {
		t.Fatalf("temperature=%v，期望 40", value)
	}
}

func writePowerFixture(t *testing.T, root, relative, value string) {
	t.Helper()
	path := filepath.Join(root, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}
