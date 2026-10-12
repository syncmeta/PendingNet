package pnserver

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestReleaseInstallerVerifiesAndExtractsAsset(t *testing.T) {
	var zipBuffer bytes.Buffer
	zw := zip.NewWriter(&zipBuffer)
	w, _ := zw.Create("xray")
	_, _ = w.Write([]byte("xray-binary"))
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(zipBuffer.Bytes())
	engine := LockedEngine{Version: "v1.2.3", Assets: map[string]EngineAsset{"amd64": {URL: "https://download.test/xray.zip", Digest: "sha256:" + hex.EncodeToString(sum[:])}}}
	installer := &releaseInstaller{
		fetch: func(_ context.Context, rawURL string, _ int64) ([]byte, error) {
			if rawURL == "https://download.test/xray.zip" {
				return zipBuffer.Bytes(), nil
			}
			return nil, fmt.Errorf("unexpected URL %s", rawURL)
		},
	}
	destination := filepath.Join(t.TempDir(), "xray")
	version, err := installer.installLocked(context.Background(), engine, "amd64", "xray", destination)
	if err != nil {
		t.Fatal(err)
	}
	if version != "v1.2.3" {
		t.Fatalf("version %q", version)
	}
	data, _ := os.ReadFile(destination)
	if string(data) != "xray-binary" {
		t.Fatalf("binary %q", data)
	}
}

func TestReleaseInstallerRejectsDigestMismatch(t *testing.T) {
	err := verifyReleaseDigest([]byte("tampered"), "sha256:"+string(bytes.Repeat([]byte{'0'}, 64)))
	if err == nil {
		t.Fatal("expected digest mismatch")
	}
}
