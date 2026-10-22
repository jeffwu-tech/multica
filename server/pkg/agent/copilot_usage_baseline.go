package agent

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// loadUsageBaseline returns the cumulative per-model totals a resumed Copilot
// session had reached before this run, or nil when they cannot be determined.
func (b *copilotBackend) loadUsageBaseline(env []string, opts ExecOptions) map[string]copilotUsageData {
	path, err := copilotSessionEventsPath(env, opts.CustomArgs, opts.Cwd, opts.ResumeSessionID)
	if err == nil {
		var baseline map[string]copilotUsageData
		if baseline, err = readCopilotUsageBaseline(path); err == nil {
			return baseline
		}
	}
	b.cfg.Logger.Warn("copilot usage baseline unavailable; this resumed run will not report session totals",
		"session", opts.ResumeSessionID, "path", path, "err", err)
	return nil
}

// copilotSessionEventsPath locates the CLI's own event log for a session.
func copilotSessionEventsPath(env, customArgs []string, cwd, sessionID string) (string, error) {
	if sessionID == "" || sessionID == "." || sessionID == ".." || strings.ContainsAny(sessionID, "/\\:\x00") {
		return "", fmt.Errorf("invalid copilot session id %q", sessionID)
	}
	home, err := copilotHomeDir(env, customArgs, cwd)
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "session-state", sessionID, "events.jsonl"), nil
}

// copilotHomeDir mirrors the CLI's state-directory resolution: the deprecated
// --config-dir flag, then COPILOT_HOME, then ~/.copilot. A relative path
// resolves against the CLI's working directory.
func copilotHomeDir(env, customArgs []string, cwd string) (string, error) {
	dir := copilotConfigDirArg(customArgs)
	if dir == "" {
		dir, _ = lastEnvValue(env, "COPILOT_HOME")
	}
	if dir == "" {
		homeKey := "HOME"
		if runtime.GOOS == "windows" {
			homeKey = "USERPROFILE"
		}
		home, _ := lastEnvValue(env, homeKey)
		if home == "" {
			var err error
			if home, err = os.UserHomeDir(); err != nil {
				return "", fmt.Errorf("resolve home directory for Copilot state: %w", err)
			}
		}
		dir = filepath.Join(home, ".copilot")
	}
	if !filepath.IsAbs(dir) && cwd != "" {
		dir = filepath.Join(cwd, dir)
	}
	return filepath.Abs(dir)
}

// copilotConfigDirArg returns the last --config-dir value in customArgs.
func copilotConfigDirArg(customArgs []string) string {
	var dir string
	for i, arg := range customArgs {
		if value, ok := strings.CutPrefix(arg, "--config-dir="); ok {
			dir = value
		} else if arg == "--config-dir" && i+1 < len(customArgs) {
			dir = customArgs[i+1]
		}
	}
	return dir
}

var (
	copilotCheckpointTypeMarker = []byte(`"type":"session.usage_checkpoint"`)
	copilotShutdownTypeMarker   = []byte(`"type":"session.shutdown"`)
)

// readCopilotUsageBaseline returns the last cumulative snapshot in a session
// log. A log without any snapshot yields an empty, non-nil baseline: the
// session has no accounted usage yet, so the whole next snapshot is new.
func readCopilotUsageBaseline(path string) (map[string]copilotUsageData, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	baseline := map[string]copilotUsageData{}
	r := bufio.NewReaderSize(f, 64*1024)
	for {
		line, readErr := r.ReadBytes('\n')
		// Tool output embedded in other events is JSON-escaped, so an unescaped
		// type marker can only come from a snapshot event's own envelope.
		if bytes.Contains(line, copilotCheckpointTypeMarker) || bytes.Contains(line, copilotShutdownTypeMarker) {
			var evt copilotEvent
			if json.Unmarshal(line, &evt) == nil {
				if metrics, ok := copilotSnapshotMetrics(evt); ok && len(metrics) > 0 {
					baseline = make(map[string]copilotUsageData, len(metrics))
					for model, m := range metrics {
						baseline[model] = m.Usage
					}
				}
			}
		}
		if errors.Is(readErr, io.EOF) {
			return baseline, nil
		}
		if readErr != nil {
			return nil, readErr
		}
	}
}
