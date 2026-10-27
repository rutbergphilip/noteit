<script setup lang="ts">
import { computed, ref, watch, type VNode } from 'vue';
import type { CommandPaletteGroup, CommandPaletteItem } from '@nuxt/ui';
import { useNoteit } from '~/composables/useNoteit';
import { webCommands } from '~/utils/commands';
import { notebookIcon } from '~/utils/notebooks';
import { parsePaletteQuery, rankPalette, type PaletteRow } from '~/utils/paletteRank';
import { comboKbds } from '~/utils/shortcuts';
import { useOpeningKey } from '~/utils/overlay';

const { state, client, tags, createNote, setTheme } = useNoteit();
const query = ref('');
/** Notes the search language finds by their text; ranked after title matches, as on the Mac. */
const bodyMatches = ref(new Set<string>());
const searching = ref(false);

// Note search runs in the worker over decrypted text (nothing leaves the device); the palette only ranks it.
let seq = 0;
async function update(): Promise<void> {
  const { mode, text } = parsePaletteQuery(query.value);
  const mine = ++seq;
  if (mode === 'commands' || !text) {
    bodyMatches.value = new Set();
    return;
  }
  searching.value = true;
  const ids = new Set(await client().search(text));
  if (mine !== seq) return;
  searching.value = false;
  bodyMatches.value = ids;
}
watch(query, () => void update());
watch(
  () => state.palette,
  (open) => {
    if (!open) return;
    query.value = state.query;
    void update();
  },
  { immediate: true },
);

const close = () => (state.palette = false);
function openNote(id: string): void {
  close();
  state.selectedId = id;
  state.pane = 'editor';
}

const commands = computed(() => {
  const list = webCommands()
    .filter((c) => c.available())
    .map((c) => ({ id: c.id, title: c.title, keywords: c.keywords, icon: c.icon, kbds: c.keys?.[0] ? comboKbds(c.keys[0]) : undefined, run: () => void c.run() }));
  const dark = state.theme === 'dark';
  list.push({ id: 'theme', title: dark ? 'Switch to Light Mode' : 'Switch to Dark Mode', keywords: ['appearance', 'theme'], icon: dark ? 'i-lucide-sun' : 'i-lucide-moon', kbds: undefined, run: () => {
    close();
    setTheme(dark ? 'light' : 'dark');
  } });
  return list;
});

function item(r: PaletteRow): CommandPaletteItem {
  switch (r.kind) {
    case 'note': {
      const row = state.notes.find((n) => n.id === r.id);
      const nb = state.notebooks.find((n) => n.id === row?.notebookID);
      return { id: r.key, label: r.title, description: r.subtitle, icon: row?.isPinned ? 'i-lucide-pin' : nb ? notebookIcon(nb.symbol) : 'i-lucide-file-text', onSelect: () => openNote(r.id) };
    }
    case 'notebook': {
      const nb = state.notebooks.find((n) => n.id === r.id);
      return { id: r.key, label: r.title, description: r.subtitle, icon: notebookIcon(nb?.symbol), onSelect: () => (close(), (state.view = { kind: 'notebook', id: r.id }), (state.pane = 'list')) };
    }
    case 'smartFolder':
      return { id: r.key, label: r.title, description: r.subtitle, icon: 'i-lucide-folder-search', onSelect: () => (close(), (state.view = { kind: 'smartFolder', id: r.id }), (state.pane = 'list')) };
    case 'tag':
      return { id: r.key, label: r.title, description: r.subtitle, icon: 'i-lucide-hash', onSelect: () => (close(), (state.view = { kind: 'tag', tag: r.path }), (state.pane = 'list')) };
    case 'command': {
      const c = commands.value.find((x) => x.id === r.id)!;
      return { id: r.key, label: r.title, icon: c.icon, ...(c.kbds ? { kbds: c.kbds } : {}), onSelect: c.run };
    }
    case 'create':
      return {
        id: r.key,
        label: `New Note “${r.title}”`,
        icon: 'i-lucide-file-plus',
        onSelect: () => {
          close();
          void createNote({ format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content: [{ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: r.title }] }, { type: 'paragraph' }] } });
        },
      };
  }
}

const groups = computed<CommandPaletteGroup<CommandPaletteItem>[]>(() => {
  const { mode, text } = parsePaletteQuery(query.value);
  const rows = rankPalette({
    query: query.value,
    notes: state.notes.filter((n) => !n.deletedAt),
    notebooks: state.notebooks,
    commands: commands.value,
    bodyMatches: bodyMatches.value,
    smartFolders: state.smartFolders,
    tags: tags.value.map((t) => ({ path: t.tag, count: t.count })),
  });
  const label = mode === 'commands' ? 'Commands' : text ? undefined : 'Recent notes';
  return [{ id: 'results', ...(label ? { label } : {}), ignoreFilter: true, items: rows.map(item) }];
});
/**
 * Names the results listbox for assistive tech. Nuxt UI's CommandPalette renders reka's ListboxContent without a
 * name and passes no attributes to it (its `ui` slots take classes only), so the name is set on mount.
 */
function nameResults(vnode: VNode): void {
  // The palette renders a fragment, so its vnode's element is an anchor inside the modal's content.
  (vnode.el as Node | null)?.parentElement?.querySelector('[role="listbox"]')?.setAttribute('aria-label', 'Notes and commands');
}
// A fresh portal per opening, so it shows above the sidebar drawer (see useOpeningKey).
const portalKey = useOpeningKey(() => state.palette);
</script>

<template>
  <!-- design p03 -->
  <UModal :key="portalKey" v-model:open="state.palette" title="Search notes and commands" description="Search runs on this device; nothing leaves it." :ui="{ content: 'sm:max-w-[640px] top-[12dvh] translate-y-0 sm:top-24' }">
    <template #content>
      <UCommandPalette
        v-model:search-term="query"
        :groups="groups"
        :loading="searching"
        placeholder="Search notes and commands"
        :close="{ color: 'neutral', variant: 'ghost' }"
        class="max-h-[min(520px,70dvh)]"
        :ui="{ input: '[&>input]:text-[17px]', itemDescription: 'line-clamp-1', footer: 'p-0' }"
        @update:open="(v: boolean) => !v && close()"
        @vue:mounted="nameResults"
      >
        <template #footer>
          <div class="flex flex-wrap items-center gap-4 border-t border-default px-4 py-2.5 text-xs text-muted">
            <span class="flex items-center gap-1"><UKbd value="arrowup" /><UKbd value="arrowdown" /> to move</span>
            <span class="flex items-center gap-1"><UKbd value="enter" /> to open</span>
            <span class="flex items-center gap-1"><UKbd value="escape" /> to close</span>
            <span class="ms-auto max-sm:hidden">Search runs on this device; nothing leaves it</span>
          </div>
        </template>
      </UCommandPalette>
    </template>
  </UModal>
</template>
