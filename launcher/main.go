//go:build windows

// Cælōcord native Windows launcher. A single EXE carries the WPF/PowerShell
// application and its images; a build with -tags bundled_ffmpeg also carries
// ffmpeg.exe. Users do not need to install Go or .NET SDK.
package main

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

const version = "1.0.0"

//go:embed payload/Caelocord.ps1 payload/art/mavi-ay-amblem.ico payload/art/mavi-ay-amblem.png payload/art/mavi-ay-arkaplan.png payload/art/kayit-ay-motifi.png
var packagedApp embed.FS

var files = []string{
	"Caelocord.ps1",
	"art/mavi-ay-amblem.ico",
	"art/mavi-ay-amblem.png",
	"art/mavi-ay-arkaplan.png",
	"art/kayit-ay-motifi.png",
}

func main() {
	if err := run(); err != nil {
		messageBox("Cælōcord could not start", err.Error())
		os.Exit(1)
	}
}

func run() error {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		var err error
		base, err = os.UserCacheDir()
		if err != nil {
			return fmt.Errorf("cannot locate local application data: %w", err)
		}
	}
	appRoot := filepath.Join(base, "Caelocord")
	appDir := filepath.Join(appRoot, "app", version)
	if err := os.MkdirAll(appDir, 0700); err != nil {
		return fmt.Errorf("cannot create application cache: %w", err)
	}

	for _, name := range files {
		bytes, err := packagedApp.ReadFile("payload/" + name)
		if err != nil {
			return fmt.Errorf("embedded file %s: %w", name, err)
		}
		if err := ensureFile(filepath.Join(appDir, filepath.FromSlash(name)), bytes); err != nil {
			return fmt.Errorf("extracting %s: %w", name, err)
		}
	}

	// No downloading is required on builds carrying the optional FFmpeg blob.
	// Lightweight builds retain the app's consent-based FFmpeg first-run setup.
	if ffmpeg := bundledFFmpeg(); len(ffmpeg) > 0 {
		if err := ensureFile(filepath.Join(appRoot, "ffmpeg.exe"), ffmpeg); err != nil {
			return fmt.Errorf("extracting embedded FFmpeg: %w", err)
		}
	}

	logDir := filepath.Join(appRoot, "logs")
	if err := os.MkdirAll(logDir, 0700); err != nil {
		return err
	}
	logPath := filepath.Join(logDir, "launcher.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	fmt.Fprintln(logFile, "Cælōcord", version)

	scriptPath := filepath.Join(appDir, "Caelocord.ps1")
	cmd := exec.Command("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File", scriptPath)
	cmd.Dir = appDir
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000} // CREATE_NO_WINDOW hides the shell console, not the WPF window
	if err := cmd.Run(); err != nil {
		logFile.Sync()
		if errors.Is(err, exec.ErrNotFound) {
			return fmt.Errorf("Windows PowerShell 5.1 is required. Details: %s", logPath)
		}
		content, _ := os.ReadFile(logPath)
		details := string(content)
		if len(details) > 1600 {
			details = details[len(details)-1600:]
		}
		return fmt.Errorf("the app exited unexpectedly (%v).\n\n%s\n\nDiagnostic log: %s", err, strings.TrimSpace(details), logPath)
	}
	return nil
}

// Atomic replacement avoids partial extraction on a crash. Hash equality
// prevents rewriting all assets and triggering AV scans on every launch.
func ensureFile(target string, data []byte) error {
	newSum := sha256.Sum256(data)
	if current, err := os.Open(target); err == nil {
		hash := sha256.New()
		_, copyErr := io.Copy(hash, current)
		current.Close()
		if copyErr == nil && hex.EncodeToString(hash.Sum(nil)) == hex.EncodeToString(newSum[:]) {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(target), ".caelocord-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	// Windows os.Rename cannot always replace a preexisting file.
	if err := os.Remove(target); err != nil && !os.IsNotExist(err) {
		return err
	}
	return os.Rename(tmpName, target)
}

func messageBox(title, body string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	proc := user32.NewProc("MessageBoxW")
	t, _ := syscall.UTF16PtrFromString(title)
	b, _ := syscall.UTF16PtrFromString(body)
	proc.Call(0, uintptr(unsafe.Pointer(b)), uintptr(unsafe.Pointer(t)), 0x10)
}
