package core

import (
	"path/filepath"

	"sbtally/internal/source"
)

// AppKey picks the best application label: process name, else binary basename,
// else sniffed host, else "unknown".
func AppKey(c source.Connection) string {
	if c.Process != "" {
		return c.Process
	}
	if c.ProcessPath != "" {
		return filepath.Base(c.ProcessPath)
	}
	if c.Host != "" {
		return c.Host
	}
	return "unknown"
}

// HostKey picks host, else destination IP, else "unknown".
func HostKey(c source.Connection) string {
	if c.Host != "" {
		return c.Host
	}
	if c.DestIP != "" {
		return c.DestIP
	}
	return "unknown"
}
