<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import type { CommandPaletteGroup, CommandPaletteItem } from '@nuxt/ui';
import { emptyContainer, templateDisplayName } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';
import { useOpeningKey } from '~/utils/overlay';

// Native's New Note from Template… (⌥⌘N on the Mac) and Edit › Insert Template…: templates are the notes in the
// "Templates" notebook, and their {{title}}, {{date}}, {{time}}, {{clipboard}} and {{cursor}} are filled in.
const { state, templates, newFromTemplate, newTemplate, expandedTemplate, createNote, toast } = useNoteit();
const query = ref('');
const open = computed({
  get: () => !!state.templatePicker,
  set: (v) => {
    if (!v) state.templatePicker = undefined;
  },
});
watch(open, (v) => v && (query.value = ''));

const sorted = computed(() =>
  [...templates.value].sort((a, b) => templateDisplayName(a.title).localeCompare(templateDisplayName(b.title), undefined, { numeric: true }) || a.createdAt.localeCompare(b.createdAt)),
);

async function choose(id: string): Promise<void> {
  const mode = state.templatePicker;
  state.templatePicker = undefined;
  if (mode === 'new') return newFromTemplate(id);
  const current = state.notes.find((n) => n.id === state.selectedId);
  const container = await expandedTemplate(id, current?.title ?? '');
  if (!container) return toast("This template can't be read here.", 'error');
  state.pendingInsert = container;
}

const groups = computed<CommandPaletteGroup<CommandPaletteItem>[]>(() => {
  const q = query.value.trim();
  const out: CommandPaletteGroup<CommandPaletteItem>[] = [
    { id: 'templates', label: 'Templates', items: sorted.value.map((t) => ({ label: templateDisplayName(t.title), icon: 'i-lucide-file-text', onSelect: () => void choose(t.id) })) },
  ];
  if (state.templatePicker === 'new' && q) {
    out.push({
      id: 'blank',
      ignoreFilter: true,
      items: [
        {
          label: `New Note “${q}”`,
          icon: 'i-lucide-file-plus',
          onSelect: () => {
            state.templatePicker = undefined;
            const c = emptyContainer();
            c.doc = { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: q }] }, { type: 'paragraph' }] };
            void createNote(c);
          },
        },
      ],
    });
  }
  return out;
});
// A fresh portal per opening, so it shows above the sidebar drawer (see useOpeningKey).
const portalKey = useOpeningKey(() => open.value);
</script>

<template>
  <UModal :key="portalKey" v-model:open="open" :title="state.templatePicker === 'insert' ? 'Insert Template' : 'New Note from Template'" description="Templates are the notes in your Templates notebook." :ui="{ content: 'sm:max-w-[520px] top-[14dvh] translate-y-0 sm:top-28' }">
    <template #content>
      <UCommandPalette v-model:search-term="query" :groups="groups" placeholder="Find a template" :close="{ color: 'neutral', variant: 'ghost' }" class="max-h-[min(440px,65dvh)]" @update:open="(v: boolean) => !v && (open = false)">
        <template #empty>
          <div class="flex flex-col items-center gap-3 px-6 py-8 text-center text-sm text-muted">
            <p v-if="!templates.length">No templates yet. A template is a note in the Templates notebook; <code v-pre>{{date}}</code> and <code v-pre>{{title}}</code> are filled in when you use it.</p>
            <p v-else>No template matches.</p>
            <UButton v-if="!templates.length" icon="i-lucide-file-plus-2" label="New Template" @click="(open = false), newTemplate()" />
          </div>
        </template>
      </UCommandPalette>
    </template>
  </UModal>
</template>
