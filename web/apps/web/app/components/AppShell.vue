<script setup lang="ts">
import { computed, ref } from 'vue';
import { useNoteit } from '~/composables/useNoteit';

const { state, createNote, setQuery, lock, signOut, setTheme } = useNoteit();
const accountOpen = ref(false);
const initials = computed(() => {
  const name = state.session?.user.displayName || state.session?.user.username || '?';
  return name
    .split(/\s+/)
    .map((p) => p[0])
    .join('')
    .slice(0, 2)
    .toUpperCase();
});
let searchTimer: ReturnType<typeof setTimeout> | undefined;
const search = ref(state.query);
function onSearch(): void {
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = setTimeout(() => void setQuery(search.value), 120);
}
</script>

<template>
  <!-- design p01 (desktop), p13 (tablet: sidebar as a drawer), p14 (phone: one pane at a time) -->
  <div class="app" :class="{ 'show-editor': state.pane === 'editor' }">
    <header class="hdr">
      <button type="button" class="icon-btn menu-btn" aria-label="Show notebooks and tags" @click="state.drawerOpen = true">
        <NiIcon name="menu" :size="20" :stroke="2" />
      </button>
      <a href="#" class="brand" aria-label="NoteIt home" @click.prevent="state.view = { kind: 'all' }; state.pane = 'list'">
        <img src="/noteit-icon.png" alt="" width="30" height="30" />
        <span class="brand-word ni-wordmark">Note<span>It</span></span>
      </a>
      <button type="button" class="icon-btn search-btn" aria-label="Search notes and commands" @click="state.palette = true">
        <NiIcon name="search" :size="18" />
      </button>
      <label class="search-field">
        <NiIcon name="search" :size="16" />
        <span class="sr-only">Search notes</span>
        <input v-model="search" type="search" placeholder="Search notes and commands" @input="onSearch" @keydown.enter.prevent="state.palette = true" />
        <kbd>⌘K</kbd>
      </label>
      <div class="right">
        <SyncPill />
        <button type="button" class="new-btn" aria-label="New note" @click="createNote()">
          <NiIcon name="plus" :size="16" :stroke="2" />
          <span class="new-label">New Note</span>
        </button>
        <button type="button" class="icon-btn settings-btn" aria-label="Settings" @click="state.settings = true">
          <NiIcon name="sliders" :size="18" />
        </button>
        <div class="account">
          <button type="button" class="avatar" aria-label="Account" :aria-expanded="accountOpen" @click="accountOpen = !accountOpen">{{ initials }}</button>
          <div v-if="accountOpen" class="menu" role="menu" @click="accountOpen = false">
            <div class="who">{{ state.session?.user.displayName }}<span>{{ state.session?.user.username }}</span></div>
            <button role="menuitem" type="button" @click="setTheme(state.theme === 'dark' ? 'light' : 'dark')">
              <NiIcon :name="state.theme === 'dark' ? 'sun' : 'moon'" :size="16" />{{ state.theme === 'dark' ? 'Light Mode' : 'Dark Mode' }}
            </button>
            <button role="menuitem" type="button" @click="state.capture = true"><NiIcon name="capture" :size="16" />Quick Capture</button>
            <button role="menuitem" type="button" @click="state.settings = true"><NiIcon name="sliders" :size="16" />Settings</button>
            <button role="menuitem" type="button" @click="lock()"><NiIcon name="lock" :size="16" />Lock</button>
            <button role="menuitem" type="button" @click="signOut()"><NiIcon name="back" :size="16" />Sign Out</button>
          </div>
        </div>
      </div>
    </header>

    <div class="body">
      <div v-if="state.drawerOpen" class="drawer-scrim" @click="state.drawerOpen = false" />
      <AppSidebar class="sidebar" :class="{ open: state.drawerOpen }" />
      <NoteList class="notes" />
      <main class="editor">
        <NoteEditor v-if="state.selectedId" :key="state.selectedId" :note-id="state.selectedId" />
        <div v-else class="nothing">
          <img src="/noteit-icon.png" alt="" width="64" height="64" />
          <p>Select a note, or press <kbd>⌥⌘N</kbd> for a new one.</p>
        </div>
      </main>
    </div>
  </div>
</template>

<style scoped>
.app {
  container-type: inline-size;
  container-name: app;
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--bg);
}
.hdr {
  height: var(--header-h);
  flex: none;
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 0 16px;
  border-bottom: 1px solid var(--line);
  background: var(--top);
}
.icon-btn {
  width: 40px;
  height: 40px;
  display: grid;
  place-items: center;
  border: 0;
  border-radius: 10px;
  background: transparent;
  color: var(--ink2);
  cursor: pointer;
  flex: none;
}
.menu-btn,
.search-btn {
  display: none;
}
.search-btn {
  background: var(--fill);
}
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  text-decoration: none;
  width: 220px;
  flex: none;
  font-size: 19px;
}
.search-field {
  flex: 1 1 280px;
  max-width: 520px;
  display: flex;
  align-items: center;
  gap: 8px;
  height: 36px;
  padding: 0 12px;
  border-radius: 10px;
  background: var(--fill);
  color: var(--ink2);
}
.search-field input {
  flex: 1;
  min-width: 0;
  border: 0;
  background: transparent;
  font-size: 14px;
  color: var(--ink);
  outline: none;
}
kbd {
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  color: var(--ink2);
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 2px 6px;
}
.right {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: 8px;
  flex: none;
}
.new-btn {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  height: 40px;
  padding: 0 14px;
  border: 0;
  border-radius: 10px;
  background: var(--acc);
  color: var(--onacc);
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
}
.account {
  position: relative;
}
.avatar {
  width: 34px;
  height: 34px;
  border: 0;
  border-radius: 50%;
  background: var(--avatar);
  color: #fff;
  font-size: 13px;
  font-weight: 700;
  cursor: pointer;
}
.menu {
  position: absolute;
  right: 0;
  top: 42px;
  z-index: 40;
  min-width: 220px;
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-dialog);
  padding: 6px;
  display: flex;
  flex-direction: column;
}
.menu .who {
  padding: 8px 10px;
  font-weight: 600;
  display: flex;
  flex-direction: column;
  font-size: 14px;
}
.menu .who span {
  font-weight: 400;
  font-size: 12px;
  color: var(--ink2);
}
.menu button {
  display: flex;
  align-items: center;
  gap: 10px;
  height: 36px;
  padding: 0 10px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  font-size: 14px;
  text-align: left;
  cursor: pointer;
}
.menu button:hover {
  background: var(--fill);
}
.body {
  flex: 1;
  display: flex;
  align-items: stretch;
  min-height: 0;
  position: relative;
}
.sidebar {
  flex: 0 0 240px;
  max-width: 256px;
}
.notes {
  flex: 1 1 320px;
  max-width: 360px;
}
.editor {
  flex: 999 1 420px;
  min-width: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
.nothing {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  color: var(--ink2);
  opacity: 0.85;
}
.drawer-scrim {
  display: none;
}

@container app (max-width: 1279px) {
  .sidebar {
    flex-basis: 200px;
    max-width: 216px;
  }
  .notes {
    flex-basis: 260px;
    max-width: 300px;
  }
}
/* Tablet (design p13): the sidebar becomes a drawer behind the menu button. */
@container app (max-width: 1023px) {
  .menu-btn {
    display: grid;
  }
  .brand {
    width: auto;
  }
  .sidebar {
    display: none;
  }
  .sidebar.open {
    display: flex;
    position: absolute;
    inset: 0 auto 0 0;
    width: 280px;
    max-width: 85%;
    z-index: 30;
    box-shadow: var(--shadow-dialog);
  }
  .drawer-scrim {
    display: block;
    position: absolute;
    inset: 0;
    z-index: 29;
    background: var(--scrim);
  }
  :deep(.sync-label) {
    display: none;
  }
}
/* Phone (design p14): one pane at a time. */
@container app (max-width: 719px) {
  .hdr {
    gap: 6px;
    padding: 0 8px;
  }
  .notes {
    max-width: none;
    border-right: 0;
  }
  .editor {
    display: none;
  }
  .show-editor .notes {
    display: none;
  }
  .show-editor .editor {
    display: flex;
  }
  .search-field {
    display: none;
  }
  .search-btn {
    display: grid;
  }
  .new-label {
    display: none;
  }
  .new-btn {
    width: 40px;
    padding: 0;
    justify-content: center;
  }
  .brand-word,
  .settings-btn {
    display: none;
  }
}
</style>
