import { onBeforeUnmount, ref } from 'vue';
import type { BodyContainer } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

/** Settings › General › When a note is renamed (native `linkRenameUpdates`); kept per browser, as the Mac keeps its own. */
export type LinkRenameMode = 'ask' | 'always' | 'never';
const KEY = 'linkRenameUpdates';

export function linkRenameMode(): LinkRenameMode {
  try {
    const v = localStorage.getItem(KEY);
    return v === 'always' || v === 'never' ? v : 'ask';
  } catch {
    return 'ask';
  }
}

export function setLinkRenameMode(mode: LinkRenameMode): void {
  try {
    if (mode === 'ask') localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, mode);
  } catch {
    // Private windows may refuse storage; the default stays.
  }
}

/** "Updated 2 links. 1 note couldn't be changed." (native RenameTracker.message) */
export function linkRewriteMessage(updated: number, skipped: number): string {
  let text = updated === 1 ? 'Updated 1 link.' : `Updated ${updated} links.`;
  if (skipped === 1) text += " 1 note couldn't be changed.";
  else if (skipped > 1) text += ` ${skipped} notes couldn't be changed.`;
  return text;
}

export interface RenamePrompt {
  oldTitle: string;
  newTitle: string;
  noteCount: number;
}

/**
 * Native RenameTracker for the open note: after its title is edited here and left alone for 2 seconds, offers to
 * update the text of links to it that still read the old title (or does it, or doesn't, per the setting). Titles
 * changed any other way (sync, another tab) only move the baseline. `self` counts and rewrites the open note's own
 * links in the editor, so they don't race its pending save.
 */
export function useRenameTracker(noteId: () => string, self: { count: (oldTitle: string) => number; rewrite: (oldTitle: string, newTitle: string) => number }) {
  const { client } = useNoteit();
  const prompt = ref<RenamePrompt>();
  const outcome = ref<{ message: string; undo?: { id: string; revision: string; before: BodyContainer }[] }>();
  const updating = ref(false);
  let baseline = '';
  let latest = '';
  let waitTimer: ReturnType<typeof setTimeout> | undefined;
  let outcomeTimer: ReturnType<typeof setTimeout> | undefined;

  /** The note was (re)loaded: its title is the baseline. */
  function observed(title: string): void {
    if (title === latest) return;
    if (waitTimer) clearTimeout(waitTimer);
    prompt.value = undefined;
    baseline = latest = title;
  }

  /** The title as typed in the editor. */
  function changed(title: string): void {
    if (title === latest) return;
    latest = title;
    prompt.value = undefined;
    if (waitTimer) clearTimeout(waitTimer);
    if (title === baseline) return;
    waitTimer = setTimeout(() => void settled(), 2000);
  }

  async function settled(): Promise<void> {
    const old = baseline;
    const next = latest;
    const mode = linkRenameMode();
    const others = mode === 'never' || !next.trim() ? [] : await client().linkRenameCandidates(noteId(), old, noteId());
    const count = others.length + (mode !== 'never' && next.trim() && self.count(old) > 0 ? 1 : 0);
    if (latest !== next) return;
    if (!count) {
      baseline = next;
      return;
    }
    const p = { oldTitle: old, newTitle: next, noteCount: count };
    if (mode === 'always') await update(p, true);
    else prompt.value = p;
  }

  async function update(p = prompt.value, confirmation = false): Promise<void> {
    if (!p) return;
    prompt.value = undefined;
    updating.value = true;
    try {
      const own = self.rewrite(p.oldTitle, p.newTitle);
      const r = await client().rewriteLinkText(noteId(), p.oldTitle, p.newTitle, noteId());
      baseline = p.newTitle;
      show({ message: linkRewriteMessage(r.updated + own, r.skipped), ...(r.notes.length ? { undo: r.notes } : {}) }, confirmation ? 3000 : 10_000);
    } finally {
      updating.value = false;
    }
  }

  function notNow(): void {
    if (!prompt.value) return;
    baseline = prompt.value.newTitle;
    prompt.value = undefined;
  }

  /** Puts back the other notes' links (the open note's own change is undone with ⌘Z). */
  async function undo(): Promise<void> {
    const notes = outcome.value?.undo;
    if (!notes) return;
    const leftAlone = await client().undoLinkRewrite(notes);
    baseline = latest;
    show({ message: leftAlone === 0 ? 'Links restored.' : leftAlone === 1 ? '1 note was edited since and was left as it is.' : `${leftAlone} notes were edited since and were left as they are.` }, 4000);
  }

  function dismiss(): void {
    if (outcomeTimer) clearTimeout(outcomeTimer);
    outcome.value = undefined;
  }

  function show(o: NonNullable<typeof outcome.value>, ms: number): void {
    outcome.value = o;
    if (outcomeTimer) clearTimeout(outcomeTimer);
    outcomeTimer = setTimeout(() => (outcome.value = undefined), ms);
  }

  onBeforeUnmount(() => {
    if (waitTimer) clearTimeout(waitTimer);
    if (outcomeTimer) clearTimeout(outcomeTimer);
  });

  return { prompt, outcome, updating, observed, changed, update: () => update(), notNow, undo, dismiss };
}
