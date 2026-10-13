package execenv

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const workItemTitle = "WI00123456 Fix the rate calculation"

func prepareSharedRun(t *testing.T, repo, issueRoot, agentID, taskID, title string) (*LocalWorktree, error) {
	t.Helper()
	return PrepareLocalWorktree(LocalWorktreeParams{
		LocalPath:         repo,
		EnvRoot:           t.TempDir(),
		AgentName:         agentID,
		TaskID:            taskID,
		ConversationKey:   "MUL-6881",
		WorkspaceID:       testBranchOwner.WorkspaceID,
		AgentID:           agentID,
		ConversationID:    testBranchOwner.ConversationID,
		IssueWorktreeRoot: issueRoot,
		BranchPrefix:      "JWU",
		IssueTitle:        title,
		WorkItemPattern:   DefaultWorkItemPattern,
	}, worktreeTestLogger())
}

func mustPrepareShared(t *testing.T, repo, issueRoot, agentID, taskID, title string) *LocalWorktree {
	t.Helper()
	wt, err := prepareSharedRun(t, repo, issueRoot, agentID, taskID, title)
	if err != nil {
		t.Fatalf("PrepareLocalWorktree(%s): %v", taskID, err)
	}
	return wt
}

func TestSharedIssueWorktreeIsReusedAcrossAgents(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")

	first := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	if first.Branch != "JWU/WI00123456" {
		t.Fatalf("branch = %q, want JWU/WI00123456", first.Branch)
	}
	if first.Reused {
		t.Error("first run reports Reused = true")
	}
	writeFile(t, filepath.Join(first.WorkDir, "from-a.txt"), "agent a\n")
	if outcome := finalizeOK(t, first); outcome.Branch != first.Branch {
		t.Fatalf("first outcome branch = %q", outcome.Branch)
	}
	if _, err := os.Stat(first.Path); err != nil {
		t.Fatalf("shared worktree removed by Finalize: %v", err)
	}

	second := mustPrepareShared(t, repo, issueRoot, "agent-b", turnTwoTask, workItemTitle)
	if !second.Reused || second.Path != first.Path || second.Branch != first.Branch {
		t.Fatalf("second run: reused=%v path=%q branch=%q; want the first run's worktree", second.Reused, second.Path, second.Branch)
	}
	if got := readFile(t, filepath.Join(second.WorkDir, "from-a.txt")); got != "agent a\n" {
		t.Errorf("agent b does not see agent a's work: %q", got)
	}
	writeFile(t, filepath.Join(second.WorkDir, "from-b.txt"), "agent b\n")
	finalizeOK(t, second)

	for file, want := range map[string]string{"from-a.txt": "agent a", "from-b.txt": "agent b"} {
		if got := gitRun(t, repo, "show", "JWU/WI00123456:"+file); got != want {
			t.Errorf("%s on the branch = %q, want %q", file, got, want)
		}
	}
	if branches := gitRun(t, repo, "branch", "--list", "agent/*"); branches != "" {
		t.Errorf("shared runs created per-agent branches: %q", branches)
	}
}

func TestSharedIssueBranchFallsBackToTheIssueKey(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	wt := mustPrepareShared(t, repo, filepath.Join(t.TempDir(), "issue"), "agent-a", turnOneTask, "Fix the rate calculation")
	if wt.Branch != "JWU/MUL-6881" {
		t.Errorf("branch = %q, want JWU/MUL-6881", wt.Branch)
	}
}

func TestSharedIssueBranchSurvivesATitleChange(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")

	first := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	writeFile(t, filepath.Join(first.WorkDir, "work.txt"), "work\n")
	finalizeOK(t, first)
	if err := TeardownIssueWorktree(issueRoot, worktreeTestLogger()); err != nil {
		t.Fatalf("TeardownIssueWorktree: %v", err)
	}

	second := mustPrepareShared(t, repo, issueRoot, "agent-b", turnTwoTask, "WI00999999 Renamed")
	if second.Branch != "JWU/WI00123456" {
		t.Errorf("branch = %q, want the branch the issue already has", second.Branch)
	}
	if !second.Continued {
		t.Error("second run did not continue the issue's branch")
	}
}

func TestSharedIssueWorktreeRefusesToForkABusyBranch(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")

	first := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	writeFile(t, filepath.Join(first.WorkDir, "work.txt"), "work\n")
	finalizeOK(t, first)
	if err := TeardownIssueWorktree(issueRoot, worktreeTestLogger()); err != nil {
		t.Fatalf("TeardownIssueWorktree: %v", err)
	}
	gitRun(t, repo, "worktree", "add", "--quiet", filepath.Join(t.TempDir(), "elsewhere"), "JWU/WI00123456")

	_, err := prepareSharedRun(t, repo, issueRoot, "agent-b", turnTwoTask, workItemTitle)
	if err == nil || !strings.Contains(err.Error(), "checked out elsewhere") {
		t.Fatalf("err = %v, want a refusal naming the busy branch", err)
	}
	if forks := gitRun(t, repo, "branch", "--list", "JWU/WI00123456-*"); forks != "" {
		t.Errorf("a fork branch was created: %q", forks)
	}
}

func TestSharedIssueWorktreeCommitsWorkAnInterruptedRunLeft(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")

	first := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	writeFile(t, filepath.Join(first.WorkDir, "half-done.txt"), "interrupted\n")
	// No Finalize: the daemon died mid-run.

	second := mustPrepareShared(t, repo, issueRoot, "agent-b", turnTwoTask, workItemTitle)
	if !second.Reused {
		t.Fatal("second run did not reuse the worktree")
	}
	if got := gitRun(t, repo, "show", second.Branch+":half-done.txt"); got != "interrupted" {
		t.Errorf("interrupted run's work not committed: %q", got)
	}
	if dirty, err := worktreeIsDirty(second.Path); err != nil || dirty {
		t.Errorf("worktree dirty after reuse (dirty=%v, err=%v)", dirty, err)
	}
}

func TestSharedIssueWorktreeHandsAnOpenMergeToTheNextRun(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")
	writeFile(t, filepath.Join(repo, "tracked.txt"), "A\n")

	first := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	writeFile(t, filepath.Join(first.WorkDir, "tracked.txt"), "B\n")
	finalizeOK(t, first)

	writeFile(t, filepath.Join(repo, "tracked.txt"), "C\n")
	second := mustPrepareShared(t, repo, issueRoot, "agent-b", turnTwoTask, workItemTitle)
	if len(second.ReplayConflicts) == 0 {
		t.Fatal("no conflict between the agent's B and the user's C")
	}
	if _, err := second.Finalize(worktreeTestLogger()); err == nil {
		t.Fatal("Finalize delivered an open merge")
	}

	third := mustPrepareShared(t, repo, issueRoot, "agent-a", turnThreeTask, workItemTitle)
	if !third.Reused || len(third.ReplayConflicts) != 1 || third.ReplayConflicts[0] != "tracked.txt" {
		t.Fatalf("third run: reused=%v conflicts=%v; want the open merge handed over", third.Reused, third.ReplayConflicts)
	}
	writeFile(t, filepath.Join(third.WorkDir, "tracked.txt"), "B and C\n")
	gitRun(t, third.Path, "add", "tracked.txt")
	finalizeOK(t, third)
	if got := gitRun(t, repo, "show", third.Branch+":tracked.txt"); got != "B and C" {
		t.Errorf("branch content = %q, want the resolution", got)
	}

	// The resolution recorded the user's C, so it is not offered again.
	fourth := mustPrepareShared(t, repo, issueRoot, "agent-b", "11112222-3333-4444-5555-dddddddddddd", workItemTitle)
	if len(fourth.ReplayConflicts) != 0 {
		t.Errorf("resolved edit replayed again: %v", fourth.ReplayConflicts)
	}
}

func TestSharedIssueWorktreeKeepsAReadOnlyFirstRun(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")

	first := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	if outcome := finalizeOK(t, first); outcome.Branch != "JWU/WI00123456" {
		t.Errorf("read-only run reported branch %q, want the issue's branch", outcome.Branch)
	}
	if _, err := os.Stat(first.Path); err != nil {
		t.Errorf("worktree of a read-only first run removed: %v", err)
	}
	if extra := gitRun(t, repo, "rev-list", "main..JWU/WI00123456"); extra != "" {
		t.Errorf("read-only run left commits on the shared branch: %s", extra)
	}
	second := mustPrepareShared(t, repo, issueRoot, "agent-b", turnTwoTask, workItemTitle)
	if !second.Reused || second.Branch != "JWU/WI00123456" {
		t.Errorf("second run: reused=%v branch=%q; want the kept worktree", second.Reused, second.Branch)
	}
}

// A branch with nothing beyond the user's HEAD restarts at their newer HEAD in
// the same worktree, with no empty commit and no fresh checkout.
func TestSharedIssueWorktreeFollowsTheUserHeadWhileTheBranchIsEmpty(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")

	first := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	finalizeOK(t, first)
	marker := filepath.Join(first.Path, ".git")
	before, err := os.Stat(marker)
	if err != nil {
		t.Fatal(err)
	}

	writeFile(t, filepath.Join(repo, "upstream.txt"), "new on main\n")
	gitRun(t, repo, "add", "-A")
	gitRun(t, repo, "commit", "-m", "user moves on")
	head := gitRun(t, repo, "rev-parse", "HEAD")

	second := mustPrepareShared(t, repo, issueRoot, "agent-b", turnTwoTask, workItemTitle)
	if !second.Reused {
		t.Fatal("worktree was rebuilt instead of reused")
	}
	if after, err := os.Stat(marker); err != nil || !os.SameFile(before, after) {
		t.Errorf("worktree was checked out again (err=%v)", err)
	}
	if got := gitRun(t, repo, "rev-parse", "JWU/WI00123456"); got != head {
		t.Errorf("branch at %s, want the user's HEAD %s with no commit of its own", got, head)
	}
	if _, err := os.Stat(filepath.Join(second.WorkDir, "upstream.txt")); err != nil {
		t.Errorf("worktree does not carry the user's new commit: %v", err)
	}
	finalizeOK(t, second)
	if extra := gitRun(t, repo, "rev-list", "main..JWU/WI00123456"); extra != "" {
		t.Errorf("empty commits on the shared branch: %s", extra)
	}
}

func TestTeardownIssueWorktreeDropsABranchWithoutWork(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")

	wt := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	finalizeOK(t, wt)
	if err := TeardownIssueWorktree(issueRoot, worktreeTestLogger()); err != nil {
		t.Fatalf("TeardownIssueWorktree: %v", err)
	}
	if _, err := gitTry(t, repo, "rev-parse", "--verify", wt.Branch); err == nil {
		t.Errorf("branch %s without work survived teardown", wt.Branch)
	}
}

// Windows can leave the directory behind, empty and unregistered, when a
// removal races a process still inside it. That must not wedge the issue.
func TestSharedIssueWorktreeReplacesAnEmptyLeftoverDirectory(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")
	if err := os.MkdirAll(filepath.Join(issueRoot, localWorktreeDirName), 0o755); err != nil {
		t.Fatal(err)
	}

	wt := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	if wt.Reused {
		t.Error("an empty leftover directory was treated as a reusable worktree")
	}
	if _, err := os.Stat(filepath.Join(wt.Path, "tracked.txt")); err != nil {
		t.Errorf("fresh worktree not checked out: %v", err)
	}
}

func TestTeardownIssueWorktreeCommitsAndRemoves(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	issueRoot := filepath.Join(t.TempDir(), "issue")

	wt := mustPrepareShared(t, repo, issueRoot, "agent-a", turnOneTask, workItemTitle)
	writeFile(t, filepath.Join(wt.WorkDir, "late.txt"), "late work\n")

	if err := TeardownIssueWorktree(issueRoot, worktreeTestLogger()); err != nil {
		t.Fatalf("TeardownIssueWorktree: %v", err)
	}
	if _, err := os.Stat(issueRoot); !os.IsNotExist(err) {
		t.Errorf("issue root survived teardown: %v", err)
	}
	if list := gitRun(t, repo, "worktree", "list"); strings.Contains(list, wt.Path) {
		t.Errorf("worktree still registered:\n%s", list)
	}
	if got := gitRun(t, repo, "show", wt.Branch+":late.txt"); got != "late work" {
		t.Errorf("uncommitted work lost on teardown: %q", got)
	}
}

// A run that dies after Prepare leaves its runtime files in the shared
// worktree. The next run, by another agent and provider, must not commit them
// or read them as its own.
func TestSharedIssueWorktreeRemovesAnInterruptedRunsSidecars(t *testing.T) {
	repo := newTestRepo(t)
	workspacesRoot := t.TempDir()
	issueRoot := filepath.Join(t.TempDir(), "issue")
	t.Setenv("CODEX_HOME", t.TempDir())

	prepare := func(taskID, agentID, provider string) *Environment {
		t.Helper()
		taskCtx := TaskContextForEnv{IssueID: "issue-1", AgentID: agentID, AgentName: agentID}
		env, err := Prepare(PrepareParams{
			WorkspacesRoot: workspacesRoot,
			WorkspaceID:    "ws-1",
			TaskID:         taskID,
			AgentName:      agentID,
			Provider:       provider,
			LocalWorktree: &LocalWorktreeParams{
				LocalPath:         repo,
				IssueWorktreeRoot: issueRoot,
				BranchPrefix:      "JWU",
			},
			Task: taskCtx,
		}, worktreeTestLogger())
		if err != nil {
			t.Fatalf("Prepare(%s): %v", taskID, err)
		}
		// The daemon injects the runtime brief right after Prepare.
		if _, err := InjectRuntimeConfig(env.WorkDir, provider, taskCtx); err != nil {
			t.Fatalf("InjectRuntimeConfig(%s): %v", provider, err)
		}
		return env
	}

	first := prepare(turnOneTask, "agent-a", "claude")
	if _, err := os.Stat(filepath.Join(first.WorkDir, "CLAUDE.md")); err != nil {
		t.Fatalf("precondition: first run wrote no CLAUDE.md: %v", err)
	}
	writeFile(t, filepath.Join(first.WorkDir, "work.txt"), "work\n")
	// The first run dies here: no sidecar cleanup, no Finalize.

	second := prepare(turnTwoTask, "agent-b", "codex")
	if second.WorkDir != first.WorkDir {
		t.Fatalf("second run got %q, want the shared worktree %q", second.WorkDir, first.WorkDir)
	}
	if _, err := os.Stat(filepath.Join(second.WorkDir, "CLAUDE.md")); !os.IsNotExist(err) {
		t.Errorf("the interrupted run's CLAUDE.md survived: %v", err)
	}
	if err := CleanupRuntimeConfig(second.WorkDir, "codex"); err != nil {
		t.Fatalf("CleanupRuntimeConfig: %v", err)
	}
	if err := CleanupSidecars(second.RootDir); err != nil {
		t.Fatalf("CleanupSidecars: %v", err)
	}
	outcome, err := second.LocalWorktree.Finalize(worktreeTestLogger())
	if err != nil {
		t.Fatalf("Finalize: %v", err)
	}
	files := gitRun(t, repo, "ls-tree", "-r", "--name-only", outcome.Branch)
	for _, name := range strings.Split(files, "\n") {
		if name != "tracked.txt" && name != "keep.txt" && name != "work.txt" {
			t.Errorf("branch carries runtime file %q", name)
		}
	}
}

func TestIssueWorktreeRootIsNamedAfterTheIssue(t *testing.T) {
	t.Parallel()
	repo := newTestRepo(t)
	workspacesRoot := t.TempDir()
	params := IssueWorktreeRootParams{
		WorkspacesRoot: workspacesRoot, WorkspaceID: "ws-1", IssueID: "issue-1", IssueKey: "WTG-61",
		IssueTitle: "Test WI00001001", WorkItemPattern: DefaultWorkItemPattern, LocalPath: repo,
	}
	dir := filepath.Join(workspacesRoot, issueWorktreesDirName)

	root, err := IssueWorktreeRoot(params)
	if err != nil {
		t.Fatalf("IssueWorktreeRoot: %v", err)
	}
	if want := filepath.Join(dir, "WTG-61-WI00001001"); root != want {
		t.Fatalf("root = %q, want %q", root, want)
	}
	noItem := params
	noItem.IssueTitle = "No work item"
	if got, _ := IssueWorktreeRoot(noItem); got != filepath.Join(dir, "WTG-61") {
		t.Errorf("without a work item: %q, want WTG-61", got)
	}

	// Once recorded, the issue keeps its directory whatever the title says.
	gitRoot, _ := resolveGitRoot(repo)
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writeIssueWorktreeMeta(root, IssueWorktreeMeta{WorkspaceID: "ws-1", IssueID: "issue-1", GitRoot: gitRoot}); err != nil {
		t.Fatal(err)
	}
	renamed := params
	renamed.IssueTitle = "WI00009999 renamed"
	if got, _ := IssueWorktreeRoot(renamed); got != root {
		t.Errorf("after a title edit: %q, want the recorded %q", got, root)
	}

	// Another workspace minting the same key and work item gets its own directory.
	other := params
	other.WorkspaceID = "ws-2"
	got, _ := IssueWorktreeRoot(other)
	if got == root || !strings.HasPrefix(filepath.Base(got), "WTG-61-WI00001001-") {
		t.Errorf("colliding issue got %q, want a suffixed sibling of %q", got, root)
	}
}

func TestValidateBranchPrefix(t *testing.T) {
	t.Parallel()
	for prefix, ok := range map[string]bool{
		"JWU": true, "team/JWU": true, "j.wu": true, "j_wu-2": true,
		"": false, "-x": false, "a..b": false, "a/": false, "/a": false,
		"x.lock": false, "a b": false, "a.": false, ".a": false, "a//b": false,
	} {
		if err := ValidateBranchPrefix(prefix); (err == nil) != ok {
			t.Errorf("ValidateBranchPrefix(%q) err = %v, want ok=%v", prefix, err, ok)
		}
	}
}
