<script setup lang="ts">
defineProps<{ tagline?: string }>();
</script>

<template>
  <!-- design p06: gradient hero on the left, the form on the right; stacks below 880px -->
  <div class="auth flex min-h-dvh flex-wrap bg-default">
    <aside class="hero flex flex-col justify-between overflow-hidden text-white">
      <div class="flex items-center gap-3">
        <img src="/noteit-icon.png" alt="" width="44" height="44" />
        <span class="word">Note<span>It</span></span>
      </div>
      <svg class="squiggle" viewBox="0 0 400 120" fill="none" aria-hidden="true">
        <path d="M10 80 C 60 10, 110 10, 150 60 S 240 110, 280 50 S 360 20, 390 60" stroke="rgba(255,255,255,.35)" stroke-width="6" stroke-linecap="round" />
      </svg>
      <div>
        <div class="big">Notes at the speed of thought.</div>
        <div class="mt-3 max-w-[440px] text-base/normal text-white/85">{{ tagline ?? 'Your notes, on your server. Encrypted before they leave your browser.' }}</div>
      </div>
    </aside>
    <main class="flex flex-[1_1_360px] items-center justify-center px-6 py-12">
      <div class="flex w-full max-w-[380px] flex-col gap-5">
        <slot />
      </div>
    </main>
  </div>
</template>

<style scoped>
.auth {
  container-type: inline-size;
}
.hero {
  flex: 1 1 420px;
  min-height: 320px;
  padding: 56px;
  background: var(--hero);
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
