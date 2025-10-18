# UI (SvelteKit)

Public components and routes:

- **`+layout.svelte`**: App shell containing brand, sidebar, and content slot.
  - Exposes a `children` prop from SvelteKit route layout.

- **`+page.svelte`**: Dashboard page displaying webcam image and temperature cards.
  - Uses `onMount` to periodically invalidate and refresh data.
  - Exposes `chamber_led(on: bool)` helper to toggle LED via `/api/printer/led/chamber`.

- **`+layout.ts`**: `export const ssr = false;` — disables SSR so UI runs entirely client-side.

- **`+page.ts`**: Exports a `load` function that fetches printer status and webcam image.
  - Returns `{ nozzle_temperature, bed_temperature, image }` consumed by `+page.svelte`.

Usage examples:

- Trigger LED on/off from UI:

```svelte
<script lang="ts">
  async function chamber_led(on: bool) {
    await fetch(`/api/printer/led/chamber?state=${on ? 'on' : 'off'}`);
  }
</script>

<button onclick={() => chamber_led(true)}>LED On</button>
<button onclick={() => chamber_led(false)}>LED Off</button>
```

- Fetching status in a page `load`:

```ts
export const load: PageLoad = async ({ fetch }) => {
  const status = await fetch('/api/printer/status').then((r) => r.json());
  const image = await fetch('/api/webcam.jpg').then((r) => r.blob());
  return {
    nozzle_temperature: status.temperature.nozzle,
    bed_temperature: status.temperature.bed,
    image
  };
};
```
