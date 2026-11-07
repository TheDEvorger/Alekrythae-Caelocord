//go:build !bundled_ffmpeg

package main

// The lightweight EXE keeps everything except FFmpeg embedded. The app
// downloads FFmpeg only after prompting the user, or uses an existing install.
func bundledFFmpeg() []byte { return nil }
