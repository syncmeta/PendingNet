package pnserver

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"sbtally/internal/pairing"
)

type API struct {
	Store       *Store
	ServicesDir string
	ConfigHooks ManagedConfigHooks
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
	mux.HandleFunc("GET /v1/admin/users", a.adminUsers)
	mux.HandleFunc("POST /v1/admin/users/{id}/revoke", a.adminRevokeUser)
	mux.HandleFunc("POST /v1/admin/pairings", a.adminCreatePairing)
	mux.HandleFunc("GET /v1/admin/client-config", a.adminClientConfig)
	mux.HandleFunc("GET /v1/admin/config", a.adminConfig)
	mux.HandleFunc("PUT /v1/admin/config", a.adminUpdateConfig)
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
	cred, err := a.Store.EnrollFromIP(req.Token, req.DeviceName, peerIP(r))
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
		Role        string     `json:"role,omitempty"`
		Server      ServerInfo `json:"server"`
	}{
		DeviceID: cred.DeviceID, AccessToken: cred.Token,
		Role: cred.Role, Server: a.serverInfo(state),
	})
}

func (a *API) status(w http.ResponseWriter, r *http.Request) {
	token, ok := bearerToken(r.Header.Get("Authorization"))
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", ErrUnauthorized.Error())
		return
	}
	if _, err := a.Store.AuthenticateFromIP(token, peerIP(r)); err != nil {
		writeAuthError(w, err)
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
	if _, err := a.authorizedDevice(r); err != nil {
		writeAuthError(w, err)
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

func (a *API) authorizedDevice(r *http.Request) (Device, error) {
	token, ok := bearerToken(r.Header.Get("Authorization"))
	if !ok {
		return Device{}, ErrUnauthorized
	}
	return a.Store.AuthenticateFromIP(token, peerIP(r))
}

func (a *API) authorizedAdmin(w http.ResponseWriter, r *http.Request) bool {
	device, err := a.authorizedDevice(r)
	if err != nil {
		writeAuthError(w, err)
		return false
	}
	if device.Role != "admin" {
		writeError(w, http.StatusForbidden, "forbidden", "management permission required")
		return false
	}
	return true
}

func (a *API) adminUsers(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !a.authorizedAdmin(w, r) {
		return
	}
	state, err := a.Store.Load()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_state", "cannot read server state")
		return
	}
	// User records contain names, roles and first-seen IPs, but no token hashes.
	writeJSON(w, http.StatusOK, map[string]any{"users": state.Users})
}

func (a *API) adminRevokeUser(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !a.authorizedAdmin(w, r) {
		return
	}
	err := a.Store.RevokeUser(r.PathValue("id"))
	if errors.Is(err, ErrUserNotFound) {
		writeError(w, http.StatusNotFound, "user_not_found", err.Error())
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_state", "cannot revoke user")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) adminCreatePairing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !a.authorizedAdmin(w, r) {
		return
	}
	var input struct {
		Role       string `json:"role"`
		TTLSeconds int    `json:"ttl_seconds"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "invalid pairing request")
		return
	}
	var extra any
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid_request", "trailing pairing request data")
		return
	}
	if (input.Role != "client" && input.Role != "admin") || input.TTLSeconds < 1 || input.TTLSeconds > 86400 {
		writeError(w, http.StatusBadRequest, "invalid_request", "role and 1-86400 ttl_seconds are required")
		return
	}
	ttl := time.Duration(input.TTLSeconds) * time.Second
	var file pairing.File
	var err error
	if input.Role == "admin" {
		file, err = a.Store.CreateAdminPairing(ttl)
	} else {
		file, err = a.Store.CreatePairing(ttl)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_state", "cannot issue pairing")
		return
	}
	link, err := file.URL(a.Store.now())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_state", "cannot encode pairing")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"link": link, "expires_at": file.Enrollment.ExpiresAt})
}

func (a *API) adminClientConfig(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !a.authorizedAdmin(w, r) {
		return
	}
	query := r.URL.Query()
	platforms := query["platform"]
	if len(query) != 1 || len(platforms) != 1 ||
		(platforms[0] != "android" && platforms[0] != "windows") {
		writeError(w, http.StatusBadRequest, "invalid_request", "android or windows platform required")
		return
	}
	profile, err := a.Store.LoadNodeProfile()
	if errors.Is(err, ErrNodeProfileNotFound) {
		writeError(w, http.StatusNotFound, "not_provisioned", "node profile is not provisioned")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_state", "cannot load node profile")
		return
	}
	config, err := BuildClientConfig(profile, platforms[0])
	if err != nil {
		writeError(w, http.StatusUnprocessableEntity, "invalid_node_profile", "node profile cannot be exported")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(config)
}

func (a *API) adminConfig(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !a.authorizedAdmin(w, r) {
		return
	}
	snapshot, err := a.Store.ReadManagedConfig(a.ServicesDir)
	if errors.Is(err, ErrManagedConfigNotFound) {
		writeError(w, http.StatusNotFound, "not_provisioned", "managed configuration is not provisioned")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_state", "cannot read managed configuration")
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func (a *API) adminUpdateConfig(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !a.authorizedAdmin(w, r) {
		return
	}
	// The production server does not enable this endpoint until it has safe
	// validators and health-checked restart hooks. Do not accept a write merely
	// because the caller has administrator credentials.
	if a.ConfigHooks.Validate == nil || a.ConfigHooks.Restart == nil {
		writeError(w, http.StatusServiceUnavailable, "management_unavailable", "configuration editing is unavailable")
		return
	}
	var candidate ManagedConfig
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 3*maxManagedConfigBytes+4096))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&candidate); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "invalid configuration request")
		return
	}
	var extra any
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid_request", "trailing configuration request data")
		return
	}
	if err := a.Store.ApplyManagedConfig(a.ServicesDir, candidate, a.ConfigHooks); err != nil {
		switch {
		case errors.Is(err, ErrManagedConfigConflict):
			writeError(w, http.StatusConflict, "config_conflict", "configuration changed; reload before saving")
		case errors.Is(err, ErrManagedConfigInvalid):
			writeError(w, http.StatusUnprocessableEntity, "invalid_config", "configuration did not pass validation")
		case errors.Is(err, ErrManagedConfigNotFound):
			writeError(w, http.StatusNotFound, "not_provisioned", "managed configuration is not provisioned")
		default:
			writeError(w, http.StatusInternalServerError, "config_update_failed", "configuration update failed; check server health")
		}
		return
	}
	snapshot, err := a.Store.ReadManagedConfig(a.ServicesDir)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_state", "cannot read updated configuration")
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func writeAuthError(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrUnauthorized) {
		writeError(w, http.StatusUnauthorized, "unauthorized", ErrUnauthorized.Error())
		return
	}
	writeError(w, http.StatusInternalServerError, "server_state", "cannot persist server state")
}

// RemoteAddr is set by the HTTP server from the direct connection. Forwarded
// headers are deliberately ignored because clients can forge them.
func peerIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return ""
	}
	return host
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
