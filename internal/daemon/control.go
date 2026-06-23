package daemon

import (
	"encoding/json"
	"net/http"

	"sbtally/internal/clashapi"
)

// RegisterControl adds runtime-switch endpoints (VPS/protocol selectors and
// routing mode) backed by the Clash API. These take effect immediately with no
// restart or privilege.
func RegisterControl(mux *http.ServeMux, ctrl *clashapi.Client) {
	mux.HandleFunc("/api/control/proxies", func(w http.ResponseWriter, r *http.Request) {
		ps, err := ctrl.Proxies(r.Context())
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(ps)
	})

	mux.HandleFunc("/api/control/select", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Selector string `json:"selector"`
			Name     string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := ctrl.SelectProxy(r.Context(), req.Selector, req.Name); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("/api/control/mode", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Mode string `json:"mode"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := ctrl.SetMode(r.Context(), req.Mode); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
