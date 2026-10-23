// @vitest-environment node
import { beforeEach, describe, expect, it, vi } from "vitest";

const storage = vi.hoisted(() => new Map<string, string>());
vi.mock("../../platform/storage", () => ({
  defaultStorage: {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => storage.set(key, value),
    removeItem: (key: string) => storage.delete(key),
  },
}));

import { useIssueDetailLayoutStore } from "./issue-detail-layout-store";

beforeEach(() => {
  storage.clear();
  useIssueDetailLayoutStore.setState({ wideContent: false });
});

describe("issue detail layout preference", () => {
  it("restores the wide layout on rehydration", async () => {
    useIssueDetailLayoutStore.getState().toggleWideContent();
    const saved = storage.get("multica_issue_detail_layout")!;
    expect(JSON.parse(saved).state).toEqual({ wideContent: true });
    useIssueDetailLayoutStore.getState().toggleWideContent();
    storage.set("multica_issue_detail_layout", saved);
    await useIssueDetailLayoutStore.persist.rehydrate();
    expect(useIssueDetailLayoutStore.getState().wideContent).toBe(true);
  });

  it.each([null, {}, { wideContent: "yes" }])(
    "defaults to the standard width for missing or invalid preferences: %j",
    async (state) => {
      useIssueDetailLayoutStore.setState({ wideContent: true });
      storage.set("multica_issue_detail_layout", JSON.stringify({ state, version: 0 }));
      await useIssueDetailLayoutStore.persist.rehydrate();
      expect(useIssueDetailLayoutStore.getState().wideContent).toBe(false);
    },
  );
});
