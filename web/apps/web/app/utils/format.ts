export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v < 10 ? v.toFixed(1) : Math.round(v)} ${units[i]}`;
}

export function relativeTime(iso: string | number | undefined): string {
  if (iso === undefined) return '';
  const t = typeof iso === 'number' ? iso : Date.parse(iso);
  const diff = (Date.now() - t) / 1000;
  if (diff < 45) return 'Just now';
  if (diff < 3600) return `${Math.round(diff / 60)} min ago`;
  const d = new Date(t);
  const today = new Date();
  if (d.toDateString() === today.toDateString()) return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  const yesterday = new Date(today.getTime() - 86_400_000);
  if (d.toDateString() === yesterday.toDateString()) return 'Yesterday';
  if (diff < 6 * 86400) return d.toLocaleDateString(undefined, { weekday: 'short' });
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}
