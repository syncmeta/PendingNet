package pnserver

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestEnrollAndAuthenticatedStatus(t *testing.T) {
	store, _ := testStore(t)
	pairFile, err := store.CreatePairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	handler := (&API{Store: store}).Handler()

	body, _ := json.Marshal(map[string]string{
		"token": pairFile.Enrollment.Token, "device_name": "PendingNet iPhone",
	})
	enrollReq := httptest.NewRequest(http.MethodPost, "/v1/enroll", bytes.NewReader(body))
	enrollReq.Header.Set("Content-Type", "application/json")
	enrollRec := httptest.NewRecorder()
	handler.ServeHTTP(enrollRec, enrollReq)
	if enrollRec.Code != http.StatusCreated {
		t.Fatalf("enroll status %d: %s", enrollRec.Code, enrollRec.Body.String())
	}
	var enrolled struct {
		AccessToken string     `json:"access_token"`
		Server      ServerInfo `json:"server"`
	}
	if err := json.NewDecoder(enrollRec.Body).Decode(&enrolled); err != nil {
		t.Fatal(err)
	}
	if enrolled.AccessToken == "" || enrolled.Server.ServerID != pairFile.ServerID {
		t.Fatalf("unexpected enrollment: %#v", enrolled)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	req.Header.Set("Authorization", "Bearer "+enrolled.AccessToken)
	statusRec := httptest.NewRecorder()
	handler.ServeHTTP(statusRec, req)
	if statusRec.Code != http.StatusOK {
		t.Fatalf("status endpoint returned %d", statusRec.Code)
	}
}

func TestStatusRejectsMissingDeviceToken(t *testing.T) {
	store, _ := testStore(t)
	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	rec := httptest.NewRecorder()
	(&API{Store: store}).Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401", rec.Code)
	}
}

func TestNodeProfileRequiresDeviceToken(t *testing.T) {
	store, _ := testStore(t)
	profile := NodeProfile{Protocols: []NodeProtocol{{
		ID: "reality", Type: "vless-reality", DisplayName: "Reality",
		VLESSReality: &VLESSReality{Server: "203.0.113.10", ServerPort: 443},
	}}}
	if err := store.SaveNodeProfile(profile); err != nil {
		t.Fatal(err)
	}
	handler := (&API{Store: store}).Handler()

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/v1/node", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized node status %d", unauthorized.Code)
	}

	pairFile, err := store.CreatePairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := store.Enroll(pairFile.Enrollment.Token, "test device")
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/node", nil)
	req.Header.Set("Authorization", "Bearer "+credential.Token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !bytes.Contains(rec.Body.Bytes(), []byte(`"vless-reality"`)) {
		t.Fatalf("node status %d: %s", rec.Code, rec.Body.String())
	}
}
