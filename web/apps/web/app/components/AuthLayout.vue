<script setup lang="ts">
defineProps<{ tagline?: string }>();
</script>

<template>
  <!-- design p06: gradient hero on the left, the form on the right; stacks below 880px -->
  <div class="auth">
    <aside class="hero">
      <div class="brand">
        <img src="/noteit-icon.png" alt="" width="44" height="44" />
        <span class="word">Note<span>It</span></span>
      </div>
      <svg class="squiggle" viewBox="0 0 400 120" fill="none" aria-hidden="true">
        <path d="M10 80 C 60 10, 110 10, 150 60 S 240 110, 280 50 S 360 20, 390 60" stroke="rgba(255,255,255,.35)" stroke-width="6" stroke-linecap="round" />
      </svg>
      <div>
        <div class="big">Notes at the speed of thought.</div>
        <div class="sub">{{ tagline ?? 'Your notes, on your server. Encrypted before they leave your browser.' }}</div>
      </div>
    </aside>
    <main class="side">
      <slot />
    </main>
  </div>
</template>

<style scoped>
.auth {
  min-height: 100vh;
  display: flex;
  flex-wrap: wrap;
  background: var(--bg);
  container-type: inline-size;
}
.hero {
  flex: 1 1 420px;
  min-height: 320px;
  padding: 56px;
  background: var(--hero);
  color: #fff;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  overflow: hidden;
}
.brand {
  display: flex;
  align-items: center;
  gap: 12px;
}
.word {
  font-size: 26px;
  font-weight: 800;
  font-style: italic;
  letter-spacing: -0.02em;
}
.word span {
  color: var(--hero-accent);
}
.squiggle {
  width: 100%;
  max-width: 420px;
}
.big {
  font-size: 34px;
  line-height: 1.15;
  font-weight: 700;
  letter-spacing: -0.01em;
  max-width: 440px;
}
.sub {
  font-size: 16px;
  line-height: 1.5;
  margin-top: 12px;
  color: rgba(255, 255, 255, 0.85);
  max-width: 440px;
}
.side {
  flex: 1 1 360px;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 48px 24px;
}
.side :deep(form) {
  width: 100%;
  max-width: 380px;
  display: flex;
  flex-direction: column;
  gap: 18px;
}
.side :deep(h1) {
  margin: 0;
  font-size: 28px;
  font-weight: 700;
}
.side :deep(.lead) {
  margin: 8px 0 0;
  font-size: 14px;
  color: var(--ink2);
}
.side :deep(.fine) {
  margin: 0;
  font-size: 13px;
  line-height: 1.5;
  color: var(--ink2);
}
@container (max-width: 879px) {
  .hero {
    flex-basis: 100%;
    min-height: 0;
    padding: 28px 24px;
    gap: 20px;
  }
  .squiggle {
    display: none;
  }
  .big {
    font-size: 26px;
  }
}
</style>
