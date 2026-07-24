<script setup>
import DefaultTheme from 'vitepress/theme'
import { useData } from 'vitepress'
const { Layout } = DefaultTheme
const { site } = useData()
const base = site.value.base || '/'
</script>

<template>
  <Layout>
    <template #home-hero-image>
      <div class="home-hero-image">
        <div class="demo-frame">
          <div class="demo-titlebar">
            <span class="demo-dot"></span>
            <span class="demo-dot"></span>
            <span class="demo-dot"></span>
          </div>
          <video autoplay muted loop playsinline preload="metadata">
            <source :src="base + 'demo.mp4'" type="video/mp4">
            <img :src="base + 'demo.gif'" alt="Séance-fork in action" />
          </video>
        </div>
      </div>
    </template>
  </Layout>
</template>

<style>
.home-hero-image {
  width: 100%;
  max-width: 560px;
  margin: 0 auto;
}

.demo-frame {
  background: var(--vp-c-bg-elv);
  border: 1px solid var(--vp-c-border);
  border-radius: 12px;
  padding: 10px;
  box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
}

.dark .demo-frame {
  box-shadow:
    0 20px 60px rgba(0, 0, 0, 0.5),
    0 0 80px rgba(80, 198, 247, 0.04);
}

.demo-titlebar {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 0 8px 8px;
}

.demo-dot {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background: var(--vp-c-text-3);
}

.demo-frame video,
.demo-frame img {
  display: block;
  width: 100%;
  height: auto;
  border-radius: 8px;
  background: #000;
}
</style>
