package agent

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Copilot CLI 1.0.102 --output-format json: session.usage_checkpoint is the
// only stdout event that carries token counts. Trimmed to the fields that
// matter; promptCacheBreakState and friends are omitted.
const fixtureUsageCheckpoint = `{"type":"session.usage_checkpoint","data":{"totalNanoAiu":401240000,"totalPremiumRequests":1,"modelCacheState":[{"modelId":"claude-opus-5.5","cacheTtlSeconds":300}],"accountingSnapshot":{"totalPremiumRequestCost":1.0,"totalUserRequests":1,"tokenDetails":{"input":{"tokenCount":4},"cache_read":{"tokenCount":0},"cache_write":{"tokenCount":32080},"output":{"tokenCount":4}},"modelMetrics":{"claude-opus-5.5":{"requests":{"count":1,"cost":1.0},"usage":{"inputTokens":32084,"outputTokens":4,"cacheReadTokens":0,"cacheWriteTokens":32080,"reasoningTokens":0}}},"currentModel":"claude-opus-5.5","lastCallInputTokens":32084,"lastCallOutputTokens":4},"usageAccountingWatermarks":{"984fd4f3-eff3-4aca-823f-bea15f932d7e":1}},"id":"cp-1","timestamp":"2026-10-22T09:08:06.660Z","parentId":"p-1"}`

// The same session after a resumed second run: the CLI restored its
// accumulators, so every figure includes the first run.
const fixtureUsageCheckpointResumed = `{"type":"session.usage_checkpoint","data":{"totalPremiumRequests":2,"accountingSnapshot":{"modelMetrics":{"claude-opus-5.5":{"requests":{"count":2,"cost":2.0},"usage":{"inputTokens":64217,"outputTokens":9,"cacheReadTokens":18439,"cacheWriteTokens":45770,"reasoningTokens":0}}},"currentModel":"claude-opus-5.5","lastCallInputTokens":32133,"lastCallOutputTokens":5}},"id":"cp-2","timestamp":"2026-10-22T09:08:52.000Z","parentId":"p-2"}`

const fixtureModernAssistantMessage = `{"type":"assistant.message","data":{"messageId":"m1","model":"claude-opus-5.5","providerId":"copilot","content":"ok","toolRequests":[],"interactionId":"i1","turnId":"0"},"id":"am-1","timestamp":"2026-10-22T09:08:06.654Z","parentId":"p-1"}`

var (
	firstRunUsage     = TokenUsage{InputTokens: 4, OutputTokens: 4, CacheWriteTokens: 32080}
	resumedRunUsage   = TokenUsage{InputTokens: 4, OutputTokens: 5, CacheReadTokens: 18439, CacheWriteTokens: 13690}
	wholeSessionUsage = TokenUsage{InputTokens: 8, OutputTokens: 9, CacheReadTokens: 18439, CacheWriteTokens: 45770}
)

func copilotBaselineOf(t *testing.T, line string) map[string]copilotUsageData {
	t.Helper()
	metrics, ok := copilotSnapshotMetrics(parseCopilotEvent(t, line))
	if !ok {
		t.Fatalf("not a snapshot event: %s", line)
	}
	baseline := make(map[string]copilotUsageData, len(metrics))
	for model, m := range metrics {
		baseline[model] = m.Usage
	}
	return baseline
}

func TestCopilotUsageCheckpointScopesUsageToRun(t *testing.T) {
	t.Parallel()
	otherModel := `{"type":"session.usage_checkpoint","data":{"accountingSnapshot":{"modelMetrics":{"claude-opus-5.5":{"usage":{"inputTokens":64217,"outputTokens":9,"cacheReadTokens":18439,"cacheWriteTokens":45770}},"gpt-5.4-mini":{"usage":{"inputTokens":700,"outputTokens":30,"cacheReadTokens":200}}}}},"id":"cp-3","timestamp":"2026-10-22T09:09:00.000Z"}`

	for _, tc := range []struct {
		name     string
		lines    []string
		resumed  bool
		baseline map[string]copilotUsageData
		want     map[string]TokenUsage
	}{
		{
			name:  "fresh run reports the snapshot",
			lines: []string{fixtureModernAssistantMessage, fixtureUsageCheckpoint, fixtureResult},
			want:  map[string]TokenUsage{"claude-opus-5.5": firstRunUsage},
		},
		{
			// Snapshots are cumulative: the latest replaces, never adds to, the
			// earlier ones.
			name:  "later snapshot replaces earlier one",
			lines: []string{fixtureUsageCheckpoint, fixtureUsageCheckpointResumed, fixtureResult},
			want:  map[string]TokenUsage{"claude-opus-5.5": wholeSessionUsage},
		},
		{
			name:     "resumed run subtracts the baseline",
			lines:    []string{fixtureModernAssistantMessage, fixtureUsageCheckpointResumed, fixtureResult},
			resumed:  true,
			baseline: copilotBaselineOf(t, fixtureUsageCheckpoint),
			want:     map[string]TokenUsage{"claude-opus-5.5": resumedRunUsage},
		},
		{
			name:     "model new to a resumed session is all this run's",
			lines:    []string{otherModel, fixtureResult},
			resumed:  true,
			baseline: copilotBaselineOf(t, fixtureUsageCheckpoint),
			want: map[string]TokenUsage{
				"claude-opus-5.5": resumedRunUsage,
				"gpt-5.4-mini":    {InputTokens: 500, OutputTokens: 30, CacheReadTokens: 200},
			},
		},
		{
			// The session log existed but held no snapshot yet.
			name:     "empty baseline on a resumed run",
			lines:    []string{fixtureUsageCheckpoint, fixtureResult},
			resumed:  true,
			baseline: map[string]copilotUsageData{},
			want:     map[string]TokenUsage{"claude-opus-5.5": firstRunUsage},
		},
		{
			// Raw totals on a resume would bill every earlier run again.
			name:    "resumed run without a baseline reports nothing",
			lines:   []string{fixtureUsageCheckpointResumed, fixtureResult},
			resumed: true,
			want:    map[string]TokenUsage{},
		},
		{
			name:     "resumed run baseline also scopes session.shutdown",
			lines:    []string{fixtureShutdown, fixtureResult},
			resumed:  true,
			baseline: map[string]copilotUsageData{"claude-sonnet-4.5": {InputTokens: 10000, OutputTokens: 300, CacheReadTokens: 8000, CacheWriteTokens: 2000}},
			want:     map[string]TokenUsage{"claude-sonnet-4.5": {InputTokens: 4000, OutputTokens: 600, CacheReadTokens: 16000}},
		},
		{
			name:  "checkpoint without modelMetrics does not wipe totals",
			lines: []string{fixtureUsageCheckpoint, `{"type":"session.usage_checkpoint","data":{"totalPremiumRequests":1},"id":"cp-x"}`, fixtureResult},
			want:  map[string]TokenUsage{"claude-opus-5.5": firstRunUsage},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			st := newCopilotEventState("copilot", tc.resumed)
			st.baseline = tc.baseline
			for _, line := range tc.lines {
				handleCopilotEvent(parseCopilotEvent(t, line), st)
			}
			if got := st.resolveUsage(); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("usage = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestCopilotUsageCheckpointBeatsMessageTokens(t *testing.T) {
	t.Parallel()
	lines := []string{fixtureSessionStart, fixtureAssistantMessage, fixtureUsageCheckpoint, fixtureResult}

	_, _, _, usage := simulateCopilotEventLoop(t, lines)

	if !reflect.DeepEqual(usage, map[string]TokenUsage{"claude-opus-5.5": firstRunUsage}) {
		t.Fatalf("expected the checkpoint breakdown to win over message outputTokens, got %+v", usage)
	}
}

func TestReadCopilotUsageBaseline(t *testing.T) {
	t.Parallel()
	shutdown := `{"type":"session.shutdown","data":{"shutdownType":"routine","modelMetrics":{"claude-opus-5.5":{"usage":{"inputTokens":64217,"outputTokens":9,"cacheReadTokens":18439,"cacheWriteTokens":45770}}}},"id":"sd-1"}`
	// Tool output quoting a snapshot is JSON-escaped inside another event.
	toolEcho := `{"type":"tool.execution_complete","data":{"toolCallId":"c1","success":true,"result":{"content":"{\"type\":\"session.usage_checkpoint\",\"data\":{}}"}},"id":"t-1"}`
	user := `{"type":"user.message","data":{"content":"next"},"id":"u-1"}`

	write := func(t *testing.T, lines ...string) string {
		t.Helper()
		path := filepath.Join(t.TempDir(), "events.jsonl")
		if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}

	t.Run("last snapshot wins", func(t *testing.T) {
		t.Parallel()
		got, err := readCopilotUsageBaseline(write(t, user, fixtureUsageCheckpoint, shutdown, toolEcho, user))
		if err != nil {
			t.Fatal(err)
		}
		want := map[string]copilotUsageData{"claude-opus-5.5": {InputTokens: 64217, OutputTokens: 9, CacheReadTokens: 18439, CacheWriteTokens: 45770}}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("baseline = %+v, want %+v", got, want)
		}
	})

	t.Run("no snapshot is an empty baseline", func(t *testing.T) {
		t.Parallel()
		got, err := readCopilotUsageBaseline(write(t, user, toolEcho))
		if err != nil {
			t.Fatal(err)
		}
		if got == nil || len(got) != 0 {
			t.Fatalf("expected an empty non-nil baseline, got %#v", got)
		}
	})

	t.Run("missing log is an error", func(t *testing.T) {
		t.Parallel()
		if got, err := readCopilotUsageBaseline(filepath.Join(t.TempDir(), "missing.jsonl")); err == nil {
			t.Fatalf("expected an error, got %#v", got)
		}
	})
}

func TestCopilotHomeDir(t *testing.T) {
	t.Parallel()
	homeKey := "HOME"
	if runtime.GOOS == "windows" {
		homeKey = "USERPROFILE"
	}
	flagDir := t.TempDir()
	envDir := t.TempDir()
	userHome := t.TempDir()
	cwd := t.TempDir()

	for _, tc := range []struct {
		name       string
		env        []string
		customArgs []string
		want       string
	}{
		{"home fallback", []string{homeKey + "=" + userHome}, nil, filepath.Join(userHome, ".copilot")},
		{"COPILOT_HOME", []string{homeKey + "=" + userHome, "COPILOT_HOME=" + envDir}, nil, envDir},
		{"last COPILOT_HOME wins", []string{"COPILOT_HOME=" + userHome, "COPILOT_HOME=" + envDir}, nil, envDir},
		{"--config-dir beats COPILOT_HOME", []string{"COPILOT_HOME=" + envDir}, []string{"--config-dir", flagDir}, flagDir},
		{"--config-dir= form", nil, []string{"--config-dir=" + flagDir}, flagDir},
		{"relative path resolves against cwd", []string{"COPILOT_HOME=state"}, nil, filepath.Join(cwd, "state")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := copilotHomeDir(tc.env, tc.customArgs, cwd)
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("copilotHomeDir = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestCopilotSessionEventsPathRejectsUnsafeIDs(t *testing.T) {
	t.Parallel()
	env := []string{"COPILOT_HOME=" + t.TempDir()}
	for _, id := range []string{"", ".", "..", "../other", `..\other`, "a/b", "C:evil"} {
		if path, err := copilotSessionEventsPath(env, nil, "", id); err == nil {
			t.Errorf("session id %q resolved to %q; want an error", id, path)
		}
	}
}

// ── Execute: the fake CLI is this test binary, re-executed via TestMain ──

const (
	copilotFakeStreamEnv     = "COPILOT_FAKE_STREAM"
	copilotFakeSessionLogEnv = "COPILOT_FAKE_SESSION_LOG"
)

// runFakeCopilotStream prints a recorded stream and, like the real CLI,
// appends it to the session log while the run is in progress.
func runFakeCopilotStream() {
	stream, err := os.ReadFile(os.Getenv(copilotFakeStreamEnv))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if logPath := os.Getenv(copilotFakeSessionLogEnv); logPath != "" {
		f, err := os.OpenFile(logPath, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o600)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		_, _ = f.Write(stream)
		_ = f.Close()
	}
	_, _ = os.Stdout.Write(stream)
}

func TestCopilotExecuteReportsRunScopedUsage(t *testing.T) {
	t.Parallel()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	const sessionID = "984fd4f3-eff3-4aca-823f-bea15f932d7e"
	result := fmt.Sprintf(`{"type":"result","sessionId":%q,"exitCode":0,"usage":{"premiumRequests":1}}`, sessionID)

	writeFile := func(t *testing.T, path string, lines ...string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	for _, tc := range []struct {
		name       string
		resume     string
		priorLog   []string
		checkpoint string
		want       map[string]TokenUsage
	}{
		{"fresh", "", nil, fixtureUsageCheckpoint, map[string]TokenUsage{"claude-opus-5.5": firstRunUsage}},
		{"resumed", sessionID, []string{fixtureModernAssistantMessage, fixtureUsageCheckpoint}, fixtureUsageCheckpointResumed, map[string]TokenUsage{"claude-opus-5.5": resumedRunUsage}},
		{"resumed without a session log", sessionID, nil, fixtureUsageCheckpointResumed, map[string]TokenUsage{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			home := t.TempDir()
			logPath := filepath.Join(home, "session-state", sessionID, "events.jsonl")
			env := map[string]string{"COPILOT_HOME": home}
			if tc.priorLog != nil {
				writeFile(t, logPath, tc.priorLog...)
				env[copilotFakeSessionLogEnv] = logPath
			}
			streamPath := filepath.Join(t.TempDir(), "stream.jsonl")
			writeFile(t, streamPath, fixtureModernAssistantMessage, tc.checkpoint, result)
			env[copilotFakeStreamEnv] = streamPath

			backend, err := New("copilot", Config{ExecutablePath: self, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), Env: env})
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			session, err := backend.Execute(ctx, "prompt", ExecOptions{ResumeSessionID: tc.resume, Timeout: 20 * time.Second})
			if err != nil {
				t.Fatal(err)
			}
			for range session.Messages {
			}
			res, ok := <-session.Result
			if !ok {
				t.Fatal("result channel closed without a value")
			}
			if res.Status != "completed" || res.SessionID != sessionID {
				t.Fatalf("result = %+v", res)
			}
			if !reflect.DeepEqual(res.Usage, tc.want) {
				t.Fatalf("usage = %+v, want %+v", res.Usage, tc.want)
			}
		})
	}
}
