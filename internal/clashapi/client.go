// Package clashapi performs runtime switches against the sing-box Clash API:
// routing mode (PATCH /configs) and selector outbounds (PUT /proxies/{name}).
package clashapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

type Client struct {
	base   string
	secret string
	http   *http.Client
}

func New(addr, secret string) *Client {
	return &Client{base: "http://" + addr, secret: secret, http: &http.Client{Timeout: 5 * time.Second}}
}

type Proxy struct {
	Type string   `json:"type"`
	Now  string   `json:"now"`
	All  []string `json:"all"`
}

func (c *Client) do(ctx context.Context, method, path string, body any) (*http.Response, error) {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rdr)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.secret)
	}
	return c.http.Do(req)
}

func (c *Client) SetMode(ctx context.Context, mode string) error {
	resp, err := c.do(ctx, http.MethodPatch, "/configs", map[string]string{"mode": mode})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("set mode: status %d", resp.StatusCode)
	}
	return nil
}

func (c *Client) SelectProxy(ctx context.Context, selector, name string) error {
	resp, err := c.do(ctx, http.MethodPut, "/proxies/"+selector, map[string]string{"name": name})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("select proxy: status %d", resp.StatusCode)
	}
	return nil
}

func (c *Client) Mode(ctx context.Context) (string, error) {
	resp, err := c.do(ctx, http.MethodGet, "/configs", nil)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var cfg struct {
		Mode string `json:"mode"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&cfg); err != nil {
		return "", err
	}
	return cfg.Mode, nil
}

func (c *Client) Proxies(ctx context.Context) (map[string]Proxy, error) {
	resp, err := c.do(ctx, http.MethodGet, "/proxies", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var wrap struct {
		Proxies map[string]Proxy `json:"proxies"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrap); err != nil {
		return nil, err
	}
	return wrap.Proxies, nil
}
