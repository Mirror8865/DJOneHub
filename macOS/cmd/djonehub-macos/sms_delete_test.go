package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestClearSMSCacheRemovesEveryCachedMessage(t *testing.T) {
	a := &app{sms: []receivedSMS{
		{Sender: "10086", Content: "first", Timestamp: time.Now()},
		{Sender: "10010", Content: "second", Timestamp: time.Now()},
	}}

	a.clearSMSCache()

	a.smsMu.RLock()
	defer a.smsMu.RUnlock()
	if len(a.sms) != 0 {
		t.Fatalf("cached SMS count = %d, want 0", len(a.sms))
	}
}

func TestSMSStorageClearResult(t *testing.T) {
	result := smsStorageClearResult{Memory: "SM", Before: 2, After: 0}
	if result.Memory != "SM" || result.Before != 2 || result.After != 0 {
		t.Fatalf("unexpected SMS clear result: %#v", result)
	}
}

func TestClearModuleSMSDemoReportsBothStores(t *testing.T) {
	a := &app{demo: true}
	recorder := httptest.NewRecorder()

	a.clearModuleSMS(recorder, httptest.NewRequest(http.MethodPost, "/api/sms/clear-module", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	var response struct {
		Cleared  bool     `json:"cleared"`
		Storages []string `json:"storages"`
	}
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !response.Cleared || len(response.Storages) != 2 || response.Storages[0] != "SM" || response.Storages[1] != "ME" {
		t.Fatalf("unexpected clear response: %#v", response)
	}
}
