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
	metadata := fmt.Sprintf(`{"tag_name":"v1.2.3","assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://download.test/xray.zip","digest":"sha256:%s"}]}`, hex.EncodeToString(sum[:]))
	installer := &releaseInstaller{
		apiBase: "https://api.test",
		fetch: func(_ context.Context, rawURL string, _ int64) ([]byte, error) {
			if rawURL == "https://api.test/repos/XTLS/Xray-core/releases/latest" {
				return []byte(metadata), nil
			}
			if rawURL == "https://download.test/xray.zip" {
				return zipBuffer.Bytes(), nil
			}
			return nil, fmt.Errorf("unexpected URL %s", rawURL)
		},
	}
	destination := filepath.Join(t.TempDir(), "xray")
	version, err := installer.installLatest(context.Background(), "XTLS/Xray-core", "Xray-linux-64.zip", "xray", destination)
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

func TestReleaseAssetNames(t *testing.T) {
	xray, hy2, err := releaseAssetNames("arm64")
	if err != nil {
		t.Fatal(err)
	}
	if xray != "Xray-linux-arm64-v8a.zip" || hy2 != "hysteria-linux-arm64" {
		t.Fatalf("assets %q %q", xray, hy2)
	}
}
