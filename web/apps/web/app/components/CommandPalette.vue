<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import type { CommandPaletteGroup, CommandPaletteItem } from '@nuxt/ui';
import { searchFold } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';
import { webCommands } from '~/utils/commands';
import { notebookIcon } from '~/utils/notebooks';
import { comboKbds } from '~/utils/shortcuts';
import type { NoteRow } from '~/worker/types';

const { state, client, tags, createNote, setTheme } = useNoteit();
const query = ref('');
const hits = ref<NoteRow[]>([]);
const searching = ref(false);

// Note search runs in the worker over decrypted text (nothing leaves the device); the palette only lists it.
let seq = 0;
async function update(): Promise<void> {
  const q = query.value.trim();
  const mine = ++seq;
  if (q.startsWith('>')) return;
  if (!q) {
    hits.value = state.notes
      .filter((n) => !n.deletedAt)
      .sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt))
      .slice(0, 6);
    return;
  }
  searching.value = true;
  const ids = new Set(await client().search(q));
  if (mine !== seq) return;
  searching.value = false;
  hits.value = state.notes.filter((n) => ids.has(n.id)).slice(0, 8);
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

/** Splits a preview around the first folded match so the template can wrap it in <mark> (no HTML strings). */
function parts(text: string): { pre: string; hit: string; post: string } {
  const q = query.value.trim().split(/\s+/)[0] ?? '';
  const i = q ? searchFold(text).indexOf(searchFold(q)) : -1;
  if (i < 0) return { pre: text.slice(0, 110), hit: '', post: '' };
  const start = Math.max(0, i - 30);
  return { pre: (start > 0 ? '…' : '') + text.slice(start, i), hit: text.slice(i, i + q.length), post: text.slice(i + q.length, i + q.length + 80) };
}

const groups = computed<CommandPaletteGroup<CommandPaletteItem>[]>(() => {
  const q = query.value.trim();
  if (!q.startsWith('>')) return allGroups.value;
  // `>` lists commands only (native ⇧⌘P), filtered here since the palette would search for the `>` too.
  const term = searchFold(q.slice(1).trim());
  const commands = allGroups.value.find((g) => g.id === 'commands')!;
  const items = (commands.items ?? []).filter((i) => !term || searchFold([i.label, ...((i.keywords as string[] | undefined) ?? [])].join(' ')).includes(term));
  return [{ ...commands, ignoreFilter: true, items }];
});

const allGroups = computed<CommandPaletteGroup<CommandPaletteItem>[]>(() => {
  const q = query.value.trim();
  const notebook = (n: NoteRow) => state.notebooks.find((nb) => nb.id === n.notebookID);
  const fq = searchFold(q.replace(/^#/, ''));
  return [
    {
      id: 'notes',
      label: q ? 'Notes' : 'Recent notes',
      slot: 'note',
      ignoreFilter: true,
      items: hits.value.map((n) => ({
        id: n.id,
        label: n.title || 'Untitled',
        preview: n.preview ? parts(n.preview) : undefined,
        icon: n.notebookID ? notebookIcon(notebook(n)?.symbol) : 'i-lucide-file-text',
        onSelect: () => openNote(n.id),
      })),
    },
    {
      id: 'tags',
      label: 'Tags',
      ignoreFilter: true,
      items: q
        ? tags.value
            .filter((t) => searchFold(t.tag).includes(fq))
            .slice(0, 4)
            .map((t) => ({
              label: `#${t.tag}`,
              icon: 'i-lucide-hash',
              suffix: `${t.count} ${t.count === 1 ? 'note' : 'notes'}`,
              onSelect: () => {
                close();
                state.view = { kind: 'tag', tag: t.tag };
                state.pane = 'list';
              },
            }))
        : [],
    },
    {
      id: 'new',
      ignoreFilter: true,
      items: [
        {
          label: q ? `New Note Titled “${q}”` : 'New Note',
          icon: 'i-lucide-file-plus',
          kbds: ['alt', 'meta', 'N'],
          onSelect: () => {
            close();
            void createNote(q ? { format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content: [{ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: q }] }, { type: 'paragraph' }] } } : undefined);
          },
        },
      ],
    },
    {
      id: 'commands',
      label: 'Commands',
      items: [
        ...webCommands()
          .filter((c) => c.available())
          .map((c) => ({ label: c.title, icon: c.icon, ...(c.keys?.[0] ? { kbds: comboKbds(c.keys[0]) } : {}), keywords: c.keywords, onSelect: () => void c.run() })),
        { label: state.theme === 'dark' ? 'Switch to Light Mode' : 'Switch to Dark Mode', icon: state.theme === 'dark' ? 'i-lucide-sun' : 'i-lucide-moon', onSelect: () => (close(), setTheme(state.theme === 'dark' ? 'light' : 'dark')) },
      ],
    },
  ];
});
</script>

<template>
  <!-- design p03 -->
  <UModal v-model:open="state.palette" title="Search notes and commands" description="Search runs on this device; nothing leaves it." :ui="{ content: 'sm:max-w-[640px] top-[12dvh] translate-y-0 sm:top-24' }">
    <template #content>
      <UCommandPalette
        v-model:search-term="query"
        :groups="groups"
        :loading="searching"
        placeholder="Search notes and commands"
        :close="{ color: 'neutral', variant: 'ghost' }"
        :fuse="{ resultLimit: 8 }"
        class="max-h-[min(520px,70dvh)]"
        :ui="{ input: '[&>input]:text-[17px]', itemDescription: 'line-clamp-1', footer: 'p-0' }"
        @update:open="(v: boolean) => !v && close()"
      >
        <template #note-description="{ item }">
          <template v-if="item.preview">{{ item.preview.pre }}<mark v-if="item.preview.hit" class="rounded-[3px] bg-(--mark) px-px text-inherit">{{ item.preview.hit }}</mark>{{ item.preview.post }}</template>
        </template>
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
