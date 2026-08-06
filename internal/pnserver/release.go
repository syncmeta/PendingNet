package pnserver

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	githubAPIBase      = "https://api.github.com"
	maxReleaseMetadata = 4 << 20
	maxReleaseAsset    = 128 << 20
)

type InstalledEngineVersions struct {
	Xray      string `json:"xray"`
	Hysteria2 string `json:"hysteria2"`
}

type releaseFetcher func(context.Context, string, int64) ([]byte, error)

type releaseInstaller struct {
	apiBase string
	fetch   releaseFetcher
}

func newReleaseInstaller() *releaseInstaller {
	client := &http.Client{
		Timeout: 3 * time.Minute,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("too many release download redirects")
			}
			if req.URL.Scheme != "https" {
				return errors.New("release redirect must use HTTPS")
			}
			return nil
		},
	}
	return &releaseInstaller{apiBase: githubAPIBase, fetch: func(ctx context.Context, rawURL string, limit int64) ([]byte, error) {
		u, err := url.Parse(rawURL)
		if err != nil || u.Scheme != "https" {
			return nil, errors.New("release URL must use HTTPS")
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Accept", "application/vnd.github+json")
		req.Header.Set("User-Agent", "pendingnet-server/1")
		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("download %s: HTTP %d", u.Host, resp.StatusCode)
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
		if err != nil {
			return nil, err
		}
		if int64(len(body)) > limit {
			return nil, fmt.Errorf("download from %s exceeds size limit", u.Host)
		}
		return body, nil
	}}
}

func InstallLatestProxyEngines(ctx context.Context, xrayDestination, hysteriaDestination string) (InstalledEngineVersions, error) {
	if runtime.GOOS != "linux" {
		return InstalledEngineVersions{}, errors.New("proxy engines can only be installed on Linux")
	}
	installer := newReleaseInstaller()
	for _, destination := range []string{xrayDestination, hysteriaDestination} {
		if _, err := os.Lstat(destination); err == nil {
			return InstalledEngineVersions{}, fmt.Errorf("engine destination already exists: %s (use --skip-download to keep it)", destination)
		} else if !errors.Is(err, os.ErrNotExist) {
			return InstalledEngineVersions{}, err
		}
	}
	xrayAsset, hysteriaAsset, err := releaseAssetNames(runtime.GOARCH)
	if err != nil {
		return InstalledEngineVersions{}, err
	}
	xrayVersion, err := installer.installLatest(ctx, "XTLS/Xray-core", xrayAsset, "xray", xrayDestination)
	if err != nil {
		return InstalledEngineVersions{}, fmt.Errorf("install Xray: %w", err)
	}
	hy2Version, err := installer.installLatest(ctx, "apernet/hysteria", hysteriaAsset, "", hysteriaDestination)
	if err != nil {
		_ = os.Remove(xrayDestination)
		return InstalledEngineVersions{}, fmt.Errorf("install Hysteria2: %w", err)
	}
	return InstalledEngineVersions{Xray: xrayVersion, Hysteria2: hy2Version}, nil
}

func releaseAssetNames(goarch string) (string, string, error) {
	switch goarch {
	case "amd64":
		return "Xray-linux-64.zip", "hysteria-linux-amd64", nil
	case "arm64":
		return "Xray-linux-arm64-v8a.zip", "hysteria-linux-arm64", nil
	default:
		return "", "", fmt.Errorf("unsupported Linux architecture %q", goarch)
	}
}

func (i *releaseInstaller) installLatest(ctx context.Context, repo, assetName, zippedBinary, destination string) (string, error) {
	metadata, err := i.fetch(ctx, i.apiBase+"/repos/"+repo+"/releases/latest", maxReleaseMetadata)
	if err != nil {
		return "", err
	}
	var release struct {
		TagName string `json:"tag_name"`
		Assets  []struct {
			Name   string `json:"name"`
			URL    string `json:"browser_download_url"`
			Digest string `json:"digest"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(metadata, &release); err != nil {
		return "", fmt.Errorf("decode release metadata: %w", err)
	}
	if release.TagName == "" {
		return "", errors.New("release metadata has no tag")
	}
	for _, asset := range release.Assets {
		if asset.Name != assetName {
			continue
		}
		data, err := i.fetch(ctx, asset.URL, maxReleaseAsset)
		if err != nil {
			return "", err
		}
		if err := verifyReleaseDigest(data, asset.Digest); err != nil {
			return "", err
		}
		if zippedBinary != "" {
			data, err = extractZipBinary(data, zippedBinary)
			if err != nil {
				return "", err
			}
		}
		if err := writeExecutable(destination, data); err != nil {
			return "", err
		}
		return release.TagName, nil
	}
	return "", fmt.Errorf("release %s does not contain %s", release.TagName, assetName)
}

func verifyReleaseDigest(data []byte, digest string) error {
	algorithm, want, ok := strings.Cut(strings.TrimSpace(digest), ":")
	if !ok || algorithm != "sha256" || len(want) != 64 {
		return errors.New("release asset has no usable SHA-256 digest")
	}
	if _, err := hex.DecodeString(want); err != nil {
		return errors.New("release asset SHA-256 digest is invalid")
	}
	got := sha256.Sum256(data)
	if !strings.EqualFold(hex.EncodeToString(got[:]), want) {
		return errors.New("release asset SHA-256 mismatch")
	}
	return nil
}

func extractZipBinary(data []byte, binaryName string) ([]byte, error) {
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("open release zip: %w", err)
	}
	for _, file := range reader.File {
		if filepath.Base(file.Name) != binaryName || file.FileInfo().IsDir() {
			continue
		}
		if file.UncompressedSize64 > maxReleaseAsset {
			return nil, errors.New("binary in release zip exceeds size limit")
		}
		r, err := file.Open()
		if err != nil {
			return nil, err
		}
		content, readErr := io.ReadAll(io.LimitReader(r, maxReleaseAsset+1))
		closeErr := r.Close()
		if readErr != nil {
			return nil, readErr
		}
		if closeErr != nil {
			return nil, closeErr
		}
		if len(content) > maxReleaseAsset {
			return nil, errors.New("binary in release zip exceeds size limit")
		}
		return content, nil
	}
	return nil, fmt.Errorf("release zip does not contain %s", binaryName)
}

func writeExecutable(destination string, data []byte) error {
	if !filepath.IsAbs(destination) {
		return errors.New("executable destination must be absolute")
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(destination), ".pendingnet-engine-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o755); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, destination)
}
