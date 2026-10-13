//go:build !unix

package pnserver

import "errors"

func lockStateFile(path string) (func(), error) {
	return nil, errors.New("PendingNet server state requires a Unix file lock")
}
