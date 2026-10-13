package execenv

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Shared issue worktrees: with the daemon's per-issue mode on, every run on one
// issue — whichever agent it belongs to — works in ONE persistent git worktree
// of the user's repo, on one branch. The daemon serialises those runs, so the
// worktree is never shared by two live agents; between runs it simply stays on
// disk, and the next run continues exactly where the last one stopped.
//
// Everything that makes the disposable mode safe still applies per run: the
// user's directory is snapshotted and replayed, leftovers are committed before
// a run is reported, and the branch's owner record decides whether a branch
// may be continued at all. What changes is only that Finalize keeps the
// worktree, and that the next Prepare has to clean up after a run that never
// got to finish.

const (
	// issueWorktreesDirName sits directly under the workspaces root. Dot-prefixed
	// so the env-root GC walk, which skips daemon-internal dot directories,
	// never mistakes it for a workspace.
	issueWorktreesDirName = ".issue-worktrees"
	issueWorktreeMetaFile = "meta.json"
	// issueWorktreeTaskFile records the run currently using the worktree, so a
	// run that dies before its sidecar cleanup can be cleaned up by the next.
	issueWorktreeTaskFile = "task.json"
	// issueWorktreePendingFile holds the user snapshot an unresolved replay in
	// the worktree carries, so the run that resolves it records that snapshot.
	issueWorktreePendingFile = "pending-state"

	// DefaultWorktreeBranchPrefix names shared issue branches when no prefix is
	// configured: multica/<work item or issue key>.
	DefaultWorktreeBranchPrefix = "multica"
	// DefaultWorkItemPattern finds a work item number in an issue title.
	DefaultWorkItemPattern = `\b(?:WI|CS|PRJ)\d{8}\b`

	// sharedIssueOwnerAgent is recorded in place of an agent id on a branch every
	// agent on the issue shares. It never equals a real id, so a branch recorded
	// for one agent is never adopted as the shared one, or the other way round.
	sharedIssueOwnerAgent = "shared-issue"
)

// IssueWorktreeRootParams identifies one issue's shared worktree.
type IssueWorktreeRootParams struct {
	WorkspacesRoot  string
	WorkspaceID     string
	IssueID         string
	IssueKey        string // e.g. WTG-61; names the directory
	IssueTitle      string // its work item number, when present, joins the name
	WorkItemPattern string
	LocalPath       string
}

// IssueWorktreeRoot returns the directory holding the shared worktree for one
// issue in the repository behind LocalPath, named <issue key>[-<work item>].
//
// A directory already recorded for the same workspace, issue and repository is
// always reused, so editing the title never moves an issue to a second
// worktree. Keyed by the repository root rather than the configured path, so
// two resources pointing into the same repository share it.
func IssueWorktreeRoot(p IssueWorktreeRootParams) (string, error) {
	if p.WorkspacesRoot == "" || p.WorkspaceID == "" || p.IssueID == "" {
		return "", errors.New("execenv: issue worktree root needs a workspaces root, workspace id and issue id")
	}
	gitRoot, err := resolveGitRoot(p.LocalPath)
	if err != nil {
		return "", err
	}
	dir := filepath.Join(p.WorkspacesRoot, issueWorktreesDirName)
	if existing := findIssueWorktreeRoot(dir, p.WorkspaceID, p.IssueID, gitRoot); existing != "" {
		return existing, nil
	}
	hash := stableIdentityKey(p.WorkspaceID + "\x00" + p.IssueID + "\x00" + gitRoot)[:16]
	name := issueWorktreeDirName(p.IssueKey, p.IssueTitle, p.WorkItemPattern)
	if name == "" {
		return filepath.Join(dir, hash), nil
	}
	root := filepath.Join(dir, name)
	// The same key can come from another workspace or repository.
	if meta, metaErr := ReadIssueWorktreeMeta(root); metaErr == nil && !meta.isFor(p.WorkspaceID, p.IssueID, gitRoot) {
		root = filepath.Join(dir, name+"-"+hash[:8])
	}
	return root, nil
}

var dirNameUnsafe = regexp.MustCompile(`[^A-Za-z0-9]+`)

// issueWorktreeDirName is <issue key>[-<work item>], kept short for Windows paths.
func issueWorktreeDirName(issueKey, title, workItemPattern string) string {
	part := func(s string) string {
		s = strings.Trim(dirNameUnsafe.ReplaceAllString(s, "-"), "-")
		if len(s) > 24 {
			s = strings.TrimRight(s[:24], "-")
		}
		return s
	}
	key := part(issueKey)
	if key == "" {
		return ""
	}
	if workItemPattern != "" {
		if re, err := regexp.Compile(workItemPattern); err == nil {
			if item := part(re.FindString(title)); item != "" && !strings.EqualFold(item, key) {
				return key + "-" + item
			}
		}
	}
	return key
}

func findIssueWorktreeRoot(dir, workspaceID, issueID, gitRoot string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		root := filepath.Join(dir, entry.Name())
		if meta, metaErr := ReadIssueWorktreeMeta(root); metaErr == nil && meta.isFor(workspaceID, issueID, gitRoot) {
			return root
		}
	}
	return ""
}

func (m *IssueWorktreeMeta) isFor(workspaceID, issueID, gitRoot string) bool {
	if m.WorkspaceID != workspaceID || m.IssueID != issueID {
		return false
	}
	if filepath.Clean(m.GitRoot) == filepath.Clean(gitRoot) {
		return true
	}
	a, errA := os.Stat(m.GitRoot)
	b, errB := os.Stat(gitRoot)
	return errA == nil && errB == nil && os.SameFile(a, b)
}

var branchPrefixComponent = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// ValidateBranchPrefix rejects a prefix git would refuse, or would read as an
// option, before any task depends on it.
func ValidateBranchPrefix(prefix string) error {
	invalid := fmt.Errorf("worktree branch prefix %q is not a valid git branch prefix "+
		"(use letters, digits, '.', '_', '-' and '/' between components)", prefix)
	if prefix == "" {
		return invalid
	}
	for _, component := range strings.Split(prefix, "/") {
		if !branchPrefixComponent.MatchString(component) ||
			strings.Contains(component, "..") ||
			strings.HasSuffix(component, ".") ||
			strings.HasSuffix(component, ".lock") {
			return invalid
		}
	}
	return nil
}

// ValidateWorkItemPattern rejects a work item pattern that does not compile.
func ValidateWorkItemPattern(pattern string) error {
	if _, err := regexp.Compile(pattern); err != nil {
		return fmt.Errorf("worktree work item pattern %q: %w", pattern, err)
	}
	return nil
}

// sharedIssueBranchName is <prefix>/<work item from the title>, falling back to
// <prefix>/<issue key>. Case is kept: the name is meant to match the work item
// as people write it.
func sharedIssueBranchName(gitRoot string, params LocalWorktreeParams) string {
	prefix := params.BranchPrefix
	if prefix == "" {
		prefix = DefaultWorktreeBranchPrefix
	}
	key := params.ConversationKey
	if params.WorkItemPattern != "" {
		if re, err := regexp.Compile(params.WorkItemPattern); err == nil {
			if match := re.FindString(params.IssueTitle); match != "" {
				key = match
			}
		}
	}
	if name := prefix + "/" + key; validBranchName(gitRoot, name) {
		return name
	}
	return prefix + "/" + sanitizeName(params.ConversationKey)
}

func validBranchName(gitRoot, name string) bool {
	if name == "" || strings.HasPrefix(name, "-") {
		return false
	}
	_, err := runGit(gitRoot, "check-ref-format", "refs/heads/"+name)
	return err == nil
}

// findOwnedBranch returns the branch recorded for owner, or "". This is what
// keeps an issue on one branch after its title changes.
func findOwnedBranch(gitRoot string, owner branchOwner, logger *slog.Logger) string {
	out, err := runGitTrimmed(gitRoot, "for-each-ref", "--format=%(refname)", localStateRefPrefix)
	if err != nil {
		return ""
	}
	for _, ref := range strings.Split(out, "\n") {
		branch := strings.TrimPrefix(strings.TrimSpace(ref), localStateRefPrefix)
		if branch == "" || branch == ref {
			continue
		}
		if _, owned := branchOwnedBy(gitRoot, branch, owner, logger); owned {
			return branch
		}
	}
	return ""
}

// registeredWorktreeBranch reports whether worktreePath is a worktree of
// gitRoot's repository, and the branch it has checked out ("" when detached).
func registeredWorktreeBranch(gitRoot, worktreePath string) (branch string, registered bool, err error) {
	target, err := os.Stat(worktreePath)
	if err != nil {
		return "", false, err
	}
	out, err := runGitStdout(gitRoot, "worktree", "list", "--porcelain")
	if err != nil {
		return "", false, fmt.Errorf("git worktree list: %w", err)
	}
	for _, block := range strings.Split(strings.ReplaceAll(out, "\r\n", "\n"), "\n\n") {
		var path, ref string
		for _, line := range strings.Split(block, "\n") {
			switch {
			case strings.HasPrefix(line, "worktree "):
				path = filepath.FromSlash(strings.TrimPrefix(line, "worktree "))
			case strings.HasPrefix(line, "branch "):
				ref = strings.TrimPrefix(line, "branch ")
			}
		}
		if path == "" {
			continue
		}
		info, statErr := os.Stat(path)
		if statErr != nil || !os.SameFile(info, target) {
			continue
		}
		return strings.TrimPrefix(ref, "refs/heads/"), true, nil
	}
	return "", false, nil
}

// reuseIssueWorktree readies the shared worktree an earlier run left behind.
// reused=false with no error means there is none to reuse, and the caller
// creates one at the same path. Anything the daemon cannot account for fails
// closed with the path named: this directory may hold the only copy of work.
//
// A worktree still mid-merge is handed over with its conflicts, which are
// returned so the run's prompt asks the agent to resolve them.
func reuseIssueWorktree(gitRoot, worktreePath, headSHA string, params LocalWorktreeParams, logger *slog.Logger) (plan taskBranchPlan, conflicts []string, reused bool, err error) {
	if _, statErr := os.Lstat(worktreePath); errors.Is(statErr, fs.ErrNotExist) {
		return taskBranchPlan{}, nil, false, nil
	} else if statErr != nil {
		return taskBranchPlan{}, nil, false, fmt.Errorf("execenv: inspect issue worktree %s: %w", worktreePath, statErr)
	}
	fail := func(format string, args ...any) (taskBranchPlan, []string, bool, error) {
		return taskBranchPlan{}, nil, false, fmt.Errorf("execenv: cannot reuse the issue worktree at %s: %s; "+
			"inspect it, then remove the directory to let the next run start over", worktreePath, fmt.Sprintf(format, args...))
	}

	branch, registered, listErr := registeredWorktreeBranch(gitRoot, worktreePath)
	if listErr != nil {
		return fail("%v", listErr)
	}
	if !registered {
		// An empty leftover of a removal Windows could not finish holds no work.
		if entries, readErr := os.ReadDir(worktreePath); readErr == nil && len(entries) == 0 {
			if rmErr := os.Remove(worktreePath); rmErr != nil {
				return fail("could not remove the empty leftover directory: %v", rmErr)
			}
			return taskBranchPlan{}, nil, false, nil
		}
		return fail("it is not a registered worktree of %s", gitRoot)
	}
	if branch == "" {
		return fail("it has no branch checked out")
	}
	if err := cleanStaleIssueWorktreeTask(params.IssueWorktreeRoot, worktreePath, logger); err != nil {
		return fail("the previous run's runtime files could not be removed: %v", err)
	}
	owner := params.owner()
	record, owned := branchOwnedBy(gitRoot, branch, owner, logger)
	if !owned {
		return fail("branch %s is not recorded as this issue's", branch)
	}

	unmerged, err := unmergedPaths(worktreePath)
	if err != nil {
		return fail("could not check for an unresolved merge: %v", err)
	}
	if len(unmerged) == 0 {
		dirty, dirtyErr := worktreeIsDirty(worktreePath)
		if dirtyErr != nil {
			return fail("could not read its status: %v", dirtyErr)
		}
		if dirty {
			// Only a run that died before Finalize leaves changes behind; keep them.
			if _, commitErr := commitEverything(worktreePath, "chore(agent): uncommitted work left by an interrupted run", false); commitErr != nil {
				return fail("could not commit the work an interrupted run left: %v", commitErr)
			}
			if logger != nil {
				logger.Warn("execenv: committed work an interrupted run left in the issue worktree",
					"path", worktreePath, "branch", branch)
			}
		} else if _, mergedErr := runGit(gitRoot, "merge-base", "--is-ancestor", branch, headSHA); mergedErr == nil {
			// Everything on the branch is already in the user's HEAD (merged, or no
			// commits yet): restart it there, in place, rather than re-checking out.
			if out, resetErr := runGit(worktreePath, "reset", "--hard", headSHA); resetErr != nil {
				return fail("could not move it to %s: %s", shortID(headSHA), strings.TrimSpace(out))
			}
			if logger != nil {
				logger.Info("execenv: restarting the issue's shared worktree at the user's HEAD",
					"path", worktreePath, "branch", branch, "head", headSHA)
			}
			return taskBranchPlan{
				name:           branch,
				base:           headSHA,
				reset:          true,
				conversational: true,
				tracksState:    true,
				owner:          owner,
			}, nil, true, nil
		}
	}

	tip, err := runGitTrimmed(worktreePath, "rev-parse", "--verify", "HEAD")
	if err != nil {
		return fail("could not resolve its HEAD: %v", err)
	}
	if logger != nil {
		logger.Info("execenv: reusing the issue's shared worktree",
			"path", worktreePath, "branch", branch, "tip", tip, "unresolved", len(unmerged))
	}
	return taskBranchPlan{
		name:            branch,
		base:            tip,
		continues:       true,
		priorState:      record.state,
		priorCheckpoint: record.checkpoint,
		conversational:  true,
		tracksState:     true,
		owner:           owner,
	}, unmerged, true, nil
}

// IssueWorktreeMeta is what the GC needs to find an issue worktree's parent
// issue and the repository it belongs to.
type IssueWorktreeMeta struct {
	WorkspaceID string    `json:"workspace_id"`
	IssueID     string    `json:"issue_id"`
	GitRoot     string    `json:"git_root"`
	Branch      string    `json:"branch,omitempty"`
	LastUsedAt  time.Time `json:"last_used_at"`
}

// ReadIssueWorktreeMeta reads the record Prepare keeps beside the worktree.
func ReadIssueWorktreeMeta(root string) (*IssueWorktreeMeta, error) {
	data, err := os.ReadFile(filepath.Join(root, issueWorktreeMetaFile))
	if err != nil {
		return nil, err
	}
	var meta IssueWorktreeMeta
	if err := json.Unmarshal(data, &meta); err != nil {
		return nil, fmt.Errorf("parse %s: %w", issueWorktreeMetaFile, err)
	}
	return &meta, nil
}

func writeIssueWorktreeMeta(root string, meta IssueWorktreeMeta) error {
	return writeJSONAtomic(filepath.Join(root, issueWorktreeMetaFile), meta)
}

// issueWorktreeTask is the run currently using a shared worktree: enough to
// undo its sidecars if it never reaches its own cleanup.
type issueWorktreeTask struct {
	TaskID   string          `json:"task_id"`
	WorkDir  string          `json:"work_dir"`
	Provider string          `json:"provider"`
	Sidecars sidecarManifest `json:"sidecars"`
}

func writeIssueWorktreeTask(root string, task issueWorktreeTask) error {
	return writeJSONAtomic(filepath.Join(root, issueWorktreeTaskFile), task)
}

func writeIssuePendingState(root, state string) error {
	return os.WriteFile(filepath.Join(root, issueWorktreePendingFile), []byte(state), 0o644)
}

// readIssuePendingState returns the recorded pending snapshot, or "" when there
// is none or the repository no longer has it.
func readIssuePendingState(root, gitRoot string) string {
	data, err := os.ReadFile(filepath.Join(root, issueWorktreePendingFile))
	if err != nil {
		return ""
	}
	state := strings.TrimSpace(string(data))
	if state == "" {
		return ""
	}
	if _, err := runGit(gitRoot, "cat-file", "-e", state+"^{commit}"); err != nil {
		return ""
	}
	return state
}

func clearIssuePendingState(root string) {
	if root != "" {
		_ = os.Remove(filepath.Join(root, issueWorktreePendingFile))
	}
}

func clearIssueWorktreeTask(root string, logger *slog.Logger) {
	if root == "" {
		return
	}
	if err := os.Remove(filepath.Join(root, issueWorktreeTaskFile)); err != nil && !errors.Is(err, fs.ErrNotExist) && logger != nil {
		logger.Warn("execenv: could not clear the issue worktree's run record", "root", root, "error", err)
	}
}

// cleanStaleIssueWorktreeTask removes the sidecars of a run that ended without
// its own cleanup, so they are neither committed nor read by the next agent.
// Only paths inside the worktree are touched, whatever the record says.
func cleanStaleIssueWorktreeTask(root, worktreePath string, logger *slog.Logger) error {
	data, err := os.ReadFile(filepath.Join(root, issueWorktreeTaskFile))
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var task issueWorktreeTask
	if err := json.Unmarshal(data, &task); err != nil {
		return fmt.Errorf("parse %s: %w", issueWorktreeTaskFile, err)
	}
	inside := func(path string) bool {
		rel, relErr := filepath.Rel(worktreePath, path)
		return relErr == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
	}
	var scoped sidecarManifest
	for _, f := range task.Sidecars.Files {
		if inside(f) {
			scoped.Files = append(scoped.Files, f)
		}
	}
	for _, d := range task.Sidecars.Dirs {
		if inside(d) {
			scoped.Dirs = append(scoped.Dirs, d)
		}
	}
	if err := rollBackManifest(scoped, ""); err != nil {
		return err
	}
	if task.WorkDir != "" && inside(task.WorkDir) {
		if err := CleanupRuntimeConfig(task.WorkDir, task.Provider); err != nil {
			return err
		}
	}
	if logger != nil {
		logger.Info("execenv: removed the runtime files an earlier run left in the issue worktree",
			"root", root, "task_id", task.TaskID)
	}
	clearIssueWorktreeTask(root, logger)
	return nil
}

// IssueWorktreeEntry is one shared issue worktree found on disk.
type IssueWorktreeEntry struct {
	Root    string
	Meta    *IssueWorktreeMeta // nil when the record is missing or unreadable
	ModTime time.Time
}

// ListIssueWorktrees returns every shared issue worktree under workspacesRoot.
func ListIssueWorktrees(workspacesRoot string) ([]IssueWorktreeEntry, error) {
	dir := filepath.Join(workspacesRoot, issueWorktreesDirName)
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []IssueWorktreeEntry
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		root := filepath.Join(dir, entry.Name())
		item := IssueWorktreeEntry{Root: root}
		if info, statErr := entry.Info(); statErr == nil {
			item.ModTime = info.ModTime()
		}
		if meta, metaErr := ReadIssueWorktreeMeta(root); metaErr == nil {
			item.Meta = meta
		}
		out = append(out, item)
	}
	return out, nil
}

// TeardownIssueWorktree removes an issue's shared worktree once nothing will
// run in it again. Its work is committed to the issue branch first; a worktree
// still mid-merge is kept, since committing it would deliver conflict markers.
// The caller must hold the daemon's lock for this issue.
func TeardownIssueWorktree(root string, logger *slog.Logger) error {
	worktreePath := filepath.Join(root, localWorktreeDirName)
	if _, err := os.Lstat(worktreePath); err == nil {
		meta, metaErr := ReadIssueWorktreeMeta(root)
		if metaErr != nil {
			if entries, readErr := os.ReadDir(worktreePath); readErr == nil && len(entries) == 0 {
				return os.RemoveAll(root)
			}
			return fmt.Errorf("no record of the repository behind %s, so its work cannot be committed; remove it by hand: %w",
				worktreePath, metaErr)
		}
		if _, repoErr := os.Stat(meta.GitRoot); repoErr == nil {
			unlock, lockErr := lockGitRoot(meta.GitRoot, logger)
			if lockErr != nil {
				return lockErr
			}
			defer unlock()
			if err := cleanStaleIssueWorktreeTask(root, worktreePath, logger); err != nil {
				return fmt.Errorf("remove runtime files from %s: %w", worktreePath, err)
			}
			unmerged, err := unmergedPaths(worktreePath)
			if err != nil {
				return fmt.Errorf("check %s for an unresolved merge: %w", worktreePath, err)
			}
			if len(unmerged) > 0 {
				return fmt.Errorf("keeping %s: %s still unmerged", worktreePath, quotedPaths(unmerged))
			}
			dirty, err := worktreeIsDirty(worktreePath)
			if err != nil {
				return fmt.Errorf("read the status of %s: %w", worktreePath, err)
			}
			if dirty {
				if _, err := commitEverything(worktreePath, "chore(agent): uncommitted work kept when the issue worktree was reclaimed", false); err != nil {
					return fmt.Errorf("keeping %s: its uncommitted work could not be committed: %w", worktreePath, err)
				}
			}
			branch, _, _ := registeredWorktreeBranch(meta.GitRoot, worktreePath)
			if err := removeLocalWorktreeDir(meta.GitRoot, worktreePath, logger); err != nil {
				return err
			}
			// A branch with nothing the user's HEAD lacks carries no work; do not leave it behind.
			if branch != "" {
				if _, err := runGit(meta.GitRoot, "merge-base", "--is-ancestor", branch, "HEAD"); err == nil {
					dropBranch(meta.GitRoot, branch, logger)
				}
			}
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return os.RemoveAll(root)
}

func writeJSONAtomic(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}
