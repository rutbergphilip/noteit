<script setup lang="ts">
import { formatDateTime } from '~/utils/format';
import { computed, ref, watch } from 'vue';
import { type NoteItDoc, noteStatistics, outline, readingTimeText, searchableText } from '@noteit/doc';
import { useNoteit, type InspectorTab } from '~/composables/useNoteit';

// Native's Links and Outline panel (⌥⌘I) with its Info tab (⌃⌘I): backlinks with a line of context, the links in
// this note, its headings, and word count, characters, reading time, dates, notebook and tags.
const props = defineProps<{ noteId: string; doc?: NoteItDoc }>();
const emit = defineEmits<{ jump: [block: number] }>();
const { state, client, openNote, createNote } = useNoteit();

const row = computed(() => state.notes.find((n) => n.id === props.noteId));
const links = ref<Awaited<ReturnType<ReturnType<typeof client>['links']>>>({ backlinks: [], outgoing: [] });
async function loadLinks(): Promise<void> {
  links.value = await client().links(props.noteId);
}
watch(() => [props.noteId, row.value?.updatedAt, state.notes.length], () => void loadLinks(), { immediate: true });

const headings = computed(() => (props.doc ? outline(props.doc) : []));
const stats = computed(() => noteStatistics(props.doc ? searchableText(props.doc) : ''));
const notebook = computed(() => state.notebooks.find((n) => n.id === row.value?.notebookID));
const when = (iso?: string) => formatDateTime(iso);
const number = (n: number) => n.toLocaleString();

const tabs = [
  { label: 'Links', value: 'links', icon: 'i-lucide-link-2' },
  { label: 'Outline', value: 'outline', icon: 'i-lucide-list-tree' },
  { label: 'Info', value: 'info', icon: 'i-lucide-info' },
];
const tab = computed({ get: () => state.inspector.tab, set: (v: InspectorTab) => (state.inspector.tab = v) });

async function follow(l: { id?: string; title: string; exists: boolean }): Promise<void> {
  if (l.id && l.exists) return openNote(l.id);
  // A link to a note that doesn't exist yet creates it, as on the Mac.
  await createNote({ format: 'noteit-doc', version: 1, attachments: {}, doc: { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: l.title }] }, { type: 'paragraph' }] } });
}
</script>

<template>
  <aside class="flex h-full w-full flex-col gap-3 overflow-y-auto p-4" aria-label="Links and Outline">
    <div class="flex items-center gap-2">
      <UTabs v-model="tab" :items="tabs" :content="false" size="xs" variant="pill" class="flex-1" />
      <UButton color="neutral" variant="ghost" size="sm" icon="i-lucide-x" aria-label="Close Links and Outline" @click="state.inspector.open = false" />
    </div>

    <template v-if="tab === 'links'">
      <section>
        <h3 class="mb-1 text-[11px] font-semibold text-muted">Backlinks</h3>
        <p v-if="!links.backlinks.length" class="text-[13px] text-muted">No notes link here yet. Link this note from another one with a <code>noteit://note</code> link.</p>
        <ul class="flex flex-col gap-1">
          <li v-for="b in links.backlinks" :key="b.id">
            <button type="button" class="w-full cursor-pointer rounded-md px-2 py-1.5 text-left hover:bg-(--fill)" @click="openNote(b.id)">
              <span class="block truncate text-sm font-medium">{{ b.title || 'Untitled' }}</span>
              <span class="line-clamp-2 text-xs text-muted">{{ b.context }}</span>
            </button>
          </li>
        </ul>
      </section>
      <section>
        <h3 class="mb-1 text-[11px] font-semibold text-muted">Links in this note</h3>
        <p v-if="!links.outgoing.length" class="text-[13px] text-muted">This note doesn't link to other notes.</p>
        <ul class="flex flex-col gap-1">
          <li v-for="(l, i) in links.outgoing" :key="l.id ?? `${l.title}-${i}`">
            <button type="button" class="flex w-full cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm hover:bg-(--fill)" @click="follow(l)">
              <UIcon :name="l.exists ? 'i-lucide-file-text' : 'i-lucide-file-plus'" class="size-4 shrink-0 text-muted" />
              <span class="truncate" :class="!l.exists && 'text-muted italic'">{{ l.title || 'Untitled' }}</span>
            </button>
          </li>
        </ul>
      </section>
    </template>

    <template v-else-if="tab === 'outline'">
      <p v-if="!headings.length" class="text-[13px] text-muted">No headings. Titles, headings and subheadings (⌥⌘1–3) show here.</p>
      <ul class="flex flex-col">
        <li v-for="h in headings" :key="h.block">
          <button type="button" class="w-full cursor-pointer truncate rounded-md py-1 pe-2 text-left text-sm hover:bg-(--fill)" :style="{ paddingInlineStart: `${8 + (h.level - 1) * 14}px` }" :class="h.level === 1 && 'font-semibold'" @click="emit('jump', h.block)">
            {{ h.text }}
          </button>
        </li>
      </ul>
    </template>

    <dl v-else class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
      <dt class="text-muted">Words</dt>
      <dd class="tabular-nums">{{ number(stats.words) }}</dd>
      <dt class="text-muted">Characters</dt>
      <dd class="tabular-nums">{{ number(stats.characters) }}</dd>
      <dt class="text-muted">Reading time</dt>
      <dd>{{ readingTimeText(stats) }}</dd>
      <dt class="text-muted">Created</dt>
      <dd>{{ when(row?.createdAt) }}</dd>
      <dt class="text-muted">Edited</dt>
      <dd>{{ when(row?.updatedAt) }}</dd>
      <dt class="text-muted">Notebook</dt>
      <dd class="truncate">{{ notebook?.name || 'None' }}</dd>
      <dt class="text-muted">Tags</dt>
      <dd class="flex flex-wrap gap-1">
        <span v-if="!row?.tags.length" class="text-muted">None</span>
        <UBadge v-for="t in row?.tags ?? []" :key="t" color="neutral" variant="soft" size="sm" class="rounded-full" :label="`#${t}`" />
      </dd>
    </dl>
  </aside>
</template>
