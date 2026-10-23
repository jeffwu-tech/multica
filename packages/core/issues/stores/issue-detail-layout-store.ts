import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { defaultStorage } from "../../platform/storage";

interface IssueDetailLayoutState {
  /** Let the full-page issue column fill the available width instead of the reading cap. */
  wideContent: boolean;
  toggleWideContent: () => void;
}

// A personal reading preference shared by every issue on this device, like
// the sub-issue display and comment composer preferences.
export const useIssueDetailLayoutStore = create<IssueDetailLayoutState>()(
  persist(
    (set) => ({
      wideContent: false,
      toggleWideContent: () => set((s) => ({ wideContent: !s.wideContent })),
    }),
    {
      name: "multica_issue_detail_layout",
      storage: createJSONStorage(() => defaultStorage),
      partialize: ({ wideContent }) => ({ wideContent }),
      merge: (persisted, current) => ({
        ...current,
        wideContent:
          !!persisted && typeof persisted === "object" &&
          "wideContent" in persisted && persisted.wideContent === true,
      }),
    },
  ),
);
