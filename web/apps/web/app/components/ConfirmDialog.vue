<script setup lang="ts">
import { computed, ref } from 'vue';

/** A confirmation opened through useConfirm(); resolves true only on the confirm button. */
const props = defineProps<{
  title: string;
  description?: string;
  confirmLabel?: string;
  danger?: boolean;
  /** When set, the button stays disabled until this exact text is typed (destructive admin actions). */
  typeToConfirm?: string;
  /** Cancel takes the focus (Return), as for the Mac's destructive alerts. */
  cancelDefault?: boolean;
}>();
const emit = defineEmits<{ close: [boolean] }>();
const typed = ref('');
const ready = computed(() => !props.typeToConfirm || typed.value === props.typeToConfirm);
</script>

<template>
  <UModal :title="title" :description="description" :close="false" :ui="{ footer: 'justify-end' }" @update:open="(open: boolean) => !open && emit('close', false)">
    <template v-if="typeToConfirm" #body>
      <UFormField :label="`Type ${typeToConfirm} to confirm`">
        <UInput v-model="typed" autofocus autocomplete="off" spellcheck="false" @keydown.enter="ready && emit('close', true)" />
      </UFormField>
    </template>
    <template #footer>
      <UButton color="neutral" variant="ghost" label="Cancel" :autofocus="cancelDefault" @click="emit('close', false)" />
      <UButton :color="danger ? 'error' : 'primary'" :label="confirmLabel ?? 'OK'" :disabled="!ready" :autofocus="!cancelDefault" @click="emit('close', true)" />
    </template>
  </UModal>
</template>
