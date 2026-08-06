package pnserver

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

type API struct {
	Store *Store
}

type ServerInfo struct {
	APIVersion   int      `json:"api_version"`
	ServerID     string   `json:"server_id"`
	Name         string   `json:"name"`
	Capabilities []string `json:"capabilities"`
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	mux.HandleFunc("POST /v1/enroll", a.enroll)
	mux.HandleFunc("GET /v1/status", a.status)
	mux.HandleFunc("GET /v1/node", a.node)
	return mux
}

func (a *API) enroll(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	var req struct {
		Token      string `json:"token"`
		DeviceName string `json:"device_name"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	cred, err := a.Store.Enroll(req.Token, req.DeviceName)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, ErrInvalidPairing) {
			status = http.StatusUnauthorized
		}
		writeError(w, status, "enrollment_failed", err.Error())
		return
	}
	state, err := a.Store.Load()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_state", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, struct {
		DeviceID    string     `json:"device_id"`
		AccessToken string     `json:"access_token"`
		Server      ServerInfo `json:"server"`
	}{
		DeviceID: cred.DeviceID, AccessToken: cred.Token, Server: a.serverInfo(state),
	})
}

func (a *API) status(w http.ResponseWriter, r *http.Request) {
	token, ok := bearerToken(r.Header.Get("Authorization"))
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", ErrUnauthorized.Error())
		return
	}
	if _, err := a.Store.Authenticate(token); err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized", ErrUnauthorized.Error())
		return
	}
	state, err := a.Store.Load()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_state", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a.serverInfo(state))
}

func (a *API) node(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if _, ok := a.authorizedDevice(r); !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", ErrUnauthorized.Error())
		return
	}
	profile, err := a.Store.LoadNodeProfile()
	if errors.Is(err, ErrNodeProfileNotFound) {
		writeError(w, http.StatusNotFound, "node_not_configured", err.Error())
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "node_profile", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, profile)
}

func (a *API) authorizedDevice(r *http.Request) (Device, bool) {
	token, ok := bearerToken(r.Header.Get("Authorization"))
	if !ok {
		return Device{}, false
	}
	device, err := a.Store.Authenticate(token)
	return device, err == nil
}

func (a *API) serverInfo(state State) ServerInfo {
	capabilities := []string{"pairing-v1"}
	if profile, err := a.Store.LoadNodeProfile(); err == nil {
		capabilities = append(capabilities, "node-profile-v1")
		for _, protocol := range profile.Protocols {
			capabilities = append(capabilities, protocol.Type)
		}
	}
	return ServerInfo{
		APIVersion: 1, ServerID: state.ServerID, Name: state.Name,
		Capabilities: capabilities,
	}
}

func bearerToken(header string) (string, bool) {
	scheme, token, ok := strings.Cut(header, " ")
	return token, ok && strings.EqualFold(scheme, "Bearer") && token != ""
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]string{"error": code, "message": message})
}
