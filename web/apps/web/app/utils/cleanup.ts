// "Clean Up Unused Storage…" (web-app spec §3.4.9): the Mac's wording (Sources/NoteIt/Settings/CleanupConfirmation.swift).

export const CLEANUP = {
  button: 'Clean Up Unused Storage…',
  footnote: 'Removes copies of notes that were never finished saving.',
  title: 'Clean up unused storage?',
  message:
    'This removes leftover copies of notes that were never finished saving, for example from a Mac that was erased while it was syncing. Only run this when your other devices are idle. A note being saved on another device at the same moment could be lost if that device is then lost before it syncs again.',
  /** Under the disabled button on storage without atomic conditional writes. */
  unavailableCaption:
    'Needs storage that supports conditional writes. This storage keeps earlier copies of your notes; to free the space, move sync to a NoteIt server or a compatible S3 bucket.',
  cancel: 'Cancel',
  confirm: 'Clean Up',
} as const;

/** Like the Mac's ByteCountFormatter (`.file`): decimal units, "Zero KB" for nothing. */
export function fileSize(bytes: number): string {
  if (bytes <= 0) return 'Zero KB';
  if (bytes < 1000) return `${bytes} ${bytes === 1 ? 'byte' : 'bytes'}`;
  const units: [string, number][] = [
    ['KB', 0],
    ['MB', 1],
    ['GB', 2],
    ['TB', 2],
  ];
  let v = bytes / 1000;
  let i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  const [unit, digits] = units[i]!;
  return `${Number(v.toFixed(digits)).toLocaleString('en-US', { maximumFractionDigits: digits })} ${unit}`;
}

export function cleanupResultText(report: { deletedObjects: number; deletedBytes: number }): string {
  return `Removed ${report.deletedObjects} ${report.deletedObjects === 1 ? 'item' : 'items'} (${fileSize(report.deletedBytes)})`;
}

/** Enabled only while sync is connected and the storage has atomic conditional writes (Swift CleanupButtonState). */
export function cleanupButtonState(connected: boolean, available: boolean): { enabled: boolean; caption?: string } {
  return { enabled: connected && available, ...(connected && !available ? { caption: CLEANUP.unavailableCaption } : {}) };
}
