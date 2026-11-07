//go:build bundled_ffmpeg

package main

import _ "embed"

//go:embed payload/ffmpeg.exe
var ffmpegBinary []byte

// Fully bundled release (FFmpeg license and corresponding-source obligations apply).
func bundledFFmpeg() []byte { return ffmpegBinary }
